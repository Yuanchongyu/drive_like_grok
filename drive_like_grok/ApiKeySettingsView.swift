//
//  ApiKeySettingsView.swift
//  drive_like_grok
//
//  让用户填写自己的 Gemini / Places API Key，保存在本机 Keychain。
//

import SwiftUI

private struct TTSVoiceOption: Identifiable {
    let identifier: String
    let name: String
    var id: String { identifier }
}

struct ApiKeySettingsView: View {
    @ObservedObject var store: ApiKeyStore
    @Environment(\.dismiss) private var dismiss
    /// 测试通过后可直接用当前 Key 开始 Live，与主界面「说话」同逻辑（由主界面传入）
    var onStartLiveWithKey: ((String) -> Void)?

    @State private var geminiInput: String = ""
    @State private var placesInput: String = ""
    @State private var savedMessage: String?
    @State private var selectedVoiceId: String = ""
    @State private var ttsPitch: Double = 0.98
    @State private var connectivityResult: String = ""
    @State private var isTestingConnectivity: Bool = false
    @State private var liveForceIPv4: Bool = true
    @State private var liveUseURLSession: Bool = true
    @State private var liveEnableAffectiveDialog: Bool = false
    @State private var liveTestResult: String = ""
    @State private var isTestingLive: Bool = false
    private var ttsVoiceOptions: [TTSVoiceOption] {
        [TTSVoiceOption(identifier: "", name: "系统推荐（优先增强）")] +
        TTSVoiceSettings.chineseVoicesForPicker().map { TTSVoiceOption(identifier: $0.identifier, name: $0.name) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("每人使用自己的 API Key，仅保存在本机，不会上传。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("语音对话使用 Google 官方 Gemini Live API（generativelanguage.googleapis.com），与 AI Studio 同一服务。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("Gemini API Key（必填）", text: $geminiInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Link("在 Google AI Studio 免费申请", destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.caption)
                } header: {
                    Text("Gemini API Key")
                }
                Section {
                    Button {
                        testGeminiConnectivity()
                    } label: {
                        HStack {
                            Text("测试 Gemini 连接")
                            if isTestingConnectivity {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(geminiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingConnectivity)
                    if !connectivityResult.isEmpty {
                        Text(connectivityResult)
                            .textSelection(.enabled)
                            .foregroundStyle(connectivityResult.hasPrefix("✓") ? .green : .red)
                            .font(.subheadline)
                    }
                } header: {
                    Text("连接测试")
                } footer: {
                    Text("使用当前填写的 Key 请求 generativelanguage.googleapis.com，确认 API 是否可用。")
                }
                Section {
                    Toggle("实验功能：情绪对话（Affective Dialog）", isOn: $liveEnableAffectiveDialog)
                        .onChange(of: liveEnableAffectiveDialog) { new in
                            UserDefaults.standard.set(new, forKey: "LiveEnableAffectiveDialog")
                        }
                    Text("默认关闭，优先保证标准 Live 稳定可用。开启后会尝试更有情绪反馈的预览能力；若失败，应用会自动回退到标准 Live。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Live 使用 URLSession（备用）", isOn: $liveUseURLSession)
                        .onChange(of: liveUseURLSession) { new in
                            UserDefaults.standard.set(new, forKey: "LiveUseURLSession")
                        }
                    Text("主界面「说话」已固定用 URLSession；此处仅影响「测试 Live 连接」用哪种方式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Live 连接强制 IPv4", isOn: $liveForceIPv4)
                        .onChange(of: liveForceIPv4) { new in
                            UserDefaults.standard.set(new, forKey: "LiveForceIPv4")
                        }
                    Text("仅 Network 方式有效。REST 通但 Live 连不上时可关闭（由系统选 IPv4/IPv6）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Live 语音连接")
                } footer: {
                    Text("默认使用标准 Live。若你想试情绪反馈，再开启上方实验功能。")
                }
                Section {
                    Button {
                        testLiveConnectivity()
                    } label: {
                        HStack {
                            Text("测试 Live 连接（仅 WebSocket）")
                            if isTestingLive {
                                Spacer()
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                    }
                    .disabled(geminiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingLive)
                    if !liveTestResult.isEmpty {
                        Text(liveTestResult)
                            .textSelection(.enabled)
                            .foregroundStyle(liveTestResult.contains("成功") ? .green : .red)
                            .font(.subheadline)
                        if liveTestResult.contains("成功"), let startLive = onStartLiveWithKey {
                            Button {
                                let key = geminiInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !key.isEmpty else { return }
                                store.save(gemini: geminiInput, places: placesInput)
                                dismiss()
                                // 测试刚断开，稍等再建新连，避免 code=57 Socket is not connected
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    startLive(key)
                                }
                            } label: {
                                Text("测试通过，直接开始 Live")
                                    .font(.subheadline.weight(.medium))
                            }
                        }
                    }
                } header: {
                    Text("Live 专用测试")
                } footer: {
                    Text("测试会使用与主界面「说话」相同的 Live 配置，并要求连接稳定约 2 秒。若开启实验功能失败，应用会自动回退到标准 Live。")
                }
                Section {
                    TextField("Google Places API Key（可选）", text: $placesInput)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    Text("用于把「最近的麦当劳」解析成具体地址。在 Google Cloud 开启 Places API 后创建 Key。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Places API Key")
                }
                Section {
                    Picker("语音", selection: $selectedVoiceId) {
                        ForEach(ttsVoiceOptions) { opt in
                            Text(opt.name).tag(opt.identifier)
                        }
                    }
                    .onChange(of: selectedVoiceId) { new in
                        TTSVoiceSettings.savedVoiceIdentifier = new.isEmpty ? nil : new
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("音调")
                            Spacer()
                            Text(String(format: "%.2f", ttsPitch))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $ttsPitch, in: 0.8 ... 1.2, step: 0.02)
                            .onChange(of: ttsPitch) { new in
                                TTSVoiceSettings.pitchMultiplier = new
                            }
                    }
                    Text("选「增强」语音更自然；音调略低于 1 更偏人声。可在系统 设置 → 辅助功能 → 朗读内容 → 语音 中下载更多语音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("语音朗读")
                }
                if let msg = savedMessage {
                    Section {
                        Text(msg)
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("API Key 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(geminiInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                geminiInput = store.geminiKey
                placesInput = store.placesKey
                selectedVoiceId = TTSVoiceSettings.savedVoiceIdentifier ?? ""
                ttsPitch = TTSVoiceSettings.pitchMultiplier
                liveForceIPv4 = (UserDefaults.standard.object(forKey: "LiveForceIPv4") as? Bool) ?? true
                liveUseURLSession = (UserDefaults.standard.object(forKey: "LiveUseURLSession") as? Bool) ?? true
                liveEnableAffectiveDialog = (UserDefaults.standard.object(forKey: "LiveEnableAffectiveDialog") as? Bool) ?? false
            }
        }
    }

    private func save() {
        store.save(gemini: geminiInput, places: placesInput)
        savedMessage = "已保存，仅存于本机。"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            dismiss()
        }
    }

    private func testGeminiConnectivity() {
        let key = geminiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        connectivityResult = ""
        isTestingConnectivity = true
        Task {
            let (ok, message) = await GeminiLiveService.checkRESTConnectivity(apiKey: key)
            await MainActor.run {
                isTestingConnectivity = false
                if ok {
                    connectivityResult = "✓ 连接正常，Gemini API 可用。"
                } else {
                    connectivityResult = "✗ " + (message.isEmpty ? "请求失败" : message)
                }
            }
        }
    }

    private func testLiveConnectivity() {
        let key = geminiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        liveTestResult = ""
        isTestingLive = true
        let forceIPv4 = liveForceIPv4
        let useURLSession = liveUseURLSession
        Task {
            let (ok, message) = await GeminiLiveService.checkLiveConnectivity(apiKey: key, forceIPv4: forceIPv4, useURLSession: useURLSession)
            await MainActor.run {
                isTestingLive = false
                if ok {
                    liveTestResult = "✓ " + message
                } else {
                    liveTestResult = "✗ " + message
                }
            }
        }
    }
}
