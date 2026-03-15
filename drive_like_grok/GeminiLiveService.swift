//
//  GeminiLiveService.swift
//  drive_like_grok
//
//  Gemini Multimodal Live API：实时双向语音，Native Audio、打断、情感对话。
//  使用方式：connect() → sendConfig() → 持续 sendAudioChunk()，在 delegate 里处理音频播放与 toolCall。
//

import AVFoundation
import Foundation

// MARK: - Delegate

/// Live API 事件回调：音频块、打断、工具调用、转写等（主线程回调，便于更新 UI）
@MainActor
protocol GeminiLiveServiceDelegate: AnyObject {
    /// 收到一段 24kHz 16-bit PCM，需实时播放（或交给内部 Player 播放）
    func geminiLive(_ service: GeminiLiveService, didReceiveAudioPCM pcmData: Data)
    /// 服务端通知用户打断，应停止播放并清空缓冲
    func geminiLiveDidInterrupt(_ service: GeminiLiveService)
    /// 模型请求调用工具（如 plan_route）
    func geminiLive(_ service: GeminiLiveService, toolCall name: String, arguments: [String: Any], callId: String)
    /// 连接状态
    func geminiLive(_ service: GeminiLiveService, connectionStateChanged state: GeminiLiveService.ConnectionState)
    /// 可选：用户/模型转写（调试或 UI）
    func geminiLive(_ service: GeminiLiveService, inputTranscription: String?)
    func geminiLive(_ service: GeminiLiveService, outputTranscription: String?)
}

extension GeminiLiveServiceDelegate {
    func geminiLive(_ service: GeminiLiveService, inputTranscription: String?) {}
    func geminiLive(_ service: GeminiLiveService, outputTranscription: String?) {}
}

/// 仅用于 checkLiveConnectivity：要求连接进入 connected 后再稳定一小段时间，避免“假成功”
@MainActor
private final class LiveTestDelegate: GeminiLiveServiceDelegate {
    private(set) var result: (ok: Bool, message: String)?
    private var connectedAt: Date?
    func geminiLive(_ service: GeminiLiveService, didReceiveAudioPCM pcmData: Data) {}
    func geminiLiveDidInterrupt(_ service: GeminiLiveService) {}
    func geminiLive(_ service: GeminiLiveService, toolCall name: String, arguments: [String: Any], callId: String) {}
    func geminiLive(_ service: GeminiLiveService, connectionStateChanged state: GeminiLiveService.ConnectionState) {
        switch state {
        case .connected:
            if connectedAt == nil {
                connectedAt = Date()
            }
        case .failed(let msg):
            result = (false, msg)
        default: break
        }
    }

    func pollStableResult() -> (ok: Bool, message: String)? {
        if let result {
            return result
        }
        if let connectedAt, Date().timeIntervalSince(connectedAt) >= 2.0 {
            return (true, "Live 连接成功（稳定 2 秒）")
        }
        return nil
    }
}

// MARK: - Service

final class GeminiLiveService: NSObject, URLSessionWebSocketDelegate, URLSessionDelegate {
    private let apiKey: String
    private let useV1Alpha: Bool
    private var nwSocket: LiveWebSocketNW?
    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var configSent = false
    private var pendingSystemInstruction: String?
    private var pendingEnableAffectiveDialog: Bool = false

    weak var delegate: GeminiLiveServiceDelegate?

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    init(apiKey: String, useV1Alpha: Bool = false) {
        self.apiKey = apiKey
        self.useV1Alpha = useV1Alpha
        super.init()
    }

    /// WebSocket 端点：Google 官方 Gemini Live API（与 AI Studio 同一服务）
    /// 文档：https://ai.google.dev/gemini-api/docs/multimodal-live
    private static let liveHost = "generativelanguage.googleapis.com"
    private var wsPathWithQuery: String {
        let path = useV1Alpha
            ? "google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
            : "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        return "/ws/\(path)?key=\(apiKey)"
    }

    private var wsURL: URL {
        URL(string: "wss://\(Self.liveHost)\(wsPathWithQuery)")!
    }

    /// 用 REST 快速检查：同一 host、同一 API Key 能否访问 Google（排除 Key/网络问题）
    /// 遇到连接中断/超时（-1005 等）会自动重试一次
    static func checkRESTConnectivity(apiKey: String) async -> (ok: Bool, message: String) {
        let result = await performRESTCheck(apiKey: apiKey)
        if case (false, let msg) = result, msg.contains("连接中断") || msg.contains("超时") {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await performRESTCheck(apiKey: apiKey)
        }
        return result
    }

    /// 仅测试 Live WebSocket 能否连上并稳定一小段时间，不发麦。
    /// 若 affective dialog 失败，会自动回退到标准 Live 再试，便于区分“Live 整体不通”和“仅 affective 配置不通”。
    static func checkLiveConnectivity(apiKey: String, forceIPv4: Bool, useURLSession: Bool) async -> (ok: Bool, message: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return (false, "请先填写 Gemini API Key") }
        let firstTry = await checkSingleLiveConnectivity(
            apiKey: key,
            useV1Alpha: true,
            enableAffectiveDialog: true,
            forceIPv4: forceIPv4,
            useURLSession: useURLSession
        )
        if firstTry.ok {
            return firstTry
        }
        let secondTry = await checkSingleLiveConnectivity(
            apiKey: key,
            useV1Alpha: false,
            enableAffectiveDialog: false,
            forceIPv4: forceIPv4,
            useURLSession: useURLSession
        )
        if secondTry.ok {
            return (true, "标准 Live 连接成功；当前网络/环境下 affective dialog 连接失败，已确认不是 Live 整体不可用。")
        }
        return firstTry
    }

    private static func checkSingleLiveConnectivity(
        apiKey: String,
        useV1Alpha: Bool,
        enableAffectiveDialog: Bool,
        forceIPv4: Bool,
        useURLSession: Bool
    ) async -> (ok: Bool, message: String) {
        let delegate = await MainActor.run { LiveTestDelegate() }
        let service = GeminiLiveService(apiKey: apiKey, useV1Alpha: useV1Alpha)
        service.delegate = delegate
        service.connect(
            systemInstruction: "You are a test.",
            enableAffectiveDialog: enableAffectiveDialog,
            forceIPv4: forceIPv4,
            useURLSession: useURLSession
        )
        for _ in 0..<200 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let r = await MainActor.run { delegate.pollStableResult() }
            if let r {
                service.disconnect()
                return r
            }
        }
        service.disconnect()
        return (false, "Live 连接超时（约 20 秒），当前网络或代理可能不支持 WebSocket。")
    }

    private static func performRESTCheck(apiKey: String) async -> (ok: Bool, message: String) {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(apiKey)") else {
            return (false, "请求地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 1 as Int]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return (false, "请求体无效") }
        request.httpBody = bodyData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 200 { return (true, "") }
            if code == 401 { return (false, "API Key 无效或已过期") }
            if code == 403 { return (false, "无权限访问该 API") }
            return (false, "Google 返回 \(code)，请检查网络或 Key")
        } catch {
            let ns = error as NSError
            if ns.code == NSURLErrorNetworkConnectionLost || ns.code == -1005 {
                return (false, "网络连接中断或超时，请检查网络后重试")
            }
            if ns.code == NSURLErrorTimedOut {
                return (false, "请求超时，请检查网络后重试")
            }
            return (false, "无法连接 Google（\(error.localizedDescription)）")
        }
    }

    // MARK: - Connect & Config

    /// 建立连接；config 会在 WebSocket 打开后自动发送
    /// - Parameters:
    ///   - forceIPv4: 仅 Network 方式时有效；REST 通但 Live 连不上可传 false
    ///   - useURLSession: 为 true 时用系统 URLSession 建连（与 REST 同栈），Network 连不上时可试
    func connect(systemInstruction: String, enableAffectiveDialog: Bool = false, forceIPv4: Bool = true, useURLSession: Bool = false) {
        guard nwSocket == nil, webSocketTask == nil else { return }
        pendingSystemInstruction = systemInstruction
        pendingEnableAffectiveDialog = enableAffectiveDialog
        configSent = false

        Task { @MainActor in
            delegate?.geminiLive(self, connectionStateChanged: .connecting)
        }

        if useURLSession {
            let config = URLSessionConfiguration.default
            config.waitsForConnectivity = true
            config.timeoutIntervalForRequest = 60
            let sess = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            session = sess
            var request = URLRequest(url: wsURL)
            request.timeoutInterval = 60
            let task = sess.webSocketTask(with: request)
            webSocketTask = task
            task.resume()
            let ref = task
            receiveTask = Task { [weak self] in
                await Self.runURLSessionReceiveLoop(service: self, webSocketTask: ref)
            }
        } else {
            let ws = LiveWebSocketNW(host: Self.liveHost, pathWithQuery: wsPathWithQuery)
            nwSocket = ws
            ws.setCallbacks(
                onOpen: { [weak self] in self?.sendPendingConfigAndNotify() },
                onMessage: { [weak self] data in
                    guard let self else { return }
                    let service = self
                    Task { @MainActor in service.handleResponse(data) }
                },
                onError: { [weak self] err in
                    guard let self else { return }
                    let service = self
                    let msg = service.connectionErrorMessage(err)
                    Task { @MainActor in service.delegate?.geminiLive(service, connectionStateChanged: .failed(msg)) }
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    let service = self
                    Task { @MainActor in service.delegate?.geminiLive(service, connectionStateChanged: .disconnected) }
                }
            )
            ws.connect(forceIPv4: forceIPv4)
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session = nil
        nwSocket?.disconnect()
        nwSocket = nil
        configSent = false
        pendingSystemInstruction = nil
        Task { @MainActor in
            delegate?.geminiLive(self, connectionStateChanged: .disconnected)
        }
    }

    private func connectionErrorMessage(_ error: Error) -> String {
        let s = error.localizedDescription
        let ns = error as NSError
        let detail = "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
        if s.contains("Socket is not connected") || s.contains("connection") || s.contains("connect") {
            return "连接失败（网络或代理问题）\n详情: \(detail)"
        }
        return s.isEmpty ? detail : "\(s)\n详情: \(detail)"
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        sendPendingConfigAndNotify()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error {
            let msg = connectionErrorMessage(e)
            Task { @MainActor in delegate?.geminiLive(self, connectionStateChanged: .failed(msg)) }
        }
    }

    /// WebSocket 打开后发 setup；真正 connected 以服务端 setupComplete 为准
    private func sendPendingConfigAndNotify() {
        guard let instruction = pendingSystemInstruction else { return }
        var setup: [String: Any] = [
            "model": "models/gemini-2.5-flash-native-audio-preview-12-2025",
            "generationConfig": [
                "responseModalities": ["AUDIO"]
            ] as [String: Any],
            "realtimeInputConfig": [
                "automaticActivityDetection": [
                    "disabled": true
                ] as [String: Any]
            ] as [String: Any],
            "systemInstruction": ["parts": [["text": instruction]]] as [String: Any],
            "inputAudioTranscription": [:] as [String: Any],
            "outputAudioTranscription": [:] as [String: Any]
        ] as [String: Any]
        if useV1Alpha && pendingEnableAffectiveDialog {
            setup["enableAffectiveDialog"] = true
        }
        setup["tools"] = [[
            "functionDeclarations": [[
                "name": "plan_route",
                "description": "根据用户说的站点顺序规划驾车路线并打开地图。站点按用户说的顺序排列。",
                "parameters": [
                    "type": "object",
                    "properties": ["waypoints": ["type": "array", "items": ["type": "string"], "description": "按顺序的站点名称或地址"] as [String: Any]] as [String: Any],
                    "required": ["waypoints"]
                ] as [String: Any]
            ] as [String: Any]]
        ] as [String: Any]]
        guard let data = try? JSONSerialization.data(withJSONObject: ["setup": setup]),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text) { [weak self] error in
            guard let self else { return }
            if let error {
                let msg = self.connectionErrorMessage(error)
                Task { @MainActor in
                    self.delegate?.geminiLive(self, connectionStateChanged: .failed(msg))
                }
                return
            }
        }
    }

    /// 发送一段 16kHz 16-bit PCM（little-endian）
    func sendAudioChunk(_ pcmData: Data) {
        guard configSent else { return }
        let base64 = pcmData.base64EncodedString()
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": base64,
                    "mimeType": "audio/pcm;rate=16000"
                ] as [String: Any]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    /// 用户停止说话时调用（若 API 支持可发 audioStreamEnd）
    func sendAudioStreamEnd() {
        guard configSent else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    func sendActivityStart() {
        guard configSent else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "activityStart": [:] as [String: Any]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    func sendActivityEnd() {
        guard configSent else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "activityEnd": [:] as [String: Any]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    /// 回复工具调用结果
    func sendToolResponse(callId: String, name: String, result: [String: Any]) {
        let message: [String: Any] = [
            "toolResponse": [
                "functionResponses": [[
                    "name": name,
                    "id": callId,
                    "response": ["result": result]
                ] as [String: Any]]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    // MARK: - Private

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text)
    }

    private func sendText(_ text: String, completion: ((Error?) -> Void)? = nil) {
        if let ws = nwSocket {
            ws.send(text: text, completion: completion)
            return
        }
        guard let task = webSocketTask else {
            completion?(NSError(domain: "GeminiLiveService", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocket 未建立"]))
            return
        }
        task.send(.string(text)) { [weak self] err in
            if let e = err, let self = self {
                let msg = self.connectionErrorMessage(e)
                Task { @MainActor in self.delegate?.geminiLive(self, connectionStateChanged: .failed(msg)) }
            }
            completion?(err)
        }
    }

    // MARK: - URLSession WebSocket（备用路径）

    private static func runURLSessionReceiveLoop(service: GeminiLiveService?, webSocketTask: URLSessionWebSocketTask?) async {
        guard let service, let webSocketTask else { return }
        while !Task.isCancelled {
            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .data(let data):
                    await MainActor.run { service.handleResponse(data) }
                case .string(let text):
                    if let data = text.data(using: .utf8) { await MainActor.run { service.handleResponse(data) } }
                @unknown default:
                    break
                }
            } catch {
                if (error as NSError).code != NSURLErrorCancelled {
                    await MainActor.run {
                        service.delegate?.geminiLive(service, connectionStateChanged: .failed(service.connectionErrorMessage(error)))
                    }
                }
                break
            }
        }
    }

    @MainActor
    private func handleResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if json["setupComplete"] != nil {
            configSent = true
            pendingSystemInstruction = nil
            delegate?.geminiLive(self, connectionStateChanged: .connected)
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if serverContent["interrupted"] as? Bool == true {
                delegate?.geminiLiveDidInterrupt(self)
            }
            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
               let parts = modelTurn["parts"] as? [[String: Any]] {
                for part in parts {
                    if let inline = part["inlineData"] as? [String: Any],
                       let b64 = inline["data"] as? String,
                       let pcm = Data(base64Encoded: b64) {
                        delegate?.geminiLive(self, didReceiveAudioPCM: pcm)
                    }
                }
            }
            if let inputTr = serverContent["inputTranscription"] as? [String: Any],
               let text = inputTr["text"] as? String {
                delegate?.geminiLive(self, inputTranscription: text)
            }
            if let outputTr = serverContent["outputTranscription"] as? [String: Any],
               let text = outputTr["text"] as? String {
                delegate?.geminiLive(self, outputTranscription: text)
            }
        }

        if let toolCall = json["toolCall"] as? [String: Any],
           let fcList = toolCall["functionCalls"] as? [[String: Any]] {
            for fc in fcList {
                let name = fc["name"] as? String ?? ""
                let callId = fc["id"] as? String ?? UUID().uuidString
                let args = fc["args"] as? [String: Any] ?? [:]
                delegate?.geminiLive(self, toolCall: name, arguments: args, callId: callId)
            }
        }
    }
}

// MARK: - 24kHz PCM 播放器（支持打断时清空）

/// 播放 Live API 返回的 24kHz 16-bit 单声道 PCM；收到打断时清空队列并停止
final class LiveAudioPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// Live API 原始输出格式（24kHz Int16 PCM）
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var outputFormat: AVAudioFormat!
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "live.audio.queue")
    private var buffers: [AVAudioPCMBuffer] = []
    private var pendingPCM = Data()
    private var isPlaying = false
    private var engineStarted = false
    private var hasPrimedPlayback = false
    private var isOutputActive = false
    /// 抖动缓冲：每块约 100ms，首次播放前预缓冲 2 块，减少碎片化调度造成的卡顿
    private let chunkFrames: UInt32 = 2400
    private let minimumStartBuffers = 2
    var onPlaybackStateChanged: ((Bool) -> Void)?

    init() {
        engine.attach(playerNode)
        // 不在 init 里 prepare/connect/start，否则启动时音频会话未就绪会崩 (inputNode/outputNode 断言)
        // 全部延后到首次播放时在 ensureEngineStarted() 里执行
    }

    /// 首次播放前调用：配置会话后再 connect、prepare、start，避免启动时崩溃
    private func ensureEngineStarted() {
        guard !engineStarted else { return }
        engineStarted = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try? session.setPreferredSampleRate(48000)
        try? session.setPreferredIOBufferDuration(0.01)
        try? session.setActive(true)
        // AVAudioEngine 的 mixer 更稳定接受 Float32 / non-interleaved
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)
        converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)
        engine.prepare()
        try? engine.start()
    }

    /// 追加一段 24kHz 16-bit PCM 并尝试播放
    func enqueue(_ pcmData: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureEngineStarted()
            self.pendingPCM.append(pcmData)
            self.drainPendingPCM()
            self.scheduleNextIfNeeded()
        }
    }

    private func drainPendingPCM() {
        let chunkBytes = Int(chunkFrames * 2)
        while pendingPCM.count >= chunkBytes {
            let chunk = Data(pendingPCM.prefix(chunkBytes))
            pendingPCM.removeFirst(chunkBytes)
            if let buffer = makeBuffer(from: chunk) {
                buffers.append(buffer)
            }
        }
        // 流式尾块：已有缓冲可播时，也允许把不足一块的尾部尽快送出去，减少停顿
        if !buffers.isEmpty, !pendingPCM.isEmpty, pendingPCM.count >= chunkBytes / 4 {
            let chunk = pendingPCM
            pendingPCM.removeAll(keepingCapacity: true)
            if let buffer = makeBuffer(from: chunk) {
                buffers.append(buffer)
            }
        }
    }

    private func makeBuffer(from pcmData: Data) -> AVAudioPCMBuffer? {
        let frameCount = UInt32(pcmData.count / 2)
        guard frameCount > 0 else { return nil }
        if let conv = converter {
            let ratio = outputFormat.sampleRate / sourceFormat.sampleRate
            let convertedCapacity = AVAudioFrameCount(ceil(Double(frameCount) * ratio))
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: convertedCapacity),
                  let srcBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else { return nil }
            srcBuf.frameLength = frameCount
            if let ch = srcBuf.int16ChannelData?[0] {
                pcmData.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    for i in 0..<Int(frameCount) { ch[i] = src[i] }
                }
            }
            outBuf.frameLength = 0
            var err: NSError?
            var done = false
            conv.convert(to: outBuf, error: &err, withInputFrom: { _, status in
                if !done {
                    done = true
                    status.pointee = .haveData
                    return srcBuf
                }
                status.pointee = .noDataNow
                return nil
            })
            guard err == nil, outBuf.frameLength > 0 else { return nil }
            return outBuf
        }

        guard let buf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        if let ch = buf.floatChannelData?[0] {
            pcmData.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Int16.self)
                for i in 0..<Int(frameCount) {
                    ch[i] = Float(src[i]) / 32768.0
                }
            }
        }
        return buf
    }

    /// 打断：清空未播放并停止
    func interrupt() {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffers.removeAll()
            self.pendingPCM.removeAll(keepingCapacity: true)
            self.isPlaying = false
            self.hasPrimedPlayback = false
            self.updateOutputActive(false)
            let node = self.playerNode
            Task { @MainActor in
                node.stop()
            }
        }
    }

    private func scheduleNextIfNeeded() {
        guard !buffers.isEmpty, !isPlaying else {
            if buffers.isEmpty, !isPlaying {
                updateOutputActive(false)
            }
            return
        }
        if !hasPrimedPlayback && buffers.count < minimumStartBuffers {
            return
        }
        let buffer = buffers.removeFirst()
        isPlaying = true
        updateOutputActive(true)
        playerNode.scheduleBuffer(buffer) { [weak self] in
            self?.queue.async {
                self?.isPlaying = false
                self?.scheduleNextIfNeeded()
            }
        }
        if playerNode.isPlaying == false {
            hasPrimedPlayback = true
            playerNode.play()
        }
    }

    private func updateOutputActive(_ active: Bool) {
        guard isOutputActive != active else { return }
        isOutputActive = active
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackStateChanged?(active)
        }
    }
}
