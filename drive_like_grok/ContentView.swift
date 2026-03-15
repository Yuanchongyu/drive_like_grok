//
//  ContentView.swift
//  drive_like_grok
//
//  Created by chongyuyuan on 2026-03-10.
//

import AVFoundation
import SwiftUI

/// 后端地址：仅当用户未填写自己的 API Key 时使用（开发时可用本机 IP）
private let planServiceBaseURL = "http://10.0.0.108:5002"

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var voiceHelper = VoiceInputHelper()
    @StateObject private var apiKeyStore = ApiKeyStore()
    @StateObject private var liveManager = LiveSessionManager()
    @State private var userInput = ""
    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var lastWaypoints: [String] = []
    @State private var showApiKeySettings = false

    private var liveAffectiveDialogEnabled: Bool {
        (UserDefaults.standard.object(forKey: "LiveEnableAffectiveDialog") as? Bool) ?? false
    }

    /// 优先用用户自己填的 Key（Keychain），否则走自建后端
    private var planService: TripPlanningService {
        if apiKeyStore.hasGeminiKey {
            return OnDeviceTripPlanningService(
                geminiAPIKey: apiKeyStore.geminiKey,
                placesAPIKey: apiKeyStore.placesKey.isEmpty ? nil : apiKeyStore.placesKey
            )
        }
        return APITripPlanningService(baseURL: planServiceBaseURL)
    }

    private let accentGradient = LinearGradient(
        colors: [Color(red: 0.2, green: 0.8, blue: 1), Color(red: 0.4, green: 0.6, blue: 1)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var liveSubtitle: String {
        if liveManager.isConnecting { return "正在连接…" }
        if liveManager.isLiveActive { return "Live 对话中，点击结束" }
        if voiceHelper.isListening { return "正在听… 说完再点结束" }
        if isPlanning { return "正在规划…" }
        return "点击说话"
    }

    private var micButton: some View {
        Button {
            if !apiKeyStore.hasGeminiKey {
                showApiKeySettings = true
            } else {
                toggleLiveOrLegacy()
            }
        } label: {
            ZStack {
                let isActive = liveManager.isLiveActive || voiceHelper.isListening
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .stroke(
                            accentGradient.opacity(isActive ? 0.4 : 0.2),
                            lineWidth: 2
                        )
                        .scaleEffect(isActive ? 1.15 + Double(i) * 0.12 : 1.0 + Double(i) * 0.08)
                        .opacity(isActive ? 0.6 - Double(i) * 0.15 : 0.5 - Double(i) * 0.1)
                }
                Circle()
                    .fill(Color(red: 0.1, green: 0.12, blue: 0.2))
                    .frame(width: 120, height: 120)
                Circle()
                    .stroke(accentGradient, lineWidth: 3)
                    .frame(width: 120, height: 120)
                Image(systemName: liveManager.isLiveActive ? "stop.fill" : (voiceHelper.isListening ? "stop.fill" : "mic.fill"))
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(
                        isActive
                            ? LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : LinearGradient(colors: [Color(red: 0.3, green: 0.85, blue: 1), Color(red: 0.2, green: 0.6, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .animation(.easeInOut(duration: 0.35), value: liveManager.isLiveActive)
            .animation(.easeInOut(duration: 0.35), value: voiceHelper.isListening)
        }
        .buttonStyle(.plain)
        .disabled(isPlanning)
    }

    private var statusSection: some View {
        Group {
            Text(liveSubtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(voiceHelper.isListening ? 0.9 : 0.5))
                .padding(.top, 20)

            if let voiceErr = voiceHelper.errorMessage {
                Text(voiceErr)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }
            if let liveErr = liveManager.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text(liveErr)
                        .textSelection(.enabled)
                        .lineLimit(20)
                    if liveErr.contains("连接") || liveErr.contains("代理") {
                        Text("请检查：能在浏览器打开 google.com 吗？若在国内需开代理/VPN。若设置里「测试 Live 连接」能成功，可到设置里点「测试通过，直接开始 Live」。")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 8)
            }
            if let heard = liveManager.lastUserTranscript, !heard.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("她听到你说：")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(heard)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 8)
                .padding(.horizontal, 24)
            }
            if let said = liveManager.lastAgentTranscript, !said.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("她正在说：")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                    Text(said)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 8)
                .padding(.horizontal, 24)
            }
            if let err = errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.9))
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
            }
        }
    }

    private var settingsSheet: some View {
        ApiKeySettingsView(store: apiKeyStore) { key in
            showApiKeySettings = false
            let service = planService
            let loc = locationProvider.currentCoordinate
            liveManager.startSession(
                apiKey: key,
                origin: loc,
                onPlanRoute: { waypoints, origin in
                    let input = waypoints.joined(separator: " 然后 ")
                    do {
                        let result = try await service.plan(userInput: input, location: origin ?? loc)
                        guard !result.waypoints.isEmpty else { return (false, "未解析出站点") }
                        let opened = await GoogleMapsOpener.openDirections(
                            waypoints: result.waypoints,
                            origin: origin ?? loc
                        )
                        return (opened, opened ? "已打开地图" : "无法打开地图")
                    } catch {
                        return (false, error.localizedDescription)
                    }
                },
                enableAffectiveDialog: liveAffectiveDialogEnabled
            )
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // 深色科技感背景
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.14),
                        Color(red: 0.04, green: 0.06, blue: 0.12)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if !apiKeyStore.hasGeminiKey {
                        Button {
                            showApiKeySettings = true
                        } label: {
                            Label("请先设置 Gemini API Key", systemImage: "key.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        .padding(.top, 8)
                    }

                    Spacer(minLength: 40)

                    // 副标题：弱化
                    Text("说行程 · 开地图")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.bottom, 32)

                    micButton
                    statusSection

                    Spacer(minLength: 60)
                }
            }
            .navigationTitle("Drive like Grok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.06, green: 0.08, blue: 0.14), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("设置") { showApiKeySettings = true }
                        .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1))
                }
            }
            .sheet(isPresented: $showApiKeySettings) {
                settingsSheet
            }
            .onAppear {
                locationProvider.requestLocation()
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase != .active, (liveManager.isLiveActive || liveManager.isConnecting) {
                    liveManager.endSession()
                }
            }
        }
    }

    /// 主按钮：有 Gemini Key 时用 Live 对话（真人声 + 打断），否则走旧流程（本地 STT + TTS）
    private func toggleLiveOrLegacy() {
        guard apiKeyStore.hasGeminiKey else { return }
        if liveManager.isLiveActive {
            liveManager.endSession()
            return
        }
        // 先连 Live，连上后再要麦克风（与设置里「测试 Live 连接」顺序一致，避免先动音频会话影响建连）
        let service = planService
        let loc = locationProvider.currentCoordinate
        liveManager.startSession(
            apiKey: apiKeyStore.geminiKey,
            origin: loc,
            onPlanRoute: { waypoints, origin in
                let input = waypoints.joined(separator: " 然后 ")
                do {
                    let result = try await service.plan(userInput: input, location: origin ?? loc)
                    guard !result.waypoints.isEmpty else {
                        return (false, "未解析出站点")
                    }
                    let opened = await GoogleMapsOpener.openDirections(
                        waypoints: result.waypoints,
                        origin: origin ?? loc
                    )
                    return (opened, opened ? "已打开地图" : "无法打开地图")
                } catch {
                    return (false, error.localizedDescription)
                }
            },
            enableAffectiveDialog: liveAffectiveDialogEnabled
        )
    }

    private func speakThen(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            VoiceFeedbackHelper.speak(text) { cont.resume() }
        }
    }

    private func startPlanning(overrideInput: String? = nil) {
        let input = (overrideInput ?? userInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        errorMessage = nil
        isPlanning = true

        Task {
            do {
                let result = try await planService.plan(
                    userInput: input,
                    location: locationProvider.currentCoordinate
                )
                await MainActor.run {
                    lastWaypoints = result.waypoints
                    isPlanning = false
                }
                guard !result.waypoints.isEmpty else {
                    await speakThen("对不起，我没听明白，请您再说一遍可以吗？")
                    await MainActor.run {
                        errorMessage = "未解析出任何站点"
                        isPlanning = false
                    }
                    return
                }
                // 有语音回复：先读给用户听，再打开地图；没有则读「没听明白」且不打开地图
                if let reply = result.voiceReply, !reply.isEmpty {
                    await speakThen(reply)
                    let opened = await GoogleMapsOpener.openDirections(waypoints: result.waypoints, origin: locationProvider.currentCoordinate)
                    await MainActor.run {
                        if !opened {
                            errorMessage = "无法打开地图"
                        }
                        isPlanning = false
                    }
                } else {
                    await speakThen("对不起，我没听明白，请您再说一遍可以吗？")
                    await MainActor.run { isPlanning = false }
                }
            } catch {
                if let te = error as? TripPlanningError, case .serverError(let status, let msg) = te {
                    print("[Plan] 服务器错误 \(status)，完整响应：\n\(msg)")
                } else {
                    print("[Plan] 错误：", error)
                }
                await speakThen("对不起，我没听明白，请您再说一遍可以吗？")
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isPlanning = false
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
