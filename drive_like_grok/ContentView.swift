//
//  ContentView.swift
//  drive_like_grok
//
//  Created by chongyuyuan on 2026-03-10.
//

import AVFoundation
import CoreLocation
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
        colors: [DrivePalette.primary, DrivePalette.secondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var liveSubtitle: String {
        if liveManager.isConnecting { return "正在连接并准备麦克风…" }
        if liveManager.isLiveActive { return "Live 对话中，可以开始说话了" }
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
                            accentGradient.opacity(isActive ? 0.3 : 0.12),
                            lineWidth: 2
                        )
                        .scaleEffect(isActive ? 1.15 + Double(i) * 0.12 : 1.0 + Double(i) * 0.08)
                        .opacity(isActive ? 0.6 - Double(i) * 0.15 : 0.5 - Double(i) * 0.1)
                }
                Circle()
                    .fill(DrivePalette.surfaceStrong)
                    .frame(width: 120, height: 120)
                    .shadow(color: DrivePalette.shadow, radius: 24, x: 0, y: 12)
                Circle()
                    .strokeBorder(accentGradient, lineWidth: 3)
                    .frame(width: 120, height: 120)
                Image(systemName: liveManager.isLiveActive ? "stop.fill" : (voiceHelper.isListening ? "stop.fill" : "mic.fill"))
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(
                        isActive
                            ? LinearGradient(colors: [.pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                            : accentGradient
                    )
            }
            .animation(.easeInOut(duration: 0.35), value: liveManager.isLiveActive)
            .animation(.easeInOut(duration: 0.35), value: voiceHelper.isListening)
        }
        .buttonStyle(.plain)
        .disabled(isPlanning)
    }

    private var statusSection: some View {
        VStack(spacing: 12) {
            Text(liveSubtitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(DrivePalette.textSecondary)
                .padding(.top, 20)

            if let voiceErr = voiceHelper.errorMessage {
                messageCard(title: "语音错误", body: voiceErr, tint: .orange)
            }
            if let liveErr = liveManager.errorMessage {
                messageCard(
                    title: "Live 状态",
                    body: liveErr.contains("连接") || liveErr.contains("代理")
                        ? liveErr + "\n\n请检查：能在浏览器打开 google.com 吗？若在国内需开代理/VPN。若设置里「测试 Live 连接」能成功，可到设置里点「测试通过，直接开始 Live」。"
                        : liveErr,
                    tint: .orange
                )
            }
            if let heard = liveManager.lastUserTranscript, !heard.isEmpty {
                transcriptCard(title: "她听到你说", body: heard)
            }
            if let said = liveManager.lastAgentTranscript, !said.isEmpty {
                transcriptCard(title: "她正在说", body: said)
            }
            if let err = errorMessage {
                messageCard(title: "规划错误", body: err, tint: .red)
            }
        }
    }

    private func messageCard(title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            Text(body)
                .font(.caption)
                .foregroundStyle(DrivePalette.textPrimary)
                .textSelection(.enabled)
                .lineLimit(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DrivePalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DrivePalette.stroke, lineWidth: 1)
                )
        )
        .shadow(color: DrivePalette.shadow, radius: 10, x: 0, y: 8)
        .padding(.horizontal, 24)
    }

    private func transcriptCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DrivePalette.textSecondary)
            Text(body)
                .font(.callout)
                .foregroundStyle(DrivePalette.textPrimary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(DrivePalette.surfaceStrong)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(DrivePalette.stroke, lineWidth: 1)
                )
        )
        .shadow(color: DrivePalette.shadow, radius: 12, x: 0, y: 8)
        .padding(.horizontal, 24)
    }

    private func makeLiveSearchClosure(geminiKey: String) -> ((String, Int, Int, NearbySearchSort, CLLocationCoordinate2D?) async -> Result<[NearbyPlaceCandidate], Error>)? {
        let trimmedGeminiKey = geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPlacesKey = apiKeyStore.placesKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGeminiKey.isEmpty, !trimmedPlacesKey.isEmpty else {
            return nil
        }

        let provider = locationProvider

        return { query, radiusMeters, maxResults, sortBy, origin in
            let service = OnDeviceTripPlanningService(
                geminiAPIKey: trimmedGeminiKey,
                placesAPIKey: trimmedPlacesKey
            )
            do {
                let candidates = try await service.searchNearby(
                    query: query,
                    radiusMeters: radiusMeters,
                    maxResults: maxResults,
                    sortBy: sortBy,
                    location: origin ?? provider.currentCoordinate
                )
                return .success(candidates)
            } catch {
                return .failure(error)
            }
        }
    }

    private func startLiveSession(using key: String) {
        let loc = locationProvider.currentCoordinate
        liveManager.startSession(
            apiKey: key,
            origin: loc,
            onSearchNearby: makeLiveSearchClosure(geminiKey: key),
            enableAffectiveDialog: liveAffectiveDialogEnabled
        )
    }

    private var settingsSheet: some View {
        ApiKeySettingsView(store: apiKeyStore) { key in
            showApiKeySettings = false
            startLiveSession(using: key)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        DrivePalette.backgroundTop,
                        DrivePalette.backgroundBottom
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        DriveTitleLockup(
                            centered: true,
                            subtitle: "轻量、清爽、可打断的语音导航"
                        )
                        .padding(.top, 18)

                        if !apiKeyStore.hasGeminiKey {
                            messageCard(title: "开始之前", body: "先在设置里填写 Gemini API Key，就可以直接开始实时语音对话和导航。", tint: DrivePalette.primary)
                                .onTapGesture { showApiKeySettings = true }
                                .padding(.top, 20)
                        }

                        Spacer(minLength: 24)

                        micButton
                            .padding(.top, 34)

                        statusSection
                            .padding(.top, 8)

                        Spacer(minLength: 40)
                    }
                    .padding(.bottom, 36)
                }
            }
            .navigationTitle("Drive like Grok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DrivePalette.backgroundTop, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("设置") { showApiKeySettings = true }
                        .foregroundStyle(DrivePalette.primary)
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
        startLiveSession(using: apiKeyStore.geminiKey)
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
