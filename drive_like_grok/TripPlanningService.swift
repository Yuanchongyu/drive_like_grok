//
//  TripPlanningService.swift
//  drive_like_grok
//
//  把用户自然语言 + 当前位置发给后端，由 Gemini 解析成有序站点列表。
//

import CoreLocation
import Foundation

/// 后端返回的规划结果
struct TripPlanResponse: Codable {
    let waypoints: [String]
}

/// 行程规划服务：根据用户输入和当前位置，返回有序站点
protocol TripPlanningService {
    func plan(userInput: String, location: CLLocationCoordinate2D?) async throws -> [String]
}

/// 调用云端后端（含 Gemini）的行程规划
final class APITripPlanningService: TripPlanningService {
    private let baseURL: String
    private let session: URLSession
    
    /// - Parameter baseURL: 后端根地址，如 "https://your-backend.run.app" 或 "http://localhost:5000"
    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }
    
    func plan(userInput: String, location: CLLocationCoordinate2D?) async throws -> [String] {
        let url = URL(string: baseURL.hasSuffix("/") ? baseURL + "plan" : baseURL + "/plan")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        var body: [String: Any] = ["userInput": userInput]
        if let loc = location {
            body["latitude"] = loc.latitude
            body["longitude"] = loc.longitude
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TripPlanningError.invalidResponse }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(http.statusCode)"
            throw TripPlanningError.serverError(status: http.statusCode, message: msg)
        }
        
        let decoded = try JSONDecoder().decode(TripPlanResponse.self, from: data)
        return decoded.waypoints
    }
}

enum TripPlanningError: LocalizedError {
    case invalidResponse
    case serverError(status: Int, message: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效的服务器响应"
        case .serverError(let s, let m): return "服务器错误 \(s)：\(m)"
        }
    }
}
