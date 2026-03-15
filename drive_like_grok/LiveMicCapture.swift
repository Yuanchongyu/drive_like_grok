//
//  LiveMicCapture.swift
//  drive_like_grok
//
//  采集 16kHz 16-bit 单声道 PCM，供 Gemini Live API 使用。
//

import AVFoundation
import Foundation

/// 将麦克风转为 16kHz 16-bit PCM，按块回调
final class LiveMicCapture {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private let queue = DispatchQueue(label: "live.mic.capture")
    private var isRunning = false

    /// 每块 PCM 回调（可在任意线程调用）
    var onPCM: ((Data) -> Void)?

    func start() throws {
        guard !isRunning else { return }
        let inputNode = engine.inputNode

        let session = AVAudioSession.sharedInstance()
        // voiceChat 会启用系统级回声消除/自动增益，更适合双向语音而不是纯播放器模式
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        // 把 input 连到 mixer，让图包含 outputNode，满足 inputNode != nil || outputNode != nil 的初始化要求；format: nil 用设备原生格式
        engine.connect(inputNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0  // 不把麦克风送到扬声器，避免啸叫；只通过 tap 取数据
        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            self?.queue.async {
                self?.processBuffer(buffer, from: buffer.format)
            }
        }
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.disconnectNodeOutput(engine.inputNode)
        engine.stop()
    }

    private func processBuffer(_ buffer: AVAudioPCMBuffer, from format: AVAudioFormat) {
        guard let onPCM = onPCM else { return }
        if format.sampleRate == targetFormat.sampleRate && format.channelCount == 1 && format.commonFormat == .pcmFormatInt16 {
            pcmBufferToData(buffer).map { onPCM($0) }
            return
        }
        guard let conv = AVAudioConverter(from: format, to: targetFormat) else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / format.sampleRate) + 1
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        outBuffer.frameLength = 0
        var error: NSError?
        var provided = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if !provided {
                provided = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }
        conv.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if error == nil, outBuffer.frameLength > 0 {
            pcmBufferToData(outBuffer).map { onPCM($0) }
        }
    }

    private func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channel = buffer.int16ChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        return Data(bytes: channel, count: count * 2)
    }
}
