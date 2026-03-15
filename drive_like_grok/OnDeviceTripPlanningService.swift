//
//  OnDeviceTripPlanningService.swift
//  drive_like_grok
//
//  在设备上直接调用 Gemini API 和（可选）Places API，无需自建后端。适合上架 App Store 免费版。
//

import CoreLocation
import Foundation

// MARK: - Gemini REST API

// 新用户可用：gemini-2.5-flash（2.0-flash 已不对新用户开放）
private let geminiModel = "gemini-2.5-flash"
private let geminiBase = "https://generativelanguage.googleapis.com/v1beta/models"

private struct GeminiRequest: Encodable {
    struct Content: Encodable {
        struct Part: Encodable {
            let text: String
        }
        let parts: [Part]
    }
    struct GenerationConfig: Encodable {
        let temperature: Float
        let maxOutputTokens: Int
    }
    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}

// MARK: - Places API

private let resolveKeywords = [
    "麦当劳", "mcdonald", "星巴克", "starbucks", "咖啡", "肯德基", "kfc", "加油站", "gas station",
    "超市", "银行", "最近", "附近", "nearest", "near me", "离我", "最近的"
]

private func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let R = 6371.0
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let a = sin(dLat/2)*sin(dLat/2) +
        cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon/2)*sin(dLon/2)
    let c = 2 * atan2(sqrt(min(1, a)), sqrt(1 - a))
    return R * c
}

// MARK: - OnDeviceTripPlanningService

/// 在设备上直接调用 Gemini + 可选 Places，不依赖自建后端。
final class OnDeviceTripPlanningService: TripPlanningService {
    private let geminiKey: String
    private let placesKey: String?
    private let session: URLSession

    init(geminiAPIKey: String, placesAPIKey: String? = nil, session: URLSession = .shared) {
        self.geminiKey = geminiAPIKey
        self.placesKey = placesAPIKey
        self.session = session
    }

    func plan(userInput: String, location: CLLocationCoordinate2D?) async throws -> PlanResult {
        let (waypoints, resolveFlags, voiceReply) = try await callGemini(userInput: userInput, location: location)
        let resolved: [String]
        if let loc = location, !waypoints.isEmpty {
            resolved = await resolveWaypoints(waypoints, resolveWithPlaces: resolveFlags, latitude: loc.latitude, longitude: loc.longitude)
        } else {
            resolved = waypoints
        }
        return PlanResult(waypoints: resolved, voiceReply: voiceReply)
    }

    // MARK: - Gemini

    private func callGemini(userInput: String, location: CLLocationCoordinate2D?) async throws -> (waypoints: [String], resolveWithPlaces: [Bool], voiceReply: String?) {
        var locationLine = ""
        if let lat = location?.latitude, let lng = location?.longitude {
            locationLine = "用户当前所在位置（经纬度）: (\(lat), \(lng))。请根据「当前位置」理解「附近」「最近」等表述。\n\n"
        }
        let prompt = """
        你是路线规划助手，像 Grok 一样和用户对话。\(locationLine)从用户的话里「按顺序」抽出每一站，并生成一句简短的语音回复（我们会用 TTS 读给用户听）。

        输出格式：一个 JSON 对象，包含两个键：
        - "stops": 数组，每个元素是 {"place": "地点名或描述", "resolve": true/false}。place 是这一站；resolve 表示是否需要系统解析成具体地址（泛指/连锁如麦当劳、加油站填 true，具体地址或家填 false）。
        - "reply": 一句简短的中文回复（1～2 句），用来确认行程并带点人情味，例如：「好的，先帮您导航到最近的麦当劳，下一站是 SFU 山上看夕阳，最后去 SFU 附近的球场，好好踢个球吧！」。纯中文短句，不要 markdown、反斜杠、代码或括号里的技术内容（会用于语音播放）。

        规则：
        1. 只输出一个 JSON 对象，不要其他解释。
        2. 示例：用户说「去学校然后去麦当劳再回家」→ {"stops":[{"place":"XX学校","resolve":false},{"place":"最近的麦当劳","resolve":true},{"place":"家","resolve":false}],"reply":"好的，先到学校，接着去最近的麦当劳，最后回家！"}
        3. 禁止把用户整句话当成一站；必须拆成多站。

        用户输入：
        \(userInput)

        请只输出 JSON 对象：
        """

        let url = URL(string: "\(geminiBase)/\(geminiModel):generateContent?key=\(geminiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = GeminiRequest(
            contents: [.init(parts: [.init(text: prompt)])],
            generationConfig: .init(temperature: 0.2, maxOutputTokens: 1024)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "\(response)"
            throw TripPlanningError.serverError(status: (response as? HTTPURLResponse)?.statusCode ?? -1, message: msg)
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates?.first?.content?.parts?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let parsed = parseStopsAndReply(text) { return parsed }
        if let parsed = parseWaypointsWithResolveFlags(text) { return (parsed.waypoints, parsed.resolveWithPlaces, nil) }
        if let waypoints = parseWaypointsFromResponseLegacy(text) {
            return (waypoints, waypoints.map { _ in true }, nil)
        }
        if let waypoints = fallbackSplit(userInput) {
            return (waypoints, waypoints.map { _ in true }, nil)
        }
        return userInput.isEmpty ? ([], [], nil) : ([userInput], [true], nil)
    }

    /// 解析 {"stops": [...], "reply": "..."}
    private func parseStopsAndReply(_ text: String) -> (waypoints: [String], resolveWithPlaces: [Bool], voiceReply: String?)? {
        guard let objMatch = text.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) else { return nil }
        let jsonStr = String(text[objMatch])
        guard let data = jsonStr.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stopsArr = obj["stops"] as? [[String: Any]] else { return nil }
        var places: [String] = []
        var flags: [Bool] = []
        for item in stopsArr {
            guard let p = item["place"] as? String else { continue }
            let place = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if place.isEmpty { continue }
            places.append(place)
            flags.append((item["resolve"] as? Bool) ?? false)
        }
        guard !places.isEmpty else { return nil }
        let reply = (obj["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (places, flags, reply?.isEmpty == false ? reply : nil)
    }

    /// 解析 [{"place":"...","resolve":true/false}, ...]（无 reply）
    private func parseWaypointsWithResolveFlags(_ text: String) -> (waypoints: [String], resolveWithPlaces: [Bool])? {
        guard let match = text.range(of: #"\[[\s\S]*?\]"#, options: .regularExpression) else { return nil }
        let jsonStr = String(text[match])
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var places: [String] = []
        var flags: [Bool] = []
        for item in arr {
            guard let p = item["place"] as? String else { continue }
            let place = p.trimmingCharacters(in: .whitespacesAndNewlines)
            if place.isEmpty { continue }
            let resolve = (item["resolve"] as? Bool) ?? false
            places.append(place)
            flags.append(resolve)
        }
        return places.isEmpty ? nil : (places, flags)
    }

    private func parseWaypointsFromResponseLegacy(_ text: String) -> [String]? {
        guard let match = text.range(of: #"\[[\s\S]*?\]"#, options: .regularExpression) else { return nil }
        let jsonStr = String(text[match])
        guard let data = jsonStr.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        var cleaned = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if cleaned.count == 1, cleaned[0].count > 30 {
            for sep in ["然后", "再", "接着", "最后去", "再去"] {
                let parts = cleaned[0].components(separatedBy: sep)
                if parts.count > 1 {
                    cleaned = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "，。、")) }.filter { !$0.isEmpty }
                    break
                }
            }
        }
        return cleaned.isEmpty ? nil : cleaned
    }

    private func fallbackSplit(_ userInput: String) -> [String]? {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in ["然后", "再", "接着", "最后", "再去"] {
            let parts = trimmed.components(separatedBy: sep)
            if parts.count > 1 {
                return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "去")) }.filter { !$0.isEmpty }
            }
        }
        return nil
    }

    // MARK: - Places

    private func resolveWaypoints(_ waypoints: [String], resolveWithPlaces: [Bool], latitude: Double, longitude: Double) async -> [String] {
        guard let key = placesKey, !key.isEmpty else {
            print("[Places] 未调用：未设置 Places API Key 或为空")
            return waypoints
        }
        var out: [String] = []
        for (i, w) in waypoints.enumerated() {
            let shouldResolve = i < resolveWithPlaces.count ? resolveWithPlaces[i] : false
            if !shouldResolve {
                out.append(w)
                continue
            }
            let resolved = await resolveToSinglePlace(query: w, latitude: latitude, longitude: longitude, placesKey: key)
            if let r = resolved {
                out.append(r)
                print("[Places] 解析成功：「\(w)」-> 「\(r)」")
            } else {
                out.append(w)
                print("[Places] 未解析（无结果）：「\(w)」")
            }
        }
        return out
    }

    private func resolveToSinglePlace(query: String, latitude: Double, longitude: Double, placesKey: String) async -> String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shouldResolve = resolveKeywords.contains { kw in q.contains(kw) || query.contains(kw) }
        guard shouldResolve else { return nil }

        // 加油站：用 Nearby Search 按「直线距离」排序，取最近的一个（比 Find Place 只给 1 个相关性结果准）
        if q.contains("加油站") || q.contains("gas station") {
            if let coords = await nearbySearchNearest(latitude: latitude, longitude: longitude, type: "gas_station", key: placesKey) {
                return coords
            }
        }

        // 其余：用 Text Search 拿多个结果，再按直线距离排序取最近（麦当劳、星巴克等）
        if let coords = await textSearchNearest(query: query, latitude: latitude, longitude: longitude, key: placesKey) {
            return coords
        }

        // 回退：Find Place from Text（只返回 1 个时用）
        return await findPlaceFallback(query: query, latitude: latitude, longitude: longitude, key: placesKey)
    }

    /// Nearby Search，rankby=distance，取直线距离最近的一个（加油站等有固定 type 的）
    private func nearbySearchNearest(latitude: Double, longitude: Double, type: String, key: String) async -> String? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/nearbysearch/json")!
        components.queryItems = [
            .init(name: "location", value: "\(latitude),\(longitude)"),
            .init(name: "rankby", value: "distance"),
            .init(name: "type", value: type),
            .init(name: "key", value: key)
        ]
        guard let url = components.url else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = json["error_message"] as? String {
            print("[Places] Nearby Search 错误：", err)
            return nil
        }
        guard let results = json["results"] as? [[String: Any]], let first = results.first else { return nil }
        let loc = (first["geometry"] as? [String: Any])?["location"] as? [String: Any]
        guard let lat = loc?["lat"] as? Double, let lng = loc?["lng"] as? Double else { return nil }
        return "\(lat),\(lng)"
    }

    /// Text Search 拿多个结果，按直线距离排序取最近
    private func textSearchNearest(query: String, latitude: Double, longitude: Double, key: String) async -> String? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/textsearch/json")!
        components.queryItems = [
            .init(name: "query", value: query),
            .init(name: "location", value: "\(latitude),\(longitude)"),
            .init(name: "key", value: key)
        ]
        guard let url = components.url else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = json["error_message"] as? String {
            print("[Places] Text Search 错误：", err)
            return nil
        }
        guard let results = json["results"] as? [[String: Any]], !results.isEmpty else { return nil }
        let sorted = results.sorted { r1, r2 in
            let loc1 = (r1["geometry"] as? [String: Any])?["location"] as? [String: Any]
            let loc2 = (r2["geometry"] as? [String: Any])?["location"] as? [String: Any]
            let (lat1, lng1) = (loc1?["lat"] as? Double, loc1?["lng"] as? Double)
            let (lat2, lng2) = (loc2?["lat"] as? Double, loc2?["lng"] as? Double)
            let d1 = lat1.flatMap { a in lng1.map { b in distanceKm(lat1: latitude, lon1: longitude, lat2: a, lon2: b) } } ?? .infinity
            let d2 = lat2.flatMap { a in lng2.map { b in distanceKm(lat1: latitude, lon1: longitude, lat2: a, lon2: b) } } ?? .infinity
            return d1 < d2
        }
        guard let best = sorted.first,
              let loc = (best["geometry"] as? [String: Any])?["location"] as? [String: Any],
              let lat = loc["lat"] as? Double, let lng = loc["lng"] as? Double else { return nil }
        return "\(lat),\(lng)"
    }

    private func findPlaceFallback(query: String, latitude: Double, longitude: Double, key: String) async -> String? {
        var components = URLComponents(string: "https://maps.googleapis.com/maps/api/place/findplacefromtext/json")!
        components.queryItems = [
            .init(name: "input", value: query),
            .init(name: "inputtype", value: "textquery"),
            .init(name: "locationbias", value: "circle:5000@\(latitude),\(longitude)"),
            .init(name: "fields", value: "formatted_address,name,geometry"),
            .init(name: "key", value: key)
        ]
        guard let url = components.url else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error_message"] == nil,
              let candidates = json["candidates"] as? [[String: Any]], !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { c1, c2 in
            let loc1 = (c1["geometry"] as? [String: Any])?["location"] as? [String: Any]
            let loc2 = (c2["geometry"] as? [String: Any])?["location"] as? [String: Any]
            let (lat1, lng1) = (loc1?["lat"] as? Double, loc1?["lng"] as? Double)
            let (lat2, lng2) = (loc2?["lat"] as? Double, loc2?["lng"] as? Double)
            let d1 = lat1.flatMap { a in lng1.map { b in distanceKm(lat1: latitude, lon1: longitude, lat2: a, lon2: b) } } ?? .infinity
            let d2 = lat2.flatMap { a in lng2.map { b in distanceKm(lat1: latitude, lon1: longitude, lat2: a, lon2: b) } } ?? .infinity
            return d1 < d2
        }
        let best = sorted[0]
        let loc = (best["geometry"] as? [String: Any])?["location"] as? [String: Any]
        guard let lat = loc?["lat"] as? Double, let lng = loc?["lng"] as? Double else { return best["formatted_address"] as? String }
        return "\(lat),\(lng)"
    }
}
