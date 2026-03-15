//
//  LiveSessionManager.swift
//  drive_like_grok
//
//  把 Gemini Live API、麦克风采集、播放和行程规划串起来；实现 delegate，收到 plan_route 时执行规划并打开地图。
//

import AVFoundation
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class LiveSessionManager: NSObject, ObservableObject, GeminiLiveServiceDelegate {
    @Published private(set) var isLiveActive = false
    @Published private(set) var isConnecting = false
    @Published var errorMessage: String?
    @Published var lastUserTranscript: String?
    @Published var lastAgentTranscript: String?

    private var liveService: GeminiLiveService?
    private let audioPlayer = LiveAudioPlayer()
    private var micCapture: LiveMicCapture?
    private let systemInstruction: String
    private var onPlanRoute: (([String], CLLocationCoordinate2D?) async -> (success: Bool, message: String))?
    private var lastOrigin: CLLocationCoordinate2D?
    private var connectRetryCount = 0
    private var lastApiKey: String?
    private var lastEnableAffectiveDialog: Bool = true
    private var didFallbackFromAffectiveDialog = false
    private var isModelAudioPlaying = false
    private var uplinkGateOpenUntil = Date.distantPast
    private var isUserActivityActive = false
    private var pendingActivityEndWorkItem: DispatchWorkItem?

    init(
        systemInstruction: String = "你是路线规划助手，像 Grok 一样和用户自然对话。用户会说想去哪些地方（可中英混说），你确认行程并用自然语气回复。只要用户提到要去哪里、导航、路线、先去A再去B、打开地图、带我去某地，就应优先调用 plan_route 工具，传入按用户原话顺序排列的站点列表；不要只聊天不调工具。若地点不够明确，可先简短确认后立刻调用工具。"
    ) {
        self.systemInstruction = systemInstruction
        self.onPlanRoute = nil
        super.init()
        audioPlayer.onPlaybackStateChanged = { [weak self] isPlaying in
            self?.isModelAudioPlaying = isPlaying
            if !isPlaying {
                self?.uplinkGateOpenUntil = Date.distantPast
            }
        }
    }

    /// 开始 Live 对话：连接、发 config、开始送麦
    /// - Parameter onPlanRoute: 收到 plan_route 时执行规划并打开地图，返回 (成功, 提示语)
    func startSession(
        apiKey: String,
        origin: CLLocationCoordinate2D?,
        onPlanRoute: @escaping ([String], CLLocationCoordinate2D?) async -> (success: Bool, message: String),
        enableAffectiveDialog: Bool = false
    ) {
        guard !isLiveActive, !apiKey.isEmpty else { return }
        self.onPlanRoute = onPlanRoute
        isConnecting = true
        errorMessage = nil
        lastUserTranscript = nil
        lastAgentTranscript = nil
        lastOrigin = origin
        lastApiKey = apiKey
        lastEnableAffectiveDialog = enableAffectiveDialog
        connectRetryCount = 0
        didFallbackFromAffectiveDialog = false
        isUserActivityActive = false
        pendingActivityEndWorkItem?.cancel()
        pendingActivityEndWorkItem = nil

        Task { @MainActor in
            let forceIPv4 = (UserDefaults.standard.object(forKey: "LiveForceIPv4") as? Bool) ?? true
            // 主界面说话始终用 URLSession，与「测试 Live 连接」一致，避免 NW 在部分网络下 Socket is not connected
            let service = GeminiLiveService(apiKey: apiKey, useV1Alpha: enableAffectiveDialog)
            service.delegate = self
            liveService = service
            service.connect(systemInstruction: systemInstruction, enableAffectiveDialog: enableAffectiveDialog, forceIPv4: forceIPv4, useURLSession: true)

            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if isConnecting, !isLiveActive {
                errorMessage = "Live 连接超时。可尝试：设置里开启「Live 使用 URLSession」或关闭「强制 IPv4」后重试。「说行程」仍可用。"
                isConnecting = false
                endSession()
            }
        }
    }

    /// 停止对话：停麦、断开连接
    func endSession() {
        pendingActivityEndWorkItem?.cancel()
        pendingActivityEndWorkItem = nil
        isUserActivityActive = false
        micCapture?.stop()
        micCapture = nil
        liveService?.sendAudioStreamEnd()
        liveService?.disconnect()
        liveService = nil
        audioPlayer.interrupt()
        isLiveActive = false
        isConnecting = false
    }

    private func startMicAndSend() async {
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission != .granted {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.requestRecordPermission { _ in cont.resume() }
            }
        }
        guard session.recordPermission == .granted else {
            errorMessage = "需要麦克风权限才能语音对话"
            endSession()
            return
        }
        let capture = LiveMicCapture()
        capture.onPCM = { [weak self] data in
            guard let self else { return }
            let level = self.rmsLevel(of: data)
            self.updateUserActivity(using: level)
            if self.shouldSendMicPCM(data) {
                self.liveService?.sendAudioChunk(data)
            }
        }
        do {
            try capture.start()
            micCapture = capture
        } catch {
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            endSession()
        }
    }

    // MARK: - GeminiLiveServiceDelegate

    func geminiLive(_ service: GeminiLiveService, didReceiveAudioPCM pcmData: Data) {
        audioPlayer.enqueue(pcmData)
    }

    func geminiLiveDidInterrupt(_ service: GeminiLiveService) {
        audioPlayer.interrupt()
        isModelAudioPlaying = false
        uplinkGateOpenUntil = Date.distantPast
    }

    func geminiLive(_ service: GeminiLiveService, toolCall name: String, arguments: [String: Any], callId: String) {
        guard name == "plan_route" else {
            service.sendToolResponse(callId: callId, name: name, result: ["error": "未知工具"])
            return
        }
        let waypoints = (arguments["waypoints"] as? [String]) ?? (arguments["waypoints"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !waypoints.isEmpty else {
            service.sendToolResponse(callId: callId, name: name, result: ["success": false, "message": "站点列表为空"])
            return
        }
        guard let onPlanRoute = onPlanRoute else {
            service.sendToolResponse(callId: callId, name: name, result: ["success": false, "message": "未设置规划回调"])
            return
        }
        Task { @MainActor in
            let (success, message) = await onPlanRoute(waypoints, lastOrigin)
            service.sendToolResponse(callId: callId, name: name, result: ["success": success, "message": message])
        }
    }

    func geminiLive(_ service: GeminiLiveService, connectionStateChanged state: GeminiLiveService.ConnectionState) {
        switch state {
        case .connecting:
            isConnecting = true
        case .connected:
            isConnecting = false
            isLiveActive = true
            if didFallbackFromAffectiveDialog {
                errorMessage = "已自动降级为标准 Live。当前环境下 affective dialog 连接失败，但基础 Live 可用。"
            }
            Task { @MainActor in await startMicAndSend() }
        case .disconnected:
            isConnecting = false
            pendingActivityEndWorkItem?.cancel()
            pendingActivityEndWorkItem = nil
            isUserActivityActive = false
            if isLiveActive { isLiveActive = false }
        case .failed(let msg):
            isConnecting = false
            isLiveActive = false
            pendingActivityEndWorkItem?.cancel()
            pendingActivityEndWorkItem = nil
            isUserActivityActive = false
            if lastEnableAffectiveDialog, let key = lastApiKey, !key.isEmpty {
                liveService?.disconnect()
                liveService = nil
                lastEnableAffectiveDialog = false
                didFallbackFromAffectiveDialog = true
                let forceIPv4 = (UserDefaults.standard.object(forKey: "LiveForceIPv4") as? Bool) ?? true
                let retry = GeminiLiveService(apiKey: key, useV1Alpha: false)
                retry.delegate = self
                liveService = retry
                isConnecting = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard liveService != nil else { return }
                    liveService?.connect(systemInstruction: systemInstruction, enableAffectiveDialog: false, forceIPv4: forceIPv4, useURLSession: true)
                }
            } else if connectRetryCount < 1, let key = lastApiKey, !key.isEmpty {
                connectRetryCount += 1
                liveService?.disconnect()
                liveService = nil
                let forceIPv4 = (UserDefaults.standard.object(forKey: "LiveForceIPv4") as? Bool) ?? true
                let retry = GeminiLiveService(apiKey: key, useV1Alpha: lastEnableAffectiveDialog)
                retry.delegate = self
                liveService = retry
                isConnecting = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard liveService != nil else { return }
                    liveService?.connect(systemInstruction: systemInstruction, enableAffectiveDialog: lastEnableAffectiveDialog, forceIPv4: forceIPv4, useURLSession: true)
                }
            } else {
                let hint = (msg.contains("Socket") || msg.contains("connection") || msg.contains("connect") || msg.contains("超时"))
                    ? "主界面已固定用 URLSession。若设置里「测试 Live 连接」能成功，可到设置里点「测试通过，直接开始 Live」用同一 Key 进对话。「说行程」仍可用。\n\n\(msg)"
                    : msg
                errorMessage = hint
            }
        }
    }

    func geminiLive(_ service: GeminiLiveService, inputTranscription: String?) {
        if let t = inputTranscription, !t.isEmpty { lastUserTranscript = t }
    }

    func geminiLive(_ service: GeminiLiveService, outputTranscription: String?) {
        if let t = outputTranscription, !t.isEmpty { lastAgentTranscript = t }
    }

    private func shouldSendMicPCM(_ data: Data) -> Bool {
        guard isModelAudioPlaying else { return true }

        let level = rmsLevel(of: data)
        let now = Date()

        // 播放中的弱音量大概率是扬声器漏音，直接拦住；只有明显用户开口时才短时间放行
        if level >= 0.045 {
            uplinkGateOpenUntil = now.addingTimeInterval(0.7)
            return true
        }

        return now < uplinkGateOpenUntil
    }

    private func updateUserActivity(using level: Float) {
        let speechThreshold: Float = 0.02
        if level >= speechThreshold {
            if !isUserActivityActive {
                isUserActivityActive = true
                liveService?.sendActivityStart()
            }
            pendingActivityEndWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isUserActivityActive else { return }
                self.isUserActivityActive = false
                self.liveService?.sendActivityEnd()
            }
            pendingActivityEndWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: work)
        }
    }

    private func rmsLevel(of data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        let sumSquares: Float = data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var acc: Float = 0
            for s in samples {
                let normalized = Float(s) / 32768.0
                acc += normalized * normalized
            }
            return acc
        }
        return sqrt(sumSquares / Float(sampleCount))
    }
}
