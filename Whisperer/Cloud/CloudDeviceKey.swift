//
//  CloudDeviceKey.swift
//  Whisperer
//
//  A per-Mac P-256 signing key. It stays in the data-protection keychain of THIS device only (not
//  synchronizable), so each Mac has its own identity: the server enrols it, and revoking it cuts that Mac off.
//

import Foundation
import CryptoKit

nonisolated struct CloudDeviceKey {
    static let service = "com.ivy.whisperer.cloud.device-key"
    private static let account = "p256.signing"

    private let privateKey: P256.Signing.PrivateKey

    /// Loads this Mac's key, creating it on first use.
    static func loadOrCreate(keychain: CloudKeychain = SystemCloudKeychain(), service: String = CloudDeviceKey.service) throws -> CloudDeviceKey {
        if let raw = try keychain.read(service: service, account: account, synchronizable: false),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return CloudDeviceKey(privateKey: key)
        }
        let key = P256.Signing.PrivateKey()
        try keychain.write(key.rawRepresentation, service: service, account: account, synchronizable: false)
        return CloudDeviceKey(privateKey: key)
    }

    static func delete(keychain: CloudKeychain = SystemCloudKeychain(), service: String = CloudDeviceKey.service) throws {
        try keychain.delete(service: service, account: account, synchronizable: false)
    }

    /// Public key, 65-byte x9.63 form (0x04 || X || Y).
    var publicKeyX963: Data { privateKey.publicKey.x963Representation }

    /// Base64 (standard alphabet) of the x9.63 public key, as sent to the server.
    var publicKeyBase64: String { publicKeyX963.base64EncodedString() }

    /// Hex of the first 16 bytes of SHA-256 over the x9.63 public key.
    var deviceId: String { Self.deviceId(forPublicKeyX963: publicKeyX963) }

    static func deviceId(forPublicKeyX963 pub: Data) -> String {
        Data(SHA256.hash(data: pub).prefix(16)).cloudHex
    }

    /// THE signature layout (the server's `devauth` verifies exactly this; pinned by a Go-generated vector in the tests):
    ///
    ///     nonce     = 64 lowercase hex characters from POST /v1/auth/challenge (or the 32-char hex enrollChallenge)
    ///     message   = rawBytes(nonce) || UTF8(purpose)        -- the DECODED nonce bytes, no separator, no length
    ///     signature = ECDSA-P256-SHA256(message)               -- CryptoKit: key.signature(for: message)
    ///     encoding  = raw r || s, 64 bytes, base64 (standard alphabet, padded)
    ///
    /// Purposes: "account.create", "device.enroll", "device.confirm", "session", "library.recovery-blob", "library.reset".
    func sign(nonceHex: String, purpose: String) throws -> String {
        try privateKey.signature(for: Self.message(nonceHex: nonceHex, purpose: purpose)).rawRepresentation.base64EncodedString()
    }

    static func message(nonceHex: String, purpose: String) throws -> Data {
        guard let raw = Data(cloudHex: nonceHex) else { throw CloudCryptoError.malformedObject }
        return raw + Data(purpose.utf8)
    }

    /// For tests and verification: the same check the server performs.
    static func verify(signature: String, nonceHex: String, purpose: String, publicKeyX963: Data) -> Bool {
        guard let raw = Data(base64Encoded: signature), raw.count == 64,
              let message = try? Self.message(nonceHex: nonceHex, purpose: purpose),
              let pub = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return pub.isValidSignature(sig, for: message)
    }
}

extension Data {
    /// Bytes from a hex string (either case); nil for odd length or a non-hex character.
    nonisolated init?(cloudHex hex: String) {
        guard hex.utf8.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            case 65...70: v = c - 55
            default: return nil
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        self = out
    }
}
