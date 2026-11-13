//
//  CloudClient.swift
//  Whisperer
//
//  The identity and library API of Whisperer Cloud (server/internal/server/identity_http.go, library_http.go;
//  wire formats in docs/exec-plans/cloud-sync-implementation.md section 2.4). DTOs mirror the server JSON
//  field for field. Device-signed calls ask for a fresh nonce and sign it with `CloudDeviceKey.sign(nonceHex:purpose:)`;
//  key proofs come from `CloudCrypto.keyProof`. Nothing here stores or logs a token, a JWS or a key.
//

import Foundation
import CryptoKit

// MARK: - DTOs

nonisolated enum CloudServerState: String, Codable, Sendable {
    case active, grace, lapsed, sealed
    case softDeleted = "soft_deleted"
    case deleted
    case unknown

    init(from decoder: Decoder) throws {
        self = CloudServerState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

nonisolated struct CloudPlanSummary: Codable, Equatable, Sendable {
    var name: String
    var storedBytes: Int64
    var monthlyDownloadBytes: Int64
    var monthlyUploadGrants: Int
}

nonisolated struct CloudLibraryInfo: Codable, Equatable, Sendable {
    var exists: Bool
    var keyVersion: Int
    var recoveryAvailable: Bool
}

/// Answer of POST /v1/accounts, /v1/devices/confirm and /v1/session. `token` is a secret: never log this value.
nonisolated struct CloudSession: Codable, Equatable, Sendable, CustomStringConvertible {
    var accountId: String
    var deviceId: String
    var epoch: Int
    var token: String
    var expiresAt: Date
    var state: CloudServerState
    var readOnly: Bool
    var plan: CloudPlanSummary
    var paidUntil: Date
    var library: CloudLibraryInfo
    var serverTime: Date

    var description: String { "CloudSession(epoch \(epoch), \(state.rawValue), readOnly \(readOnly))" }
}

/// Answer of POST /v1/devices: the Mac is pending and holds no data access yet.
nonisolated struct CloudEnrollment: Codable, Equatable, Sendable {
    var deviceId: String
    var library: CloudLibraryInfo
    var enrollChallenge: String
    var expiresAt: Date
}

nonisolated enum CloudDeviceState: String, Codable, Sendable {
    case pending, authorized, revoked, unknown

    init(from decoder: Decoder) throws {
        self = CloudDeviceState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

nonisolated struct CloudDeviceInfo: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var state: CloudDeviceState
    var current: Bool
    var labelEnc: String?
    var enrolledAt: Date
    var lastSeenAt: Date?
    var expiresAt: Date?
}

/// Server field names are Go's untagged struct fields.
nonisolated struct CloudUsage: Codable, Equatable, Sendable {
    var storedBytes: Int64
    var downloadBytes: Int64
    var uploadGrants: Int

    enum CodingKeys: String, CodingKey { case storedBytes = "StoredBytes", downloadBytes = "DownloadBytes", uploadGrants = "UploadGrants" }
}

nonisolated struct CloudAccountInfo: Codable, Equatable, Sendable {
    var accountId: String
    var epoch: Int
    var state: CloudServerState
    var paidUntil: Date
    var autoRenew: Bool
    var deleteAfter: Date?
    var plan: CloudPlanSummary
    var deviceLimit: Int
    var usage: CloudUsage?
    var library: CloudLibraryInfo
    var devices: [CloudDeviceInfo]
}

nonisolated struct CloudRecoveryBlob: Codable, Equatable, Sendable {
    var wrapped: String
    var kdf: String
    var keyVersion: Int
}

nonisolated struct CloudResetResult: Codable, Equatable, Sendable {
    var epoch: Int
    var token: String
    var expiresAt: Date
    var library: CloudLibraryInfo
}

nonisolated enum CloudLibraryCreation: Equatable, Sendable {
    case created(keyVersion: Int)
    /// 409 library_exists: another Mac won the race (or the library was created earlier). The caller must adopt
    /// the existing key and discard the one it generated.
    case alreadyExists(CloudLibraryInfo)
}

// MARK: - Recovery blob encoding (what the server stores opaquely)

/// The server keeps `wrapped` and `kdf` as opaque strings. `wrapped` is the base64 of `CloudRecoveryKey.wrap`'s
/// output; `kdf` names the scheme and carries the account id, because the AEAD binds the blob to
/// `accountId || keyVersion` and a pending Mac (which has no session) is not told its account id otherwise. The id is
/// authenticated by the AEAD itself: a forged one makes the unwrap fail.
nonisolated enum CloudRecoveryBlobCodec {
    static let scheme = "whisperer-recovery-v1"

    static func kdf(accountId: String) -> String { "\(scheme);acct=\(accountId)" }

    static func accountId(fromKdf kdf: String) -> String? {
        let parts = kdf.split(separator: ";")
        guard parts.first == Substring(scheme), let acct = parts.dropFirst().first(where: { $0.hasPrefix("acct=") }) else { return nil }
        let id = String(acct.dropFirst(5))
        return id.isEmpty ? nil : id
    }
}

// MARK: - Client

nonisolated struct CloudClient: Sendable {
    let http: CloudHTTP
    /// For the session-token routes (account, library, devices). Not needed for the device-signed ones.
    let tokens: CloudTokenProvider?

    init(http: CloudHTTP, tokens: CloudTokenProvider? = nil) {
        self.http = http
        self.tokens = tokens
    }

    // MARK: plumbing

    private func post<Req: Encodable, Res: Decodable>(_ path: String, _ body: Req, as: Res.Type) async throws -> Res {
        try decode(try await http.send("POST", path, body: try CloudJSON.encode(body)))
    }

    private func authed<Req: Encodable>(_ method: String, _ path: String, _ body: Req) async throws -> Data {
        guard let tokens else { throw CloudAPIError(status: 401, code: "unauthorized", message: "No session", retryAfter: nil, body: Data()) }
        return try await http.authed(method, path, body: try CloudJSON.encode(body), tokens: tokens)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try CloudJSON.decoder.decode(T.self, from: data) } catch {
            throw CloudAPIError(status: 200, code: "bad_response", message: "The server's answer could not be read", retryAfter: nil, body: Data())
        }
    }

    // MARK: challenge and device signatures

    /// A fresh nonce for `deviceId`. Valid 60 to 120 seconds; not single-use.
    func challenge(deviceId: String) async throws -> String {
        nonisolated struct Request: Encodable { var deviceId: String }
        nonisolated struct Response: Decodable { var nonce: String }
        return try await post("/v1/auth/challenge", Request(deviceId: deviceId), as: Response.self).nonce
    }

    private func signed(_ device: CloudDeviceKey, purpose: String) async throws -> (nonce: String, sig: String) {
        let nonce = try await challenge(deviceId: device.deviceId)
        return (nonce, try device.sign(nonceHex: nonce, purpose: purpose))
    }

    // MARK: identity

    nonisolated private struct EnrolBody: Encodable {
        var transactionJWS: String
        var devicePublicKey: String
        var nonce: String
        var sig: String
        var labelEnc: String?
        var appVersion: String?
    }

    /// POST /v1/accounts — the first device of a new purchase. 409 `already_bound` means: enrol instead.
    func createAccount(transactionJWS: String, device: CloudDeviceKey, labelEnc: String? = nil, appVersion: String? = nil) async throws -> CloudSession {
        let s = try await signed(device, purpose: "account.create")
        return try await post("/v1/accounts", EnrolBody(transactionJWS: transactionJWS, devicePublicKey: device.publicKeyBase64, nonce: s.nonce, sig: s.sig,
                                                        labelEnc: labelEnc, appVersion: appVersion), as: CloudSession.self)
    }

    /// POST /v1/devices — a new Mac for an existing account: pending until the key is proved.
    func enrollDevice(transactionJWS: String, device: CloudDeviceKey, labelEnc: String? = nil, appVersion: String? = nil) async throws -> CloudEnrollment {
        let s = try await signed(device, purpose: "device.enroll")
        return try await post("/v1/devices", EnrolBody(transactionJWS: transactionJWS, devicePublicKey: device.publicKeyBase64, nonce: s.nonce, sig: s.sig,
                                                       labelEnc: labelEnc, appVersion: appVersion), as: CloudEnrollment.self)
    }

    /// POST /v1/devices/confirm. `keyProof` is `CloudCrypto.keyProof(... enrollChallenge ...)`; empty when the
    /// library does not exist yet (nothing to prove).
    func confirmDevice(device: CloudDeviceKey, keyProof: String) async throws -> CloudSession {
        nonisolated struct Body: Encodable { var deviceId: String; var nonce: String; var sig: String; var keyProof: String }
        let s = try await signed(device, purpose: "device.confirm")
        return try await post("/v1/devices/confirm", Body(deviceId: device.deviceId, nonce: s.nonce, sig: s.sig, keyProof: keyProof), as: CloudSession.self)
    }

    /// POST /v1/session — renews the session token. The JWS (optional) refreshes the entitlement.
    func session(device: CloudDeviceKey, transactionJWS: String?) async throws -> CloudSession {
        nonisolated struct Body: Encodable { var deviceId: String; var nonce: String; var sig: String; var transactionJWS: String? }
        let s = try await signed(device, purpose: "session")
        return try await post("/v1/session", Body(deviceId: device.deviceId, nonce: s.nonce, sig: s.sig, transactionJWS: transactionJWS), as: CloudSession.self)
    }

    func account() async throws -> CloudAccountInfo {
        try decode(try await http.authed("GET", "/v1/account", tokens: tokens ?? { _ in throw CloudAPIError(status: 401, code: "unauthorized", message: "No session", retryAfter: nil, body: Data()) }))
    }

    /// DELETE /v1/devices/{id} — idempotent; the device can never enrol again.
    func revokeDevice(id: String) async throws {
        guard let tokens else { throw CloudAPIError(status: 401, code: "unauthorized", message: "No session", retryAfter: nil, body: Data()) }
        _ = try await http.authed("DELETE", "/v1/devices/\(id)", tokens: tokens)
    }

    // MARK: library

    /// POST /v1/library — create-if-absent. Call only with a key generated after the server said no library exists.
    func createLibrary(keyVerifierHex: String, keyVersion: Int) async throws -> CloudLibraryCreation {
        nonisolated struct Body: Encodable { var keyVerifier: String; var keyVersion: Int }
        nonisolated struct Created: Decodable { var keyVersion: Int }
        do {
            let created: Created = try decode(try await authed("POST", "/v1/library", Body(keyVerifier: keyVerifierHex, keyVersion: keyVersion)))
            return .created(keyVersion: created.keyVersion)
        } catch let error as CloudAPIError where error.status == 409 && error.code == "library_exists" {
            return .alreadyExists(error.decode(CloudLibraryInfo.self, key: "library") ?? CloudLibraryInfo(exists: true, keyVersion: 1, recoveryAvailable: false))
        }
    }

    /// PUT /v1/library/recovery — replaces the recovery blob; needs a fresh key proof (suffix "library.recovery").
    func putRecovery(device: CloudDeviceKey, authKey: SymmetricKey, wrapped: String, kdf: String) async throws {
        nonisolated struct Body: Encodable { var wrapped: String; var kdf: String; var nonce: String; var keyProof: String }
        let nonce = try await challenge(deviceId: device.deviceId)
        let proof = try CloudCrypto.keyProof(authKey: authKey, challengeHex: nonce, deviceId: device.deviceId, suffix: "library.recovery")
        _ = try await authed("PUT", "/v1/library/recovery", Body(wrapped: wrapped, kdf: kdf, nonce: nonce, keyProof: proof))
    }

    /// POST /v1/library/recovery-blob — usable by a pending device; useless without the recovery key.
    func recoveryBlob(device: CloudDeviceKey, transactionJWS: String) async throws -> CloudRecoveryBlob {
        nonisolated struct Body: Encodable { var deviceId: String; var nonce: String; var sig: String; var transactionJWS: String }
        let s = try await signed(device, purpose: "library.recovery-blob")
        return try await post("/v1/library/recovery-blob", Body(deviceId: device.deviceId, nonce: s.nonce, sig: s.sig, transactionJWS: transactionJWS), as: CloudRecoveryBlob.self)
    }

    /// POST /v1/library/reset with the session (S path). `confirm` must be exactly "RESET MY LIBRARY".
    func resetLibrary(confirm: String) async throws -> CloudResetResult {
        nonisolated struct Body: Encodable { var confirm: String }
        return try decode(try await authed("POST", "/v1/library/reset", Body(confirm: confirm)))
    }

    /// POST /v1/library/reset with a device signature and a transaction (D+A path, the lost-key case).
    func resetLibrary(confirm: String, device: CloudDeviceKey, transactionJWS: String) async throws -> CloudResetResult {
        nonisolated struct Body: Encodable { var confirm: String; var deviceId: String; var nonce: String; var sig: String; var transactionJWS: String }
        let s = try await signed(device, purpose: "library.reset")
        return try await post("/v1/library/reset", Body(confirm: confirm, deviceId: device.deviceId, nonce: s.nonce, sig: s.sig, transactionJWS: transactionJWS), as: CloudResetResult.self)
    }
}
