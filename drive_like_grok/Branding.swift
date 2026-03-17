//
//  Branding.swift
//  drive_like_grok
//

import SwiftUI

enum DrivePalette {
    static let backgroundTop = Color(red: 0.97, green: 0.98, blue: 1.0)
    static let backgroundBottom = Color(red: 0.93, green: 0.96, blue: 0.99)
    static let surface = Color.white.opacity(0.82)
    static let surfaceStrong = Color.white.opacity(0.94)
    static let stroke = Color(red: 0.84, green: 0.89, blue: 0.96)
    static let primary = Color(red: 0.22, green: 0.46, blue: 0.95)
    static let secondary = Color(red: 0.29, green: 0.80, blue: 0.90)
    static let textPrimary = Color(red: 0.11, green: 0.17, blue: 0.26)
    static let textSecondary = Color(red: 0.39, green: 0.49, blue: 0.62)
    static let shadow = Color(red: 0.33, green: 0.47, blue: 0.72).opacity(0.14)
}

struct DriveLogoMark: View {
    var size: CGFloat = 88

    var body: some View {
        Image("BrandLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .shadow(color: DrivePalette.shadow, radius: 18, x: 0, y: 12)
    }
}

struct DriveTitleLockup: View {
    var centered: Bool = true
    var subtitle: String = "Realtime voice navigation"
    var compact: Bool = false

    var body: some View {
        let alignment: HorizontalAlignment = centered ? .center : .leading
        let size: CGFloat = compact ? 54 : 90

        return VStack(alignment: alignment, spacing: compact ? 10 : 14) {
            DriveLogoMark(size: size)
            VStack(alignment: alignment, spacing: 6) {
                Text("Drive like Grok")
                    .font(.system(size: compact ? 24 : 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(DrivePalette.textPrimary)
                Text(subtitle)
                    .font(.system(size: compact ? 13 : 15, weight: .medium, design: .rounded))
                    .foregroundStyle(DrivePalette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }
}

struct AppSplashView: View {
    @State private var glow = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [DrivePalette.backgroundTop, DrivePalette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(DrivePalette.secondary.opacity(0.16))
                .frame(width: 220, height: 220)
                .blur(radius: 10)
                .offset(x: -90, y: -180)

            Circle()
                .fill(DrivePalette.primary.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 16)
                .offset(x: 120, y: 220)

            VStack(spacing: 24) {
                DriveTitleLockup(
                    centered: true,
                    subtitle: "Voice-first route planning"
                )

                HStack(spacing: 10) {
                    Circle()
                        .fill(DrivePalette.primary.opacity(glow ? 1 : 0.35))
                        .frame(width: 8, height: 8)
                    Circle()
                        .fill(DrivePalette.secondary.opacity(glow ? 0.7 : 0.25))
                        .frame(width: 8, height: 8)
                    Circle()
                        .fill(DrivePalette.primary.opacity(glow ? 0.45 : 0.18))
                        .frame(width: 8, height: 8)
                }
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: glow)
            }
            .padding(32)
        }
        .onAppear { glow = true }
    }
}
