//
//  CloudCrypto.swift
//  Whisperer
//
//  Client-side encryption for Whisperer Cloud (plan section 10). Every object is
//
//      header "WCV1" || keyVersion(1) || salt(16)                    (21 bytes)
//      then, per chunk:  u32 big-endian length L || AES-GCM ciphertext || 16-byte tag    (L counts ciphertext+tag)
//
//  The plaintext is cut into blocks of at most 1 MiB. Each block is compressed with Apple Compression LZFSE
//  BEFORE encryption (flag 1; stored raw with flag 0 when LZFSE would not shrink it), so one chunk's plaintext
//  is  flag(1) || payload. Per-block compression keeps memory bounded for huge files (Apple's streaming
//  LZFSE encoder buffers its whole input). The last chunk is the one with nothing after it (isFinal = 1).
//
//  objectKey = HKDF-SHA256(ikm: master, salt: object salt, info: "whisperer-obj-v1")
//  nonce     = 12-byte big-endian chunk counter (the key is unique per object, so counters never repeat)
//  AAD       = header(21) || u16 len || accountId(utf8) || u64 epoch || u16 len || objectName(utf8)
//              || u64 chunkIndex || isFinal(1 byte: 0 or 1)         (all integers big-endian)
//  Length-prefixing the strings keeps the concatenation unambiguous. The AAD binds a chunk to its object,
//  position, account, epoch and name, so reordering, truncation and cross-account/epoch/name swaps all fail.
//
//  authKey  = HKDF-SHA256(ikm: master, salt: empty, info: "whisperer-auth-v1")
//  verifier = SHA-256(authKey)                           (the server stores this only)
//  keyProof = hex HMAC-SHA256(key: SHA-256(authKey), message: challengeBytes || deviceId || suffix)
//

import Foundation
import CryptoKit
import Compression

nonisolated enum CloudCryptoError: Error, LocalizedError, Equatable {
    case badKeyLength
    case malformedObject
    case unknownKeyVersion(UInt8)
    case authenticationFailed
    case compressionFailed
    case decompressionFailed
    case io(String)

    var errorDescription: String? {
        switch self {
        case .badKeyLength: return "The key must be 32 bytes"
        case .malformedObject: return "The cloud object is malformed or truncated"
        case .unknownKeyVersion(let v): return "No key for version \(v)"
        case .authenticationFailed: return "The cloud object failed authentication"
        case .compressionFailed: return "Compression failed"
        case .decompressionFailed: return "Decompression failed"
        case .io(let m): return "File error: \(m)"
        }
    }
}

/// Where an object lives. Bound into every chunk's AAD.
nonisolated struct CloudObjectContext: Equatable, Sendable {
    let accountId: String
    let epoch: UInt64
    let objectName: String
}

/// Result of an encryption run, for the upload step (the server compares crc32c with Cloud Storage's).
nonisolated struct CloudEncryptionSummary: Equatable, Sendable {
    let ciphertextBytes: Int
    let crc32c: UInt32
}

nonisolated enum CloudCrypto {
    static let magic: [UInt8] = Array("WCV1".utf8)
    static let saltLength = 16
    static let headerLength = 4 + 1 + saltLength
    static let chunkSize = 1 << 20
    static let tagLength = 16
    static let objectInfo = Data("whisperer-obj-v1".utf8)
    static let authInfo = Data("whisperer-auth-v1".utf8)

    // MARK: - Data to Data

    static func encrypt(_ plaintext: Data, key: SymmetricKey, keyVersion: UInt8, context: CloudObjectContext) throws -> Data {
        var out = Data()
        let enc = try CloudStreamEncryptor(key: key, keyVersion: keyVersion, context: context)
        try enc.write(plaintext) { out.append($0) }
        try enc.finish { out.append($0) }
        return out
    }

    /// `keyForVersion` is the key ring lookup; an unknown version throws `.unknownKeyVersion`.
    static func decrypt(_ blob: Data, keyForVersion: @escaping (UInt8) -> SymmetricKey?, context: CloudObjectContext) throws -> Data {
        var out = Data()
        let dec = CloudStreamDecryptor(keyForVersion: keyForVersion, context: context)
        try dec.write(blob) { out.append($0) }
        try dec.finish { out.append($0) }
        return out
    }

    static func decrypt(_ blob: Data, key: SymmetricKey, keyVersion: UInt8, context: CloudObjectContext) throws -> Data {
        try decrypt(blob, keyForVersion: { $0 == keyVersion ? key : nil }, context: context)
    }

    /// The key version recorded in an object's header, without decrypting.
    static func keyVersion(ofHeader blob: Data) throws -> UInt8 {
        guard blob.count >= headerLength, Array(blob.prefix(4)) == magic else { throw CloudCryptoError.malformedObject }
        return blob[blob.startIndex + 4]
    }

    // MARK: - File to file (bounded memory)

    static func encryptFile(from source: URL, to destination: URL, key: SymmetricKey, keyVersion: UInt8,
                            context: CloudObjectContext) throws -> CloudEncryptionSummary {
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            output = try FileHandle(forWritingTo: destination)
        } catch { throw CloudCryptoError.io(error.localizedDescription) }
        defer { try? input.close(); try? output.close() }
        var crc = CloudCRC32C()
        var total = 0
        do {
            let enc = try CloudStreamEncryptor(key: key, keyVersion: keyVersion, context: context)
            let emit: (Data) throws -> Void = { piece in
                crc.update(piece); total += piece.count
                try output.write(contentsOf: piece)
            }
            while true {
                let piece = try autoreleasepool { try input.read(upToCount: chunkSize) } ?? Data()
                if piece.isEmpty { break }
                try enc.write(piece, emit: emit)
            }
            try enc.finish(emit: emit)
        } catch let e as CloudCryptoError {
            try? FileManager.default.removeItem(at: destination); throw e
        } catch {
            try? FileManager.default.removeItem(at: destination); throw CloudCryptoError.io(error.localizedDescription)
        }
        return CloudEncryptionSummary(ciphertextBytes: total, crc32c: crc.value)
    }

    /// On any failure the partial output is deleted: never leave unauthenticated plaintext behind.
    static func decryptFile(from source: URL, to destination: URL, keyForVersion: @escaping (UInt8) -> SymmetricKey?,
                            context: CloudObjectContext) throws {
        let input: FileHandle
        let output: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            output = try FileHandle(forWritingTo: destination)
        } catch { throw CloudCryptoError.io(error.localizedDescription) }
        defer { try? input.close(); try? output.close() }
        do {
            let dec = CloudStreamDecryptor(keyForVersion: keyForVersion, context: context)
            let emit: (Data) throws -> Void = { try output.write(contentsOf: $0) }
            while true {
                let piece = try autoreleasepool { try input.read(upToCount: chunkSize) } ?? Data()
                if piece.isEmpty { break }
                try dec.write(piece, emit: emit)
            }
            try dec.finish(emit: emit)
        } catch let e as CloudCryptoError {
            try? FileManager.default.removeItem(at: destination); throw e
        } catch {
            try? FileManager.default.removeItem(at: destination); throw CloudCryptoError.io(error.localizedDescription)
        }
    }

    // MARK: - Keys, verifier, proof

    static func symmetricKey(_ bytes: Data) throws -> SymmetricKey {
        guard bytes.count == 32 else { throw CloudCryptoError.badKeyLength }
        return SymmetricKey(data: bytes)
    }

    static func objectKey(master: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: objectInfo, outputByteCount: 32)
    }

    static func authKey(master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data(), info: authInfo, outputByteCount: 32)
    }

    /// SHA-256(authKey), 32 bytes. Sent to the server once, at library creation.
    static func verifier(authKey: SymmetricKey) -> Data {
        Data(SHA256.hash(data: authKey.withUnsafeBytes { Data($0) }))
    }

    /// The key proof the server checks (server/internal/devauth KeyProof):
    ///
    ///     key = verifier = SHA-256(authKey)            -- the server stores only this, so it is the HMAC key
    ///     msg = rawBytes(challengeHex) || ASCII(deviceId) || ASCII(suffix)
    ///     proof = lowercase hex of HMAC-SHA256(key, msg)
    ///
    /// challenge: the 32-char hex enrollChallenge (suffix "") or a 64-char hex nonce; suffix is "" for device
    /// enrolment and "library.recovery" when replacing the recovery blob.
    static func keyProof(authKey: SymmetricKey, challengeHex: String, deviceId: String, suffix: String = "") throws -> String {
        guard let challenge = Data(cloudHex: challengeHex) else { throw CloudCryptoError.malformedObject }
        let key = SymmetricKey(data: verifier(authKey: authKey))
        let message = challenge + Data(deviceId.utf8) + Data(suffix.utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).cloudHex
    }

    // MARK: - Internals

    static func aad(header: Data, context: CloudObjectContext, chunkIndex: UInt64, isFinal: Bool) -> Data {
        var d = header
        let account = Data(context.accountId.utf8), name = Data(context.objectName.utf8)
        d.append(contentsOf: be16(account.count)); d.append(account)
        d.append(contentsOf: be64(context.epoch))
        d.append(contentsOf: be16(name.count)); d.append(name)
        d.append(contentsOf: be64(chunkIndex))
        d.append(isFinal ? 1 : 0)
        return d
    }

    static func nonce(chunkIndex: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data(be64(chunkIndex)))
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    static func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xff) } }
}

// MARK: - Streaming encryptor / decryptor

/// Block flags inside each chunk's plaintext: 0 = stored, 1 = LZFSE.
private nonisolated enum BlockCodec {
    static func pack(_ block: Data) throws -> Data {
        if !block.isEmpty {
            var out = [UInt8](repeating: 0, count: block.count)
            let n = block.withUnsafeBytes { src in
                compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, block.count, nil, COMPRESSION_LZFSE)
            }
            if n > 0 && n < block.count { return Data([1]) + Data(out[0..<n]) }   // only when it actually shrinks
        }
        return Data([0]) + block
    }

    static func unpack(_ plain: Data) throws -> Data {
        guard let flag = plain.first else { throw CloudCryptoError.malformedObject }
        let body = plain.dropFirst()
        switch flag {
        case 0: return Data(body)
        case 1:
            guard !body.isEmpty else { throw CloudCryptoError.malformedObject }
            var out = [UInt8](repeating: 0, count: CloudCrypto.chunkSize)
            let n = body.withUnsafeBytes { src in
                compression_decode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_LZFSE)
            }
            guard n > 0 else { throw CloudCryptoError.decompressionFailed }
            return Data(out[0..<n])
        default: throw CloudCryptoError.malformedObject
        }
    }
}

nonisolated final class CloudStreamEncryptor {
    private let objectKey: SymmetricKey
    private let header: Data
    private let context: CloudObjectContext
    private var pending = Data()
    private var chunkIndex: UInt64 = 0
    private var wroteHeader = false

    init(key: SymmetricKey, keyVersion: UInt8, context: CloudObjectContext) throws {
        guard key.bitCount == 256 else { throw CloudCryptoError.badKeyLength }
        var salt = Data(count: CloudCrypto.saltLength)
        let ok = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, CloudCrypto.saltLength, $0.baseAddress!) }
        guard ok == errSecSuccess else { throw CloudCryptoError.io("random salt unavailable") }
        var h = Data(CloudCrypto.magic); h.append(keyVersion); h.append(salt)
        self.header = h
        self.objectKey = CloudCrypto.objectKey(master: key, salt: salt)
        self.context = context
    }

    func write(_ plaintext: Data, emit: (Data) throws -> Void) throws {
        try emitHeader(emit)
        pending.append(plaintext)
        // Keep at least one byte pending so the last block can be sealed as final.
        while pending.count > CloudCrypto.chunkSize {
            let block = Data(pending.prefix(CloudCrypto.chunkSize))
            pending = Data(pending.dropFirst(CloudCrypto.chunkSize))
            try seal(block, isFinal: false, emit)
        }
    }

    func finish(emit: (Data) throws -> Void) throws {
        try emitHeader(emit)
        let last = pending
        pending = Data()
        try seal(last, isFinal: true, emit)
    }

    private func emitHeader(_ emit: (Data) throws -> Void) throws {
        if !wroteHeader { wroteHeader = true; try emit(header) }
    }

    private func seal(_ block: Data, isFinal: Bool, _ emit: (Data) throws -> Void) throws {
        let aad = CloudCrypto.aad(header: header, context: context, chunkIndex: chunkIndex, isFinal: isFinal)
        let box = try AES.GCM.seal(try BlockCodec.pack(block), using: objectKey,
                                   nonce: CloudCrypto.nonce(chunkIndex: chunkIndex), authenticating: aad)
        chunkIndex += 1
        let body = box.ciphertext + box.tag
        var framed = Data(CloudCrypto.be32(body.count))
        framed.append(body)
        try emit(framed)
    }
}

nonisolated final class CloudStreamDecryptor {
    private let keyForVersion: (UInt8) -> SymmetricKey?
    private let context: CloudObjectContext
    private var buffer = Data()
    private var header: Data?
    private var objectKey: SymmetricKey?
    private var chunkIndex: UInt64 = 0
    /// Largest legal chunk body: flag + 1 MiB + tag.
    private static let maxBody = 1 + CloudCrypto.chunkSize + CloudCrypto.tagLength

    init(keyForVersion: @escaping (UInt8) -> SymmetricKey?, context: CloudObjectContext) {
        self.keyForVersion = keyForVersion
        self.context = context
    }

    func write(_ cipher: Data, emit: (Data) throws -> Void) throws {
        buffer.append(cipher)
        try parseHeaderIfPossible()
        guard header != nil else { return }
        // A chunk is final only if nothing follows it: decrypt only when bytes beyond it are buffered.
        while let len = try peekLength(), buffer.count > 4 + len {
            let body = Data(buffer[buffer.startIndex + 4 ..< buffer.startIndex + 4 + len])
            buffer = Data(buffer.dropFirst(4 + len))
            try open(body, isFinal: false, emit)
        }
    }

    func finish(emit: (Data) throws -> Void) throws {
        try parseHeaderIfPossible()
        guard header != nil, let len = try peekLength(), buffer.count == 4 + len else { throw CloudCryptoError.malformedObject }
        let body = Data(buffer.dropFirst(4))
        buffer = Data()
        try open(body, isFinal: true, emit)
    }

    private func peekLength() throws -> Int? {
        guard buffer.count >= 4 else { return nil }
        let s = buffer.startIndex
        let len = Int(buffer[s]) << 24 | Int(buffer[s + 1]) << 16 | Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
        guard len >= 1 + CloudCrypto.tagLength, len <= Self.maxBody else { throw CloudCryptoError.malformedObject }
        return len
    }

    private func parseHeaderIfPossible() throws {
        guard header == nil, buffer.count >= CloudCrypto.headerLength else { return }
        let h = Data(buffer.prefix(CloudCrypto.headerLength))
        guard Array(h.prefix(4)) == CloudCrypto.magic else { throw CloudCryptoError.malformedObject }
        let version = h[h.startIndex + 4]
        guard let master = keyForVersion(version) else { throw CloudCryptoError.unknownKeyVersion(version) }
        guard master.bitCount == 256 else { throw CloudCryptoError.badKeyLength }
        objectKey = CloudCrypto.objectKey(master: master, salt: h.suffix(CloudCrypto.saltLength))
        header = h
        buffer = Data(buffer.dropFirst(CloudCrypto.headerLength))
    }

    private func open(_ body: Data, isFinal: Bool, _ emit: (Data) throws -> Void) throws {
        guard let header, let objectKey, body.count >= CloudCrypto.tagLength else { throw CloudCryptoError.malformedObject }
        let aad = CloudCrypto.aad(header: header, context: context, chunkIndex: chunkIndex, isFinal: isFinal)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: CloudCrypto.nonce(chunkIndex: chunkIndex),
                                            ciphertext: body.prefix(body.count - CloudCrypto.tagLength),
                                            tag: body.suffix(CloudCrypto.tagLength))
            plain = try AES.GCM.open(box, using: objectKey, authenticating: aad)
        } catch { throw CloudCryptoError.authenticationFailed }
        chunkIndex += 1
        try emit(try BlockCodec.unpack(plain))
    }
}

// MARK: - CRC32C (Castagnoli), as Cloud Storage reports

nonisolated struct CloudCRC32C: Sendable {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0x82F6_3B78 : c >> 1 }
        return c
    }
    private var state: UInt32 = 0xFFFF_FFFF

    init() {}

    mutating func update(_ data: Data) {
        var c = state
        for b in data { c = Self.table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        state = c
    }

    var value: UInt32 { ~state }

    static func checksum(_ data: Data) -> UInt32 {
        var c = CloudCRC32C(); c.update(data); return c.value
    }

    /// Cloud Storage's `crc32c` metadata form: base64 of the big-endian 4 bytes.
    static func base64(_ value: UInt32) -> String {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]).base64EncodedString()
    }
}

nonisolated extension Data {
    var cloudHex: String { map { String(format: "%02x", $0) }.joined() }
    var cloudBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
