//
//  CloudAccountToken.swift
//  Whisperer
//
//  The `appAccountToken` Apple embeds in every transaction of a subscription. It lets the server recognise
//  the same person after a reinstall or on a new Mac without anything derived from their Apple ID. It is a
//  random UUID kept in the iCloud-synchronised keychain, so every Mac signed into the same Apple Account
//  uses the same one. It identifies nothing by itself and carries no secret.
//

import Foundation
import Security

nonisolated enum CloudAccountToken {
    static let service = "com.ivy.whisperer.cloud.account-token"
    private static let account = "appAccountToken"

    /// The token for this Apple Account, created on first use. Nil only if the keychain refuses — the
    /// purchase then proceeds without one and the server binds by the original transaction id instead.
    static func current(service: String = CloudAccountToken.service) -> UUID? {
        if let existing = read(service: service) { return existing }
        let fresh = UUID()
        return write(fresh, service: service) ? fresh : read(service: service)
    }

    private static func baseQuery(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func read(service: String) -> UUID? {
        var query = baseQuery(service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    private static func write(_ token: UUID, service: String) -> Bool {
        var query = baseQuery(service)
        query[kSecValueData as String] = Data(token.uuidString.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecDuplicateItem
    }

    /// For tests: remove the item.
    static func delete(service: String = CloudAccountToken.service) {
        SecItemDelete(baseQuery(service) as CFDictionary)
    }
}
