//
//  VoiceFeedbackHelper.swift
//  drive_like_grok
//
//  用系统 TTS 把 Gemini 的回复读给用户听，像对话一样。
//

import AVFoundation
import Foundation

/// 用户可选的 TTS 设置（存在 UserDefaults）
enum TTSVoiceSettings {
    private static let keyVoiceId = "tts_voice_identifier"
    private static let keyPitch = "tts_pitch_multiplier"

    static var savedVoiceIdentifier: String? {
        get { UserDefaults.standard.string(forKey: keyVoiceId) }
        set { UserDefaults.standard.set(newValue, forKey: keyVoiceId) }
    }

    /// 音调倍数 0.5–2.0，略低于 1 更偏人声。默认 0.98
    static var pitchMultiplier: Double {
        get {
            let v = UserDefaults.standard.double(forKey: keyPitch)
            return v > 0 ? v : 0.98
        }
        set { UserDefaults.standard.set(newValue, forKey: keyPitch) }
    }

    /// 所有中文语音，增强质量优先（更自然），用于设置里选择
    static func chineseVoicesForPicker() -> [(identifier: String, name: String)] {
        let langPrefixes = ["zh-CN", "zh-Hans", "zh-TW", "zh-Hant"]
        let all = AVSpeechSynthesisVoice.speechVoices()
            .filter { v in langPrefixes.contains(where: { v.language.hasPrefix($0) }) }
        let enhancedFirst = all.sorted { v1, v2 in
            let e1 = (v1.quality == .enhanced) ? 1 : 0
            let e2 = (v2.quality == .enhanced) ? 1 : 0
            if e1 != e2 { return e1 > e2 }
            return v1.name < v2.name
        }
        return enhancedFirst.map { (identifier: $0.identifier, name: voiceDisplayName($0)) }
    }

    private static func voiceDisplayName(_ v: AVSpeechSynthesisVoice) -> String {
        let tag = (v.quality == .enhanced) ? " (增强)" : ""
        return v.name + tag
    }

    /// 当前应使用的语音：用户已选则用选的，否则优先增强中文
    static func currentVoice() -> AVSpeechSynthesisVoice? {
        if let id = savedVoiceIdentifier, !id.isEmpty {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        let list = chineseVoicesForPicker()
        guard let first = list.first else { return nil }
        return AVSpeechSynthesisVoice(identifier: first.identifier)
    }
}

enum VoiceFeedbackHelper {
    private static var holder: SpeakerHolder?

    /// 朗读一段中文，读完后 completion 在主线程调用（可用来接着打开地图）
    static func speak(_ text: String, completion: @escaping () -> Void) {
        // 去掉会触发 MauiVocalizer 解析错误的字符（反斜杠、括号内技术内容如 zh-CN）
        var safe = text
            .replacingOccurrences(of: "\\", with: "")
        if let regex = try? NSRegularExpression(pattern: "\\([^()]*\\)") {
            let range = NSRange(safe.startIndex..., in: safe)
            safe = regex.stringByReplacingMatches(in: safe, range: range, withTemplate: " ")
        }
        safe = safe.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else {
            DispatchQueue.main.async { completion() }
            return
        }
        let h = SpeakerHolder(completion: completion)
        holder = h
        h.speak(safe)
    }

    private final class SpeakerHolder: NSObject, AVSpeechSynthesizerDelegate {
        let synth = AVSpeechSynthesizer()
        let completion: () -> Void
        var didComplete = false
        var timeoutWorkItem: DispatchWorkItem?

        init(completion: @escaping () -> Void) {
            self.completion = completion
            super.init()
            synth.delegate = self
        }

        func speak(_ text: String) {
            // 录音后音频会话是 .record，需切回播放才能出声
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let u = AVSpeechUtterance(string: text)
            u.voice = TTSVoiceSettings.currentVoice()
                ?? AVSpeechSynthesisVoice(language: "zh-CN")
                ?? AVSpeechSynthesisVoice(language: "zh-Hans")
                ?? AVSpeechSynthesisVoice()
            u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
            u.pitchMultiplier = Float(TTSVoiceSettings.pitchMultiplier)
            synth.speak(u)
            // TTS 失败或卡住时 12 秒后仍回调，避免 continuation 泄漏
            let work = DispatchWorkItem { [weak self] in
                self?.finishOnce()
            }
            timeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        }

        private func finishOnce() {
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            guard !didComplete else { return }
            didComplete = true
            VoiceFeedbackHelper.holder = nil
            completion()
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            DispatchQueue.main.async { self.finishOnce() }
        }

        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            DispatchQueue.main.async { self.finishOnce() }
        }
    }
}
