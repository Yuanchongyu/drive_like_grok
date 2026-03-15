//
//  ApiKeyStore.swift
//  drive_like_grok
//
//  用户自己填写的 API Key，存在 Keychain，仅本机可用。
//

import Foundation
import Security
import SwiftUI

private let service = "com.drive_like_grok.api"

final class ApiKeyStore: ObservableObject {
    static let keyGemini = "GEMINI_API_KEY"
    static let keyPlaces = "GOOGLE_PLACES_API_KEY"

    @Published private(set) var geminiKey: String = ""
    @Published private(set) var placesKey: String = ""

    init() {
        geminiKey = Self.load(account: Self.keyGemini)
        placesKey = Self.load(account: Self.keyPlaces)
    }

    var hasGeminiKey: Bool { !geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func save(gemini: String?, places: String?) {
        let g = (gemini ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = (places ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        Self.write(account: Self.keyGemini, value: g)
        Self.write(account: Self.keyPlaces, value: p)
        DispatchQueue.main.async { [weak self] in
            self?.geminiKey = g
            self?.placesKey = p
        }
    }

    private static func load(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    private static func write(account: String, value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        if value.isEmpty { return }
        var addQuery = query
        addQuery[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
