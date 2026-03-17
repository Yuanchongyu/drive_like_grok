//
//  drive_like_grokApp.swift
//  drive_like_grok
//
//  Created by chongyuyuan on 2026-03-10.
//

import SwiftUI

@main
struct drive_like_grokApp: App {
    var body: some Scene {
        WindowGroup {
            AppRootView()
        }
    }
}

struct AppRootView: View {
    @State private var showSplash = true

    var body: some View {
        ZStack {
            ContentView()
                .opacity(showSplash ? 0 : 1)

            if showSplash {
                AppSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeInOut(duration: 0.45)) {
                showSplash = false
            }
        }
    }
}
