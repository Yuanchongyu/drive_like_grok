//
//  ContentView.swift
//  drive_like_grok
//
//  Created by chongyuyuan on 2026-03-10.
//

import SwiftUI

/// 后端地址：用 Mac 的局域网 IP。端口 5002（避免和 5000/5001 占用冲突）
private let planServiceBaseURL = "http://10.0.0.108:5002"

struct ContentView: View {
    @StateObject private var locationProvider = LocationProvider()
    @StateObject private var voiceHelper = VoiceInputHelper()
    @State private var userInput = ""
    @State private var isPlanning = false
    @State private var errorMessage: String?
    @State private var lastWaypoints: [String] = []

    private var planService: TripPlanningService {
        APITripPlanningService(baseURL: planServiceBaseURL)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("说一段行程，AI 根据你当前位置解析成路线并打开地图")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                TextField("例如：去学校接孩子，然后去最近的麦当劳，再回家", text: $userInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)
                    .padding(.horizontal)

                if !userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !voiceHelper.isListening {
                    Button("规划路线") { startPlanning() }
                        .font(.subheadline)
                        .disabled(isPlanning)
                }

                Button {
                    toggleVoiceInput()
                } label: {
                    Image(systemName: voiceHelper.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(voiceHelper.isListening ? .red : .blue)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                Group {
                    if voiceHelper.isListening {
                        Text("正在听… 说完再点一下结束并规划路线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let voiceErr = voiceHelper.errorMessage {
                        Text(voiceErr)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let coord = locationProvider.currentCoordinate {
                        Text("当前定位：\(coord.latitude), \(coord.longitude)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if locationProvider.isRequesting {
                        ProgressView("正在获取位置…")
                    } else if let err = locationProvider.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if isPlanning {
                        ProgressView("正在规划路线…")
                            .padding(.top, 8)
                    }
                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                    if !lastWaypoints.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("上次解析的站点：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(lastWaypoints.enumerated()), id: \.offset) { i, w in
                                Text("\(i + 1). \(w)")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                    }
                }

                Spacer()
            }
            .padding(.vertical)
            .navigationTitle("Drive like Grok")
            .onAppear {
                locationProvider.requestLocation()
            }
        }
    }

    private func toggleVoiceInput() {
        if voiceHelper.isListening {
            Task {
                let text = try? await voiceHelper.stopListening()
                let newInput: String
                if let t = text, !t.isEmpty {
                    newInput = userInput.isEmpty ? t : userInput + " " + t
                    await MainActor.run { userInput = newInput }
                } else {
                    newInput = userInput
                }
                let toPlan = newInput.trimmingCharacters(in: .whitespacesAndNewlines)
                if !toPlan.isEmpty {
                    startPlanning(overrideInput: toPlan)
                }
            }
        } else {
            Task {
                let ok = await voiceHelper.requestAuthorization()
                guard ok else { return }
                do {
                    try voiceHelper.startListening()
                } catch {
                    voiceHelper.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startPlanning(overrideInput: String? = nil) {
        let input = (overrideInput ?? userInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        errorMessage = nil
        isPlanning = true

        Task {
            do {
                let waypoints = try await planService.plan(
                    userInput: input,
                    location: locationProvider.currentCoordinate
                )
                await MainActor.run {
                    lastWaypoints = waypoints
                    isPlanning = false
                }
                guard !waypoints.isEmpty else {
                    await MainActor.run {
                        errorMessage = "未解析出任何站点"
                        isPlanning = false
                    }
                    return
                }
                let opened = await GoogleMapsOpener.openDirections(waypoints: waypoints, origin: locationProvider.currentCoordinate)
                await MainActor.run {
                    if !opened {
                        errorMessage = "无法打开地图"
                    }
                    isPlanning = false
                }
            } catch {
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
