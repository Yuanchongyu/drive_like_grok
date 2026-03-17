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
    /// 当前模型轮次是否已完成，可用于抑制“短暂掉空被误判成说完”
    func geminiLive(_ service: GeminiLiveService, modelTurnStateChanged isComplete: Bool)
}

extension GeminiLiveServiceDelegate {
    func geminiLive(_ service: GeminiLiveService, inputTranscription: String?) {}
    func geminiLive(_ service: GeminiLiveService, outputTranscription: String?) {}
    func geminiLive(_ service: GeminiLiveService, modelTurnStateChanged isComplete: Bool) {}
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
    private var pendingEnableNearbyDiscovery: Bool = false
    private var isDisconnecting = false

    weak var delegate: GeminiLiveServiceDelegate?

    private func log(_ message: String) {
        print("[GeminiLiveService] \(message)")
    }

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
            enableNearbyDiscovery: false,
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
    func connect(
        systemInstruction: String,
        enableAffectiveDialog: Bool = false,
        enableNearbyDiscovery: Bool = false,
        forceIPv4: Bool = true,
        useURLSession: Bool = false
    ) {
        guard nwSocket == nil, webSocketTask == nil else { return }
        log("connect useURLSession=\(useURLSession) useV1Alpha=\(useV1Alpha) affective=\(enableAffectiveDialog)")
        pendingSystemInstruction = systemInstruction
        pendingEnableAffectiveDialog = enableAffectiveDialog
        pendingEnableNearbyDiscovery = enableNearbyDiscovery
        configSent = false
        isDisconnecting = false

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
        log("disconnect")
        isDisconnecting = true
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        nwSocket?.disconnect()
        nwSocket = nil
        configSent = false
        pendingSystemInstruction = nil
        pendingEnableNearbyDiscovery = false
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
        log("websocket didOpen")
        sendPendingConfigAndNotify()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if isDisconnecting {
            log("urlSession didComplete during disconnect")
            Task { @MainActor in delegate?.geminiLive(self, connectionStateChanged: .disconnected) }
            return
        }
        if let e = error {
            log("urlSession didComplete error=\(e.localizedDescription)")
            let msg = connectionErrorMessage(e)
            Task { @MainActor in delegate?.geminiLive(self, connectionStateChanged: .failed(msg)) }
        }
    }

    /// WebSocket 打开后发 setup；真正 connected 以服务端 setupComplete 为准
    private func sendPendingConfigAndNotify() {
        guard let instruction = pendingSystemInstruction else { return }
        log("send setup")
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
        var functionDeclarations: [[String: Any]] = [[
            "name": "plan_route",
            "description": "当用户提出任何具体导航、路线、多站点出行请求时，必须首先调用此工具。不要先说正在规划路线。站点必须按用户原话顺序排列。",
            "parameters": [
                "type": "object",
                "properties": ["waypoints": ["type": "array", "items": ["type": "string"], "description": "按顺序的站点名称或地址"] as [String: Any]] as [String: Any],
                "required": ["waypoints"]
            ] as [String: Any]
        ] as [String: Any]]
        if pendingEnableNearbyDiscovery {
            functionDeclarations.append([
                "name": "search_nearby_places",
                "description": "当用户还没有确定具体目的地，只是想找附近推荐，比如附近评分高的餐厅、咖啡馆、健身房或商场时，先调用此工具，不要直接导航。",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "用户想找的类别或关键词，例如日料店、咖啡馆、健身房"] as [String: Any],
                        "radiusMeters": ["type": "integer", "description": "搜索半径，默认 5000，通常不超过 10000"] as [String: Any],
                        "maxResults": ["type": "integer", "description": "返回候选数量，通常填 3"] as [String: Any],
                        "sortBy": ["type": "string", "enum": ["rating", "distance"], "description": "按评分或距离排序"] as [String: Any]
                    ] as [String: Any],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any])
        }
        setup["tools"] = [[
            "functionDeclarations": functionDeclarations
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
        guard configSent, !isDisconnecting else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "audioStreamEnd": true
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    func sendActivityStart() {
        guard configSent, !isDisconnecting else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "activityStart": [:] as [String: Any]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    func sendActivityEnd() {
        guard configSent, !isDisconnecting else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "activityEnd": [:] as [String: Any]
            ] as [String: Any]
        ]
        sendJSON(message)
    }

    /// 回复工具调用结果
    func sendToolResponse(callId: String, name: String, result: [String: Any]) {
        guard !isDisconnecting else { return }
        log("sendToolResponse name=\(name) callId=\(callId) result=\(result)")
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
        guard !isDisconnecting else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        sendText(text)
    }

    private func sendText(_ text: String, completion: ((Error?) -> Void)? = nil) {
        guard !isDisconnecting else {
            completion?(nil)
            return
        }
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
            log("received setupComplete")
            configSent = true
            pendingSystemInstruction = nil
            delegate?.geminiLive(self, connectionStateChanged: .connected)
            return
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            if serverContent["generationComplete"] as? Bool == true || serverContent["turnComplete"] as? Bool == true {
                log("serverContent turn complete")
                delegate?.geminiLive(self, modelTurnStateChanged: true)
            } else if serverContent["modelTurn"] != nil {
                log("serverContent modelTurn")
                delegate?.geminiLive(self, modelTurnStateChanged: false)
            }
            if serverContent["interrupted"] as? Bool == true {
                log("serverContent interrupted")
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
                log("received toolCall name=\(name) callId=\(callId) args=\(args)")
                delegate?.geminiLive(self, toolCall: name, arguments: args, callId: callId)
            }
        }
    }
}

// MARK: - 24kHz PCM 播放器（支持打断时清空）

/// 播放 Live API 返回的 24kHz 16-bit 单声道 PCM；收到打断时清空队列并停止
final class LiveAudioPlayer {
    private let engine = AVAudioEngine()
    private lazy var sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
        guard let self else {
            Self.zeroAudioBufferList(audioBufferList, frameCount: Int(frameCount))
            return noErr
        }
        self.render(into: audioBufferList, frameCount: Int(frameCount))
        return noErr
    }
    /// Live API 原始输出格式（24kHz Int16 PCM）
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var outputFormat: AVAudioFormat!
    private var converter: AVAudioConverter?
    private let queue = DispatchQueue(label: "live.audio.queue")
    private var pendingPCM = Data()
    private var engineStarted = false
    private var isOutputActive = false
    private let ringLock = NSLock()
    private var ringBuffer: [Float] = Array(repeating: 0, count: 48000 * 20)
    private var readIndex = 0
    private var writeIndex = 0
    private var bufferedFrameCount = 0
    private var playbackPrimed = false
    private var hasStartedPlayback = false
    /// 连续流式播放：切更小块，首播缓冲更足，续播阈值更低，避免每次掉到 0 又重新等大缓冲
    private let chunkFrames: UInt32 = 1200
    private let initialStartFrames = 16800
    private let resumeStartFrames = 2400
    var onPlaybackStateChanged: ((Bool) -> Void)?

    init() {
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
        engine.attach(sourceNode)
        // 用设备首选采样率，减少不必要的格式不匹配
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 1)
        converter = AVAudioConverter(from: sourceFormat, to: outputFormat)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)
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
        }
    }

    private func drainPendingPCM() {
        let chunkBytes = Int(chunkFrames * 2)
        while pendingPCM.count >= chunkBytes {
            let chunk = Data(pendingPCM.prefix(chunkBytes))
            pendingPCM.removeFirst(chunkBytes)
            if let samples = convertToSamples(from: chunk) {
                append(samples: samples)
            }
        }
        // 尾块策略：只要已经有一定缓冲，就把剩余小块也尽快送入 ring buffer，避免语音断裂
        let bufferedFrames = currentBufferedFrames()
        let shouldFlushTail = hasStartedPlayback ? (pendingPCM.count >= 256) : (bufferedFrames >= initialStartFrames / 2 && pendingPCM.count >= chunkBytes / 4)
        if shouldFlushTail {
            let chunk = pendingPCM
            pendingPCM.removeAll(keepingCapacity: true)
            if let samples = convertToSamples(from: chunk) {
                append(samples: samples)
            }
        }
    }

    private func convertToSamples(from pcmData: Data) -> [Float]? {
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
            guard err == nil, outBuf.frameLength > 0, let ch = outBuf.floatChannelData?[0] else { return nil }
            let count = Int(outBuf.frameLength)
            return Array(UnsafeBufferPointer(start: ch, count: count))
        }

        var out = Array(repeating: Float.zero, count: Int(frameCount))
        pcmData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<Int(frameCount) {
                out[i] = Float(src[i]) / 32768.0
            }
        }
        return out
    }

    private func append(samples: [Float]) {
        guard !samples.isEmpty else { return }
        ringLock.lock()
        defer { ringLock.unlock() }

        let capacity = ringBuffer.count
        if samples.count >= capacity {
            let tail = samples.suffix(capacity)
            for sample in tail {
                ringBuffer[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
            }
            readIndex = writeIndex
            bufferedFrameCount = capacity
            playbackPrimed = false
            hasStartedPlayback = true
            updateOutputActiveLocked()
            return
        }

        let overflow = max(0, bufferedFrameCount + samples.count - capacity)
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            bufferedFrameCount -= overflow
        }

        for sample in samples {
            ringBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        bufferedFrameCount += samples.count
        updateOutputActiveLocked()
    }

    private func currentBufferedFrames() -> Int {
        ringLock.lock()
        defer { ringLock.unlock() }
        return bufferedFrameCount
    }

    func estimatedBufferedDuration() -> TimeInterval {
        ringLock.lock()
        let frames = bufferedFrameCount
        let sampleRate = outputFormat?.sampleRate ?? 48000
        ringLock.unlock()
        guard sampleRate > 0 else { return 0 }
        return Double(frames) / sampleRate
    }

    /// 打断：清空未播放并停止
    func interrupt() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingPCM.removeAll(keepingCapacity: true)
            self.ringLock.lock()
            self.readIndex = 0
            self.writeIndex = 0
            self.bufferedFrameCount = 0
            self.playbackPrimed = false
            self.hasStartedPlayback = false
            self.ringLock.unlock()
            self.updateOutputActive(false)
        }
    }

    private func render(into audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard !buffers.isEmpty else { return }

        for buffer in buffers {
            guard let mData = buffer.mData else { continue }
            let ptr = mData.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount {
                ptr[i] = 0
            }
        }

        ringLock.lock()
        defer {
            updateOutputActiveLocked()
            ringLock.unlock()
        }

        if !playbackPrimed {
            let requiredFrames = hasStartedPlayback ? resumeStartFrames : initialStartFrames
            if bufferedFrameCount < requiredFrames {
                return
            }
            playbackPrimed = true
            hasStartedPlayback = true
        }

        let framesToRead = min(frameCount, bufferedFrameCount)
        guard framesToRead > 0 else {
            return
        }

        guard let firstBufferData = buffers[0].mData else { return }
        let firstChannelPointer = firstBufferData.bindMemory(to: Float.self, capacity: frameCount)

        for i in 0..<framesToRead {
            firstChannelPointer[i] = ringBuffer[readIndex]
            readIndex = (readIndex + 1) % ringBuffer.count
        }
        bufferedFrameCount -= framesToRead

        for index in 1..<buffers.count {
            guard let mData = buffers[index].mData else { continue }
            let ptr = mData.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<framesToRead {
                ptr[i] = firstChannelPointer[i]
            }
        }

        if bufferedFrameCount == 0 {
            playbackPrimed = false
        }
    }

    private func updateOutputActiveLocked() {
        let active = playbackPrimed && bufferedFrameCount > 0
        guard isOutputActive != active else { return }
        isOutputActive = active
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackStateChanged?(active)
        }
    }

    private func updateOutputActive(_ active: Bool) {
        guard isOutputActive != active else { return }
        isOutputActive = active
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackStateChanged?(active)
        }
    }

    private static func zeroAudioBufferList(_ audioBufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in buffers {
            guard let mData = buffer.mData else { continue }
            let ptr = mData.bindMemory(to: Float.self, capacity: frameCount)
            for i in 0..<frameCount {
                ptr[i] = 0
            }
        }
    }
}
