//
//  GoogleMapsOpener.swift
//  drive_like_grok
//
//  模拟器或无 Google Maps App 时用网页版打开路线；真机有 App 时用 App 打开。
//  路线逻辑：从「当前位置」出发，依次经过 waypoints 中的每个地点。
//

import CoreLocation
import Foundation
import UIKit

enum GoogleMapsOpener {
    /// 用站点列表打开 Google 地图（多站路线），起点为当前位置
    /// - Parameters:
    ///   - waypoints: 要依次去的地点（名称或地址），不包含起点
    ///   - origin: 起点坐标，传 nil 则用「当前定位」
    /// - Returns: 是否成功调起（App 或 Safari）
    @MainActor
    @discardableResult
    static func openDirections(waypoints: [String], origin: CLLocationCoordinate2D? = nil) async -> Bool {
        guard !waypoints.isEmpty else { return false }
        let originStr: String
        if let o = origin {
            originStr = "\(o.latitude),\(o.longitude)"
        } else {
            originStr = "Current+Location"
        }
        // 不手动编码，交给 URLComponents 统一编码，避免中文等变成乱码
        let destination = waypoints.last ?? waypoints[0]
        let waypointsParam = waypoints.dropLast().joined(separator: "|")
        var components = URLComponents(string: "https://www.google.com/maps/dir/")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: originStr),
            URLQueryItem(name: "destination", value: destination),
        ]
        if !waypointsParam.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "waypoints", value: waypointsParam))
        }
        guard let webURL = components.url else { return false }

        let appURLString = webURL.absoluteString.replacingOccurrences(of: "https://", with: "comgooglemapsurl://")
        guard let appURL = URL(string: appURLString) else {
            return await UIApplication.shared.open(webURL)
        }
        if canOpenGoogleMapsApp {
            return await UIApplication.shared.open(appURL)
        }
        return await UIApplication.shared.open(webURL)
    }

    /// 是否已安装并可调起 Google Maps App
    @MainActor
    static var canOpenGoogleMapsApp: Bool {
        guard let url = URL(string: "comgooglemapsurl://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
