//
//  VoiceInputHelper.swift
//  drive_like_grok
//
//  语音识别，将说的内容填入输入框。
//

import AVFoundation
import Speech
import SwiftUI

@MainActor
final class VoiceInputHelper: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published var errorMessage: String?

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var resultContinuation: CheckedContinuation<String?, Error>?  // used with resume(returning:) or resume(throwing:)

    private let speechRecognizer: SFSpeechRecognizer? = {
        // 优先中文，也支持英文
        if let zh = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")) { return zh }
        if let en = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) { return en }
        return SFSpeechRecognizer()
    }()

    override init() {
        super.init()
    }

    /// 请求语音识别与麦克风权限
    func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            errorMessage = speechStatusMessage(speechStatus)
            return false
        }
        let micStatus = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
        guard micStatus else {
            errorMessage = "需要麦克风权限才能语音输入"
            return false
        }
        errorMessage = nil
        return true
    }

    private func speechStatusMessage(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied: return "请在设置中允许语音识别"
        case .restricted: return "设备限制，无法使用语音识别"
        case .notDetermined: return "请先允许语音识别"
        default: return ""
        }
    }

    /// 开始听写，返回识别到的文字（用户调 stopListening 后才会返回）
    func startListening() throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw NSError(domain: "VoiceInput", code: -1, userInfo: [NSLocalizedDescriptionKey: "语音识别不可用"])
        }
        if isListening { return }
        cancelCurrentTask()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        // 关闭「仅设备端识别」，避免模拟器或未下载听写语言时出现 kAFAssistantErrorDomain 1101
        request.requiresOnDeviceRecognition = false

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            try? self?.recognitionRequest?.append(buffer)
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
        isListening = true
        errorMessage = nil

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, err in
            guard let self else { return }
            if let err = err {
                Task { @MainActor in self.finishWithError(err) }
                return
            }
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    if let c = self.resultContinuation {
                        self.resultContinuation = nil
                        c.resume(returning: text.isEmpty ? nil : text)
                    }
                }
            }
        }
    }

    /// 停止听写并返回当前识别结果（可能为 nil）
    func stopListening() async throws -> String? {
        guard isListening else { return nil }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        isListening = false
        return try await withCheckedThrowingContinuation { cont in
            resultContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if let c = resultContinuation {
                    resultContinuation = nil
                    c.resume(returning: nil)
                }
            }
        }
    }

    private func cancelCurrentTask() {
        audioEngine.stop()
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if let c = resultContinuation {
            resultContinuation = nil
            c.resume(returning: nil)
        }
    }

    private func finishWithError(_ error: Error) {
        isListening = false
        cancelCurrentTask()
        errorMessage = error.localizedDescription
        resultContinuation?.resume(throwing: error)
        resultContinuation = nil
    }
}
