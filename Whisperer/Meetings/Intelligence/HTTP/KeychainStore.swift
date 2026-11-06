//
//  KeychainStore.swift
//  Whisperer
//
//  Generic-password storage for connected-AI secrets (API keys, ChatGPT OAuth tokens).
//  Items are this-device-only and never synced to iCloud. Values never touch
//  UserDefaults or the log.
//

import Foundation
import Security

nonisolated struct KeychainStore: Sendable {
    let service: String

    static let connectedAI = KeychainStore(service: "com.ivy.whisperer.connected-ai")

    func string(for account: String) -> String? {
        guard let data = data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func data(for account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    @discardableResult
    func set(_ value: String, for account: String) -> Bool {
        set(Data(value.utf8), for: account)
    }

    /// Replaces the item atomically: update in place when it exists, add otherwise.
    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Logger.warning("Keychain: update failed for \(account) (\(update))", subsystem: .app)
            return false
        }
        var add = query
        add.merge(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Logger.warning("Keychain: add failed for \(account) (\(status))", subsystem: .app)
        }
        return status == errSecSuccess
    }

    @discardableResult
    func remove(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
