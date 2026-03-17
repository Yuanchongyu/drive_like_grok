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
    private struct PendingRouteLaunch {
        let waypoints: [String]
        let origin: CLLocationCoordinate2D?
        let createdAt: Date
    }

    @Published private(set) var isLiveActive = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isMicReady = false
    @Published var errorMessage: String?
    @Published var lastUserTranscript: String?
    @Published var lastAgentTranscript: String?

    private var liveService: GeminiLiveService?
    private let audioPlayer = LiveAudioPlayer()
    private var micCapture: LiveMicCapture?
    private let baseSystemInstruction: String
    private var lastOrigin: CLLocationCoordinate2D?
    private var onSearchNearby: ((String, Int, Int, NearbySearchSort, CLLocationCoordinate2D?) async -> Result<[NearbyPlaceCandidate], Error>)?
    private var connectRetryCount = 0
    private var lastApiKey: String?
    private var lastEnableAffectiveDialog: Bool = true
    private var didFallbackFromAffectiveDialog = false
    private var isModelAudioPlaying = false
    private var isModelTurnComplete = true
    private var uplinkGateOpenUntil = Date.distantPast
    private var bargeInStrongFrameCount = 0
    private var hasReceivedMicFrame = false
    private var isUserActivityActive = false
    private var pendingActivityEndWorkItem: DispatchWorkItem?
    private var pendingRouteLaunch: PendingRouteLaunch?
    private var pendingRouteLaunchWorkItem: DispatchWorkItem?
    private var pendingDiscoveryCandidates: [NearbyPlaceCandidate] = []
    private var isAwaitingRouteLaunch = false
    private var shouldAutoReconnect = true

    private func log(_ message: String) {
        print("[LiveSession] \(message)")
    }

    init(
        systemInstruction: String = "你是 Drive like Grok 的语音导航助手。用户会用中英混说提出导航或附近推荐请求。你必须把 direct navigation 和 nearby discovery 区分处理：已知目的地时立刻走导航链路；不知道具体去哪、只想找附近推荐时，先搜索候选，再让用户选择。"
    ) {
        self.baseSystemInstruction = systemInstruction
        super.init()
        audioPlayer.onPlaybackStateChanged = { [weak self] isPlaying in
            guard let self else { return }
            self.isModelAudioPlaying = isPlaying
            if isPlaying {
                self.isModelTurnComplete = false
                self.pendingRouteLaunchWorkItem?.cancel()
                self.pendingRouteLaunchWorkItem = nil
            }
            if !isPlaying {
                self.uplinkGateOpenUntil = Date.distantPast
                self.schedulePendingRouteLaunchIfNeeded(after: 0.35)
            }
        }
    }

    /// 开始 Live 对话：连接、发 config、开始送麦
    func startSession(
        apiKey: String,
        origin: CLLocationCoordinate2D?,
        onSearchNearby: ((String, Int, Int, NearbySearchSort, CLLocationCoordinate2D?) async -> Result<[NearbyPlaceCandidate], Error>)? = nil,
        enableAffectiveDialog: Bool = false
    ) {
        guard !isLiveActive, !apiKey.isEmpty else { return }
        log("startSession begin")
        isConnecting = true
        isMicReady = false
        errorMessage = nil
        lastUserTranscript = nil
        lastAgentTranscript = nil
        lastOrigin = origin
        self.onSearchNearby = onSearchNearby
        lastApiKey = apiKey
        lastEnableAffectiveDialog = enableAffectiveDialog
        connectRetryCount = 0
        didFallbackFromAffectiveDialog = false
        isUserActivityActive = false
        isModelTurnComplete = true
        bargeInStrongFrameCount = 0
        hasReceivedMicFrame = false
        uplinkGateOpenUntil = Date.distantPast
        pendingActivityEndWorkItem?.cancel()
        pendingActivityEndWorkItem = nil
        pendingRouteLaunchWorkItem?.cancel()
        pendingRouteLaunchWorkItem = nil
        pendingRouteLaunch = nil
        pendingDiscoveryCandidates = []
        isAwaitingRouteLaunch = false
        shouldAutoReconnect = true

        Task { @MainActor in
            let forceIPv4 = (UserDefaults.standard.object(forKey: "LiveForceIPv4") as? Bool) ?? true
            // 主界面说话始终用 URLSession，与「测试 Live 连接」一致，避免 NW 在部分网络下 Socket is not connected
            let service = GeminiLiveService(apiKey: apiKey, useV1Alpha: enableAffectiveDialog)
            service.delegate = self
            liveService = service
            service.connect(
                systemInstruction: makeSystemInstruction(origin: origin, searchEnabled: onSearchNearby != nil),
                enableAffectiveDialog: enableAffectiveDialog,
                enableNearbyDiscovery: onSearchNearby != nil,
                forceIPv4: forceIPv4,
                useURLSession: true
            )

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
        log("endSession")
        pendingActivityEndWorkItem?.cancel()
        pendingActivityEndWorkItem = nil
        isUserActivityActive = false
        bargeInStrongFrameCount = 0
        hasReceivedMicFrame = false
        uplinkGateOpenUntil = Date.distantPast
        pendingRouteLaunchWorkItem?.cancel()
        pendingRouteLaunchWorkItem = nil
        pendingRouteLaunch = nil
        pendingDiscoveryCandidates = []
        isAwaitingRouteLaunch = false
        onSearchNearby = nil
        micCapture?.stop()
        micCapture = nil
        liveService?.disconnect()
        liveService = nil
        audioPlayer.interrupt()
        isMicReady = false
        isLiveActive = false
        isConnecting = false
    }

    private func startMicAndSend() async -> Bool {
        log("startMicAndSend begin")
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission != .granted {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                session.requestRecordPermission { _ in cont.resume() }
            }
        }
        guard session.recordPermission == .granted else {
            log("microphone permission denied")
            errorMessage = "需要麦克风权限才能语音对话"
            endSession()
            return false
        }
        let capture = LiveMicCapture()
        capture.onPCM = { [weak self] data in
            guard let self else { return }
            let level = self.rmsLevel(of: data)
            DispatchQueue.main.async { [weak self] in
                self?.handleMicPCM(data, level: level)
            }
        }
        do {
            try capture.start()
            micCapture = capture
            log("microphone engine started, waiting first frame")
            for _ in 0..<15 {
                if hasReceivedMicFrame {
                    log("microphone first frame received")
                    return true
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            log("microphone first frame timeout")
            errorMessage = "麦克风准备超时，请重试一次"
            endSession()
            return false
        } catch {
            log("microphone start failed: \(error.localizedDescription)")
            errorMessage = "麦克风启动失败：\(error.localizedDescription)"
            endSession()
            return false
        }
    }

    // MARK: - GeminiLiveServiceDelegate

    func geminiLive(_ service: GeminiLiveService, didReceiveAudioPCM pcmData: Data) {
        isModelTurnComplete = false
        log("received audio pcm bytes=\(pcmData.count)")
        audioPlayer.enqueue(pcmData)
    }

    func geminiLiveDidInterrupt(_ service: GeminiLiveService) {
        log("server interrupted current turn")
        audioPlayer.interrupt()
        isModelAudioPlaying = false
        isModelTurnComplete = true
        bargeInStrongFrameCount = 0
        hasReceivedMicFrame = false
        uplinkGateOpenUntil = Date.distantPast
        if pendingRouteLaunch != nil {
            schedulePendingRouteLaunchIfNeeded(after: 0.6)
        } else {
            pendingRouteLaunchWorkItem?.cancel()
            pendingRouteLaunchWorkItem = nil
        }
    }

    func geminiLive(_ service: GeminiLiveService, toolCall name: String, arguments: [String: Any], callId: String) {
        log("toolCall name=\(name) callId=\(callId) args=\(arguments)")
        if name == "search_nearby_places" {
            handleSearchNearbyToolCall(service, arguments: arguments, callId: callId)
            return
        }
        guard name == "plan_route" else {
            service.sendToolResponse(callId: callId, name: name, result: ["error": "未知工具"])
            return
        }
        let waypoints = (arguments["waypoints"] as? [String]) ?? (arguments["waypoints"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !waypoints.isEmpty else {
            service.sendToolResponse(callId: callId, name: name, result: ["success": false, "message": "站点列表为空"])
            return
        }
        let cleaned = waypoints.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            service.sendToolResponse(callId: callId, name: name, result: ["success": false, "message": "站点列表为空"])
            return
        }
        isAwaitingRouteLaunch = true
        pendingDiscoveryCandidates = []
        pendingActivityEndWorkItem?.cancel()
        pendingActivityEndWorkItem = nil
        isUserActivityActive = false
        micCapture?.stop()
        micCapture = nil
        pendingRouteLaunchWorkItem?.cancel()
        pendingRouteLaunchWorkItem = nil
        pendingRouteLaunch = PendingRouteLaunch(waypoints: cleaned, origin: lastOrigin, createdAt: Date())
        log("route launch queued waypoints=\(cleaned)")
        service.sendToolResponse(
            callId: callId,
            name: name,
            result: ["success": true, "message": "路线已准备，将在播报结束后打开地图"]
        )
        let initialDelay = max(0.35, min(1.2, audioPlayer.estimatedBufferedDuration() + 0.2))
        schedulePendingRouteLaunchIfNeeded(after: initialDelay)
    }

    func geminiLive(_ service: GeminiLiveService, modelTurnStateChanged isComplete: Bool) {
        isModelTurnComplete = isComplete
        log("modelTurnStateChanged complete=\(isComplete)")
        if isComplete {
            let completionDelay = max(0.12, min(1.0, audioPlayer.estimatedBufferedDuration() + 0.12))
            schedulePendingRouteLaunchIfNeeded(after: completionDelay)
        }
    }

    func geminiLive(_ service: GeminiLiveService, connectionStateChanged state: GeminiLiveService.ConnectionState) {
        log("connectionStateChanged \(state)")
        switch state {
        case .connecting:
            isConnecting = true
        case .connected:
            isConnecting = true
            isLiveActive = false
            isMicReady = false
            isModelTurnComplete = true
            bargeInStrongFrameCount = 0
            hasReceivedMicFrame = false
            uplinkGateOpenUntil = Date.distantPast
            if didFallbackFromAffectiveDialog {
                errorMessage = "已自动降级为标准 Live。当前环境下 affective dialog 连接失败，但基础 Live 可用。"
            }
            Task { @MainActor in
                let micStarted = await startMicAndSend()
                guard micStarted else { return }
                shouldAutoReconnect = false
                isConnecting = false
                isLiveActive = true
                log("live session active")
            }
        case .disconnected:
            isConnecting = false
            isMicReady = false
            isModelTurnComplete = true
            bargeInStrongFrameCount = 0
            hasReceivedMicFrame = false
            uplinkGateOpenUntil = Date.distantPast
            pendingActivityEndWorkItem?.cancel()
            pendingActivityEndWorkItem = nil
            isUserActivityActive = false
            pendingRouteLaunchWorkItem?.cancel()
            pendingRouteLaunchWorkItem = nil
            pendingRouteLaunch = nil
            pendingDiscoveryCandidates = []
            isAwaitingRouteLaunch = false
            if isLiveActive { isLiveActive = false }
        case .failed(let msg):
            isConnecting = false
            isLiveActive = false
            isMicReady = false
            isModelTurnComplete = true
            bargeInStrongFrameCount = 0
            hasReceivedMicFrame = false
            uplinkGateOpenUntil = Date.distantPast
            pendingActivityEndWorkItem?.cancel()
            pendingActivityEndWorkItem = nil
            isUserActivityActive = false
            pendingRouteLaunchWorkItem?.cancel()
            pendingRouteLaunchWorkItem = nil
            pendingRouteLaunch = nil
            pendingDiscoveryCandidates = []
            isAwaitingRouteLaunch = false
            if shouldAutoReconnect, lastEnableAffectiveDialog, let key = lastApiKey, !key.isEmpty {
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
                    liveService?.connect(
                        systemInstruction: makeSystemInstruction(origin: lastOrigin, searchEnabled: onSearchNearby != nil),
                        enableAffectiveDialog: false,
                        enableNearbyDiscovery: onSearchNearby != nil,
                        forceIPv4: forceIPv4,
                        useURLSession: true
                    )
                }
            } else if shouldAutoReconnect, connectRetryCount < 1, let key = lastApiKey, !key.isEmpty {
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
                    liveService?.connect(
                        systemInstruction: makeSystemInstruction(origin: lastOrigin, searchEnabled: onSearchNearby != nil),
                        enableAffectiveDialog: lastEnableAffectiveDialog,
                        enableNearbyDiscovery: onSearchNearby != nil,
                        forceIPv4: forceIPv4,
                        useURLSession: true
                    )
                }
            } else {
                let hint = (msg.contains("Socket") || msg.contains("connection") || msg.contains("connect") || msg.contains("超时"))
                    ? "主界面已固定用 URLSession。若设置里「测试 Live 连接」能成功，可到设置里点「测试通过，直接开始 Live」用同一 Key 进对话。「说行程」仍可用。\n\n\(msg)"
                    : msg
                errorMessage = hint
                endSession()
            }
        }
    }

    func geminiLive(_ service: GeminiLiveService, inputTranscription: String?) {
        if let t = inputTranscription, !t.isEmpty {
            log("input transcription: \(t)")
            lastUserTranscript = t
        }
    }

    func geminiLive(_ service: GeminiLiveService, outputTranscription: String?) {
        if let t = outputTranscription, !t.isEmpty {
            log("output transcription: \(t)")
            lastAgentTranscript = t
        }
    }

    private func handleMicPCM(_ data: Data, level: Float) {
        if !hasReceivedMicFrame {
            hasReceivedMicFrame = true
            isMicReady = true
            log("first mic frame ready bytes=\(data.count) level=\(level)")
        }

        let shouldSend = shouldSendMicPCM(level: level)
        if shouldSend {
            updateUserActivity(using: level)
            liveService?.sendAudioChunk(data)
        }
    }

    private func shouldSendMicPCM(level: Float) -> Bool {
        guard !isAwaitingRouteLaunch else { return false }

        let modelSpeaking = isModelAudioPlaying || !isModelTurnComplete
        guard modelSpeaking else {
            bargeInStrongFrameCount = 0
            return true
        }

        let now = Date()

        // 模型正在说话时，只有连续几帧足够高的能量才视为用户真的在插话；
        // 这样不会把扬声器漏音误判成新的 activityStart。
        if level >= 0.065 {
            bargeInStrongFrameCount += 1
        } else {
            bargeInStrongFrameCount = 0
        }

        if bargeInStrongFrameCount >= 3 {
            uplinkGateOpenUntil = now.addingTimeInterval(0.9)
            bargeInStrongFrameCount = 0
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

    private func schedulePendingRouteLaunchIfNeeded(after delay: TimeInterval) {
        pendingRouteLaunchWorkItem?.cancel()
        guard pendingRouteLaunch != nil else { return }
        log("schedulePendingRouteLaunchIfNeeded delay=\(delay)")

        let work = DispatchWorkItem { [weak self] in
            guard let self, let pending = self.pendingRouteLaunch else { return }
            let routeAge = Date().timeIntervalSince(pending.createdAt)
            let bufferedAudio = self.audioPlayer.estimatedBufferedDuration()
            let canLaunchNow = !self.isModelAudioPlaying &&
                bufferedAudio < 0.08 &&
                (self.isModelTurnComplete || routeAge >= 4.0)
            guard canLaunchNow else {
                let retryDelay: TimeInterval
                if self.isModelAudioPlaying {
                    retryDelay = max(0.2, min(0.6, bufferedAudio + 0.12))
                } else if bufferedAudio >= 0.08 {
                    retryDelay = max(0.12, min(0.5, bufferedAudio + 0.08))
                } else {
                    retryDelay = 0.75
                }
                self.log("route launch postponed age=\(String(format: "%.2f", routeAge)) playing=\(self.isModelAudioPlaying) turnComplete=\(self.isModelTurnComplete) buffered=\(String(format: "%.2f", bufferedAudio))")
                self.schedulePendingRouteLaunchIfNeeded(after: retryDelay)
                return
            }

            self.pendingRouteLaunch = nil
            self.pendingRouteLaunchWorkItem = nil
            self.log("launching Google Maps waypoints=\(pending.waypoints)")

            Task { @MainActor in
                let opened = await GoogleMapsOpener.openDirections(
                    waypoints: pending.waypoints,
                    origin: pending.origin
                )
                if opened {
                    self.log("Google Maps opened successfully")
                    self.isAwaitingRouteLaunch = false
                    self.endSession()
                } else {
                    self.log("Google Maps open failed")
                    self.isAwaitingRouteLaunch = false
                    self.errorMessage = "导航失败：无法打开地图"
                    self.endSession()
                }
            }
        }

        pendingRouteLaunchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func handleSearchNearbyToolCall(_ service: GeminiLiveService, arguments: [String: Any], callId: String) {
        guard let onSearchNearby else {
            service.sendToolResponse(
                callId: callId,
                name: "search_nearby_places",
                result: ["success": false, "message": "当前会话没有启用附近搜索能力。请让用户直接说具体目的地后再导航。"]
            )
            return
        }

        let query = ((arguments["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            service.sendToolResponse(
                callId: callId,
                name: "search_nearby_places",
                result: ["success": false, "message": "搜索关键词不能为空"]
            )
            return
        }

        let radiusMeters = parsedInt(arguments["radiusMeters"]) ?? 5000
        let maxResults = parsedInt(arguments["maxResults"]) ?? 3
        let sortBy = NearbySearchSort(rawValue: ((arguments["sortBy"] as? String) ?? "rating").lowercased()) ?? .rating
        let origin = lastOrigin

        Task { @MainActor in
            let result = await onSearchNearby(query, radiusMeters, maxResults, sortBy, origin)
            switch result {
            case .success(let candidates):
                pendingDiscoveryCandidates = candidates
                let payloadCandidates = candidates.enumerated().map { offset, candidate in
                    makeCandidatePayload(candidate, index: offset + 1)
                }
                service.sendToolResponse(
                    callId: callId,
                    name: "search_nearby_places",
                    result: [
                        "success": true,
                        "query": query,
                        "sortBy": sortBy.rawValue,
                        "locationUsed": origin != nil,
                        "candidates": payloadCandidates,
                        "message": "已找到 \(candidates.count) 个候选。请先读出 2 到 3 个候选并让用户选择，不要直接导航。若用户说第一个、第二个或直接说店名，请从 candidates 中选中对应项，并把该候选的 routeTarget 作为 plan_route 的 waypoint。"
                    ]
                )
            case .failure(let error):
                pendingDiscoveryCandidates = []
                service.sendToolResponse(
                    callId: callId,
                    name: "search_nearby_places",
                    result: [
                        "success": false,
                        "query": query,
                        "locationUsed": origin != nil,
                        "message": error.localizedDescription
                    ]
                )
            }
        }
    }

    private func parsedInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let double as Double:
            return Int(double.rounded())
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func makeCandidatePayload(_ candidate: NearbyPlaceCandidate, index: Int) -> [String: Any] {
        var payload: [String: Any] = [
            "index": index,
            "id": candidate.id,
            "name": candidate.name,
            "address": candidate.address,
            "routeTarget": candidate.routeTarget
        ]
        if let distanceMeters = candidate.distanceMeters {
            payload["distanceMeters"] = distanceMeters
            payload["distanceText"] = distanceText(distanceMeters)
        }
        if let rating = candidate.rating {
            payload["rating"] = rating
        }
        if let userRatingsTotal = candidate.userRatingsTotal {
            payload["userRatingsTotal"] = userRatingsTotal
        }
        return payload
    }

    private func distanceText(_ distanceMeters: Int) -> String {
        if distanceMeters >= 1000 {
            return String(format: "%.1f 公里", Double(distanceMeters) / 1000.0)
        }
        return "\(distanceMeters) 米"
    }

    private func makeSystemInstruction(origin: CLLocationCoordinate2D?, searchEnabled: Bool) -> String {
        let locationContext: String
        if let origin {
            locationContext = "当前用户定位可用，经纬度约为 (\(origin.latitude), \(origin.longitude))。处理“附近”“最近”“5公里内”等 nearby discovery 请求时，不要再追问用户位置，直接使用当前位置。"
        } else {
            locationContext = "当前用户定位不可用。只有 direct navigation 可以继续；如果用户要搜索附近推荐，请先用一句极短的话说明需要定位权限或让用户给出区域。"
        }

        let discoveryContext: String
        if searchEnabled {
            discoveryContext = """
            任务拆分规则：
            1. direct navigation：用户已经给出明确目的地、路线、多站点顺序、打开地图等请求时，必须第一时间调用 `plan_route`，按原话顺序传入 `waypoints`。在 `plan_route` 之前不要先口头确认“正在规划路线”。
            2. nearby discovery：用户没有确定具体目的地，只是想找附近推荐，比如“附近评分最高的日料店”“5公里内咖啡馆推荐”“帮我找几家健身房”，必须先调用 `search_nearby_places`，不要直接导航。
            3. `search_nearby_places` 返回候选后，你要先简短读出 2 到 3 个候选，并告诉用户可以说“第一个”“第二个”或直接说店名来选择。
            4. 用户一旦从候选里选中一家，不要重新搜索；立刻调用 `plan_route`，并使用该候选的 `routeTarget` 作为 waypoint。
            5. nearby discovery 只适用于餐厅、咖啡馆、健身房、商场、超市这类 POI。若用户要搜房源、租房、房地产，请直接说明当前版本不支持这类搜索。
            """
        } else {
            discoveryContext = "当前会话没有启用 nearby discovery 工具。如果用户只想找附近推荐，请礼貌说明当前版本只支持直接导航到明确地点。"
        }

        return """
        \(baseSystemInstruction)

        \(locationContext)

        \(discoveryContext)
        """
    }
}
