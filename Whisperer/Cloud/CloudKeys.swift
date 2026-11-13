//
//  CloudKeys.swift
//  Whisperer
//
//  Master-key lifecycle for Whisperer Cloud (plan section 10): the keychain abstraction, the key ring,
//  the needs-key state machine and the recovery key.
//
//  Recovery key format: 32 random bytes written as RFC 4648-style groups of Crockford base32
//  (alphabet 0123456789ABCDEFGHJKMNPQRSTVWXYZ). 256 bits need 52 characters, so it is shown as 13 groups of
//  4 characters (the plan's "8 groups of 4" holds only 160 bits and cannot carry 32 bytes). The final
//  character carries 1 data bit plus 4 zero pad bits; a non-zero pad is rejected. There is no checksum.
//  Parsing ignores case, whitespace and hyphens and maps Crockford's O to 0 and I/L to 1.
//

import Foundation
import CryptoKit
import Security

nonisolated enum CloudKeyError: Error, LocalizedError, Equatable {
    case keychain(OSStatus)
    case keyAlreadyExists
    case libraryAlreadyExists
    case randomUnavailable
    case malformedKeyRing
    case malformedRecoveryKey
    case unwrapFailed
    case noSuchKey

    var errorDescription: String? {
        switch self {
        case .keychain(let s): return "Keychain error \(s)"
        case .keyAlreadyExists: return "A library key already exists on this Mac"
        case .libraryAlreadyExists: return "The cloud library already exists; its key must come from Keychain or the recovery key"
        case .randomUnavailable: return "Secure random numbers are unavailable"
        case .malformedKeyRing: return "The stored key ring is malformed"
        case .malformedRecoveryKey: return "That is not a valid recovery key"
        case .unwrapFailed: return "The recovery key does not unlock this library"
        case .noSuchKey: return "No key with that version"
        }
    }

    /// The test host may lack a data-protection keychain (-34018 missing entitlement, -25293 auth failed).
    var isKeychainUnavailable: Bool {
        if case .keychain(let s) = self { return s == -34018 || s == -25293 }
        return false
    }
}

// MARK: - Keychain abstraction

nonisolated protocol CloudKeychain: AnyObject, Sendable {
    func read(service: String, account: String, synchronizable: Bool) throws -> Data?
    /// Adds the item or replaces its value.
    func write(_ data: Data, service: String, account: String, synchronizable: Bool) throws
    func delete(service: String, account: String, synchronizable: Bool) throws
    func accounts(service: String, synchronizable: Bool) throws -> [String]
}

nonisolated final class SystemCloudKeychain: CloudKeychain {
    init() {}

    private func base(_ service: String, _ account: String?, _ sync: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: sync ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
                                kSecUseDataProtectionKeychain as String: true]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        var q = base(service, account, synchronizable)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw CloudKeyError.keychain(status) }
        return data
    }

    func write(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        var add = base(service, account, synchronizable)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base(service, account, synchronizable) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw CloudKeyError.keychain(status) }
    }

    func delete(service: String, account: String, synchronizable: Bool) throws {
        let status = SecItemDelete(base(service, account, synchronizable) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CloudKeyError.keychain(status) }
    }

    func accounts(service: String, synchronizable: Bool) throws -> [String] {
        var q = base(service, nil, synchronizable)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { throw CloudKeyError.keychain(status) }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Test double with the same semantics (replace on write, missing reads are nil).
nonisolated final class InMemoryCloudKeychain: CloudKeychain, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    init() {}

    private func key(_ s: String, _ a: String, _ sync: Bool) -> String { "\(sync ? "S" : "L")|\(s)|\(a)" }

    func read(service: String, account: String, synchronizable: Bool) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account, synchronizable)]
    }
    func write(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account, synchronizable)] = data
    }
    func delete(service: String, account: String, synchronizable: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        items[key(service, account, synchronizable)] = nil
    }
    func accounts(service: String, synchronizable: Bool) throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let prefix = key(service, "", synchronizable)
        return items.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted()
    }
}

// MARK: - Key ring

/// All master-key versions for one library. Version numbers are 1...255.
nonisolated struct CloudKeyRing: Equatable, Sendable {
    private(set) var keys: [UInt8: Data]

    init(keys: [UInt8: Data] = [:]) { self.keys = keys }

    var versions: [UInt8] { keys.keys.sorted() }
    /// The version used for new objects.
    var currentVersion: UInt8? { keys.keys.max() }
    var isEmpty: Bool { keys.isEmpty }

    mutating func insert(_ key: Data, version: UInt8) throws {
        guard key.count == 32 else { throw CloudCryptoError.badKeyLength }
        keys[version] = key
    }

    func symmetricKey(version: UInt8) -> SymmetricKey? { keys[version].map { SymmetricKey(data: $0) } }
    func current() -> (version: UInt8, key: SymmetricKey)? {
        guard let v = currentVersion, let k = symmetricKey(version: v) else { return nil }
        return (v, k)
    }

    /// "WKR1" || count(1) || count x (version(1) || key(32)), versions ascending.
    func serialized() -> Data {
        var d = Data("WKR1".utf8)
        d.append(UInt8(keys.count))
        for v in versions { d.append(v); d.append(keys[v]!) }
        return d
    }

    init(serialized data: Data) throws {
        let d = [UInt8](data)
        guard d.count >= 5, Array(d[0..<4]) == Array("WKR1".utf8) else { throw CloudKeyError.malformedKeyRing }
        let count = Int(d[4])
        guard d.count == 5 + count * 33 else { throw CloudKeyError.malformedKeyRing }
        var keys: [UInt8: Data] = [:]
        for i in 0..<count {
            let o = 5 + i * 33
            guard keys[d[o]] == nil else { throw CloudKeyError.malformedKeyRing }
            keys[d[o]] = Data(d[(o + 1)..<(o + 33)])
        }
        self.keys = keys
    }
}

// MARK: - Needs-key state machine

nonisolated enum CloudKeyState: Equatable, Sendable {
    /// The library does not exist: this Mac may generate the first key.
    case noKey
    /// A usable key is present locally; `version` is the newest one.
    case hasKey(version: UInt8)
    /// The library exists but this Mac has no usable key: wait for Keychain, enter the recovery key, or reset.
    case needsKey
}

// MARK: - Key store

nonisolated struct CloudKeyStore: Sendable {
    static let service = "com.ivy.whisperer.cloud.library"
    let keychain: CloudKeychain
    let service: String

    init(keychain: CloudKeychain = SystemCloudKeychain(), service: String = CloudKeyStore.service) {
        self.keychain = keychain
        self.service = service
    }

    private func account(_ version: UInt8) -> String { "master.v\(version)" }

    /// Every master key version currently in the keychain (including ones that arrived through iCloud Keychain).
    func loadRing() throws -> CloudKeyRing {
        var ring = CloudKeyRing()
        for name in try keychain.accounts(service: service, synchronizable: true) {
            guard name.hasPrefix("master.v"), let v = UInt8(name.dropFirst(8)),
                  let data = try keychain.read(service: service, account: name, synchronizable: true),
                  data.count == 32 else { continue }
            try ring.insert(data, version: v)
        }
        return ring
    }

    func save(_ key: Data, version: UInt8) throws {
        guard key.count == 32 else { throw CloudCryptoError.badKeyLength }
        try keychain.write(key, service: service, account: account(version), synchronizable: true)
    }

    func saveRing(_ ring: CloudKeyRing) throws {
        for v in ring.versions { try save(ring.keys[v]!, version: v) }
    }

    func deleteAll() throws {
        for name in try keychain.accounts(service: service, synchronizable: true) {
            try keychain.delete(service: service, account: name, synchronizable: true)
        }
    }

    /// `libraryExists` is the server's answer to `GET library`; `serverKeyVersion` its current key version.
    func state(libraryExists: Bool, serverKeyVersion: UInt8? = nil) throws -> CloudKeyState {
        let ring = try loadRing()
        guard let newest = ring.currentVersion else { return libraryExists ? .needsKey : .noKey }
        if let serverKeyVersion, ring.symmetricKey(version: serverKeyVersion) == nil { return .needsKey }
        return .hasKey(version: newest)
    }

    /// Generates the first master key. Call ONLY after the server said the library does not exist, and
    /// before telling the server (create-if-absent: the loser of a race gets 409 and calls `deleteAll()`).
    @discardableResult
    func generateFirstKey(libraryExists: Bool) throws -> SymmetricKey {
        guard !libraryExists else { throw CloudKeyError.libraryAlreadyExists }
        guard try loadRing().isEmpty else { throw CloudKeyError.keyAlreadyExists }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CloudKeyError.randomUnavailable }
        try save(bytes, version: 1)
        return SymmetricKey(data: bytes)
    }
}

// MARK: - Recovery key

nonisolated enum CloudRecoveryKey {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    static let infoLabel = Data("whisperer-recovery-v1".utf8)

    static func generate() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CloudKeyError.randomUnavailable }
        return bytes
    }

    /// 52 Crockford base32 characters in 13 groups of 4, joined by hyphens.
    static func encode(_ key: Data) throws -> String {
        guard key.count == 32 else { throw CloudCryptoError.badKeyLength }
        var chars: [Character] = []
        var acc: UInt32 = 0, bits = 0
        for b in key {
            acc = (acc << 8) | UInt32(b); bits += 8
            while bits >= 5 { bits -= 5; chars.append(alphabet[Int((acc >> UInt32(bits)) & 31)]) }
        }
        if bits > 0 { chars.append(alphabet[Int((acc << UInt32(5 - bits)) & 31)]) }
        return stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }.joined(separator: "-")
    }

    static func decode(_ text: String) throws -> Data {
        var values: [UInt8] = []
        for ch in text.uppercased() {
            if ch.isWhitespace || ch == "-" { continue }
            var c = ch
            if c == "O" { c = "0" } else if c == "I" || c == "L" { c = "1" }
            guard let idx = alphabet.firstIndex(of: c) else { throw CloudKeyError.malformedRecoveryKey }
            values.append(UInt8(idx))
        }
        guard values.count == 52 else { throw CloudKeyError.malformedRecoveryKey }
        var out = Data(); var acc: UInt32 = 0, bits = 0
        for v in values {
            acc = (acc << 5) | UInt32(v); bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((acc >> UInt32(bits)) & 0xff)) }
        }
        // 4 leftover pad bits must be zero.
        guard out.count == 32, (acc & ((1 << UInt32(bits)) - 1)) == 0 else { throw CloudKeyError.malformedRecoveryKey }
        return out
    }

    static func kek(recoveryKey: Data) throws -> SymmetricKey {
        guard recoveryKey.count == 32 else { throw CloudCryptoError.badKeyLength }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recoveryKey), salt: Data(),
                                      info: infoLabel, outputByteCount: 32)
    }

    private static func aad(accountId: String, keyVersion: UInt8) -> Data {
        var d = Data(accountId.utf8); d.append(keyVersion); return d
    }

    /// AES-GCM(KEK, serialized ring, AAD = accountId || keyVersion). Output is nonce || ciphertext || tag.
    static func wrap(ring: CloudKeyRing, recoveryKey: Data, accountId: String, keyVersion: UInt8) throws -> Data {
        let box = try AES.GCM.seal(ring.serialized(), using: kek(recoveryKey: recoveryKey),
                                   authenticating: aad(accountId: accountId, keyVersion: keyVersion))
        guard let combined = box.combined else { throw CloudKeyError.unwrapFailed }
        return combined
    }

    static func unwrap(_ wrapped: Data, recoveryKey: Data, accountId: String, keyVersion: UInt8) throws -> CloudKeyRing {
        do {
            let box = try AES.GCM.SealedBox(combined: wrapped)
            let plain = try AES.GCM.open(box, using: kek(recoveryKey: recoveryKey),
                                         authenticating: aad(accountId: accountId, keyVersion: keyVersion))
            return try CloudKeyRing(serialized: plain)
        } catch let e as CloudKeyError { throw e
        } catch { throw CloudKeyError.unwrapFailed }
    }
}
