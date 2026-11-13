import XCTest
import CryptoKit
@testable import whisperer

final class CloudCryptoTests: XCTestCase {
    private let master = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    private let ctx = CloudObjectContext(accountId: "0123456789abcdef0123456789abcdef", epoch: 1, objectName: "changes/dev/000001.bin")
    private let mib = 1 << 20

    private func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    private func enc(_ p: Data, _ c: CloudObjectContext? = nil) throws -> Data {
        try CloudCrypto.encrypt(p, key: master, keyVersion: 1, context: c ?? ctx)
    }
    private func dec(_ b: Data, key: SymmetricKey? = nil, version: UInt8 = 1, _ c: CloudObjectContext? = nil) throws -> Data {
        try CloudCrypto.decrypt(b, key: key ?? master, keyVersion: version, context: c ?? ctx)
    }

    // MARK: round trips

    func testRoundTripSmall() throws {
        let p = Data("hello whisperer cloud".utf8)
        let blob = try enc(p)
        XCTAssertEqual(Array(blob.prefix(4)), Array("WCV1".utf8))
        XCTAssertEqual(blob[4], 1)
        XCTAssertEqual(try dec(blob), p)
    }

    func testEmptyPlaintext() throws {
        let blob = try enc(Data())
        XCTAssertGreaterThan(blob.count, CloudCrypto.headerLength + CloudCrypto.tagLength - 1)
        XCTAssertEqual(try dec(blob), Data())
    }

    func testChunkBoundaries() throws {
        for n in [mib - 1, mib, mib + 1, 3 * mib + 17] {
            let p = random(n)
            XCTAssertEqual(try dec(try enc(p)), p, "size \(n)")
        }
    }

    func testCompressibleDataShrinksAndRoundTrips() throws {
        let p = Data(repeating: 0x61, count: 5 * mib)
        let blob = try enc(p)
        XCTAssertLessThan(blob.count, mib)
        XCTAssertEqual(try dec(blob), p)
    }

    func testSaltIsRandomPerObject() throws {
        let p = Data("same".utf8)
        let a = try enc(p), b = try enc(p)
        XCTAssertNotEqual(a.subdata(in: 5..<21), b.subdata(in: 5..<21))
        XCTAssertNotEqual(a, b)
    }

    func testKeyVersionInHeader() throws {
        let blob = try CloudCrypto.encrypt(Data("x".utf8), key: master, keyVersion: 7, context: ctx)
        XCTAssertEqual(try CloudCrypto.keyVersion(ofHeader: blob), 7)
        XCTAssertThrowsError(try CloudCrypto.keyVersion(ofHeader: Data("nope".utf8)))
    }

    // MARK: tamper detection

    private func multiChunkBlob() throws -> (Data, Data) {
        let p = random(2 * mib + 1000)      // incompressible => 3 chunks
        return (p, try enc(p))
    }

    /// (offset, total length incl. 4-byte prefix) of each chunk after the 21-byte header.
    private func chunks(_ blob: Data) -> [(Int, Int)] {
        var out: [(Int, Int)] = []; var o = 21
        while o < blob.count {
            let len = Int(blob[o]) << 24 | Int(blob[o + 1]) << 16 | Int(blob[o + 2]) << 8 | Int(blob[o + 3])
            out.append((o, 4 + len)); o += 4 + len
        }
        return out
    }

    func testFlipEveryRegion() throws {
        let (_, blob) = try multiChunkBlob()
        let cs = chunks(blob)
        XCTAssertEqual(cs.count, 3)
        var offsets = [0, 3, 4, 5, 12, 20]                                  // magic, version, salt
        for (o, n) in cs { offsets += [o, o + 3, o + 4, o + 5, o + n / 2, o + n - 17, o + n - 1] }   // length, flag, body, tag
        for o in offsets {
            var t = blob; t[o] ^= 0x01
            XCTAssertThrowsError(try CloudCrypto.decrypt(t, keyForVersion: { _ in self.master }, context: ctx), "offset \(o)")
        }
    }

    func testTruncation() throws {
        let (_, blob) = try multiChunkBlob()
        let cs = chunks(blob)
        XCTAssertThrowsError(try dec(blob.dropLast(1)))
        XCTAssertThrowsError(try dec(blob.prefix(cs[1].0)))                 // drop chunks 1 and 2 at a boundary
        XCTAssertThrowsError(try dec(blob.prefix(cs[2].0)))                 // drop only the final chunk
        XCTAssertThrowsError(try dec(blob.prefix(21)))
        XCTAssertThrowsError(try dec(blob.prefix(10)))
        XCTAssertThrowsError(try dec(Data()))
    }

    func testAppendedBytesRejected() throws {
        let (_, blob) = try multiChunkBlob()
        XCTAssertThrowsError(try dec(blob + Data([0])))
        XCTAssertThrowsError(try dec(blob + Data(repeating: 0, count: 40)))
    }

    func testChunkReorderRejected() throws {
        let (_, blob) = try multiChunkBlob()
        let cs = chunks(blob)
        let header = blob.prefix(21)
        let c = cs.map { blob.subdata(in: $0.0..<($0.0 + $0.1)) }
        XCTAssertThrowsError(try dec(header + c[1] + c[0] + c[2]))
        XCTAssertThrowsError(try dec(header + c[0] + c[0] + c[2]))
        XCTAssertThrowsError(try dec(header + c[0] + c[2] + c[1]))
        XCTAssertEqual(try dec(header + c[0] + c[1] + c[2]).count, 2 * mib + 1000)
    }

    func testChunkSwapBetweenObjectsRejected() throws {
        let a = try enc(random(2 * mib)), b = try enc(random(2 * mib))
        let ca = chunks(a), cb = chunks(b)
        let franken = a.prefix(ca[1].0) + b.subdata(in: cb[1].0..<b.count)
        XCTAssertThrowsError(try dec(franken))
    }

    func testWrongContextRejected() throws {
        let blob = try enc(Data("secret".utf8))
        XCTAssertThrowsError(try dec(blob, CloudObjectContext(accountId: "fedcba9876543210fedcba9876543210", epoch: 1, objectName: ctx.objectName)))
        XCTAssertThrowsError(try dec(blob, CloudObjectContext(accountId: ctx.accountId, epoch: 2, objectName: ctx.objectName)))
        XCTAssertThrowsError(try dec(blob, CloudObjectContext(accountId: ctx.accountId, epoch: 1, objectName: "changes/dev/000002.bin")))
        XCTAssertEqual(try dec(blob, ctx), Data("secret".utf8))
    }

    func testWrongKeyAndVersion() throws {
        let blob = try enc(Data("secret".utf8))
        XCTAssertThrowsError(try dec(blob, key: SymmetricKey(data: random(32)))) { e in
            XCTAssertEqual(e as? CloudCryptoError, .authenticationFailed)
        }
        XCTAssertThrowsError(try dec(blob, version: 2)) { e in
            XCTAssertEqual(e as? CloudCryptoError, .unknownKeyVersion(1))
        }
        // Header says v1; a ring answering v1 with another key fails authentication.
        XCTAssertThrowsError(try CloudCrypto.decrypt(blob, keyForVersion: { _ in SymmetricKey(data: self.random(32)) }, context: ctx))
        // Header version changed to one the ring lacks.
        var t = blob; t[4] = 2
        XCTAssertThrowsError(try dec(t))
    }

    func testBadKeyLength() {
        XCTAssertThrowsError(try CloudCrypto.symmetricKey(Data(count: 31)))
        XCTAssertThrowsError(try CloudCrypto.encrypt(Data(), key: SymmetricKey(size: .bits128), keyVersion: 1, context: ctx))
    }

    // MARK: streaming API

    func testStreamingMatchesOneShotInSmallWrites() throws {
        let p = random(mib + 4321)
        let e = try CloudStreamEncryptor(key: master, keyVersion: 1, context: ctx)
        var blob = Data()
        var i = 0
        while i < p.count { let j = min(i + 77_777, p.count); try e.write(p[i..<j]) { blob.append($0) }; i = j }
        try e.finish { blob.append($0) }
        // decrypt in odd-sized pieces
        let d = CloudStreamDecryptor(keyForVersion: { _ in self.master }, context: ctx)
        var out = Data(); i = 0
        while i < blob.count { let j = min(i + 100_003, blob.count); try d.write(blob[i..<j]) { out.append($0) }; i = j }
        try d.finish { out.append($0) }
        XCTAssertEqual(out, p)
    }

    func testFileRoundTripAndCRC() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("a"), c = dir.appendingPathComponent("b"), out = dir.appendingPathComponent("c")
        let p = random(2 * mib + 5)
        try p.write(to: src)
        let summary = try CloudCrypto.encryptFile(from: src, to: c, key: master, keyVersion: 1, context: ctx)
        let blob = try Data(contentsOf: c)
        XCTAssertEqual(summary.ciphertextBytes, blob.count)
        XCTAssertEqual(summary.crc32c, CloudCRC32C.checksum(blob))
        try CloudCrypto.decryptFile(from: c, to: out, keyForVersion: { _ in self.master }, context: ctx)
        XCTAssertEqual(try Data(contentsOf: out), p)

        // Tampered file: output removed.
        var t = blob; t[blob.count - 5] ^= 0xff
        try t.write(to: c)
        XCTAssertThrowsError(try CloudCrypto.decryptFile(from: c, to: out, keyForVersion: { _ in self.master }, context: ctx))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testLargeFileStreamingBoundedMemory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-big-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("big"), c = dir.appendingPathComponent("big.enc"), out = dir.appendingPathComponent("big.out")
        FileManager.default.createFile(atPath: src.path, contents: nil)
        let h = try FileHandle(forWritingTo: src)
        for _ in 0..<40 { try h.write(contentsOf: random(mib)) }
        try h.close()
        let before = Self.footprint()
        _ = try CloudCrypto.encryptFile(from: src, to: c, key: master, keyVersion: 1, context: ctx)
        try CloudCrypto.decryptFile(from: c, to: out, keyForVersion: { _ in self.master }, context: ctx)
        let growth = Self.footprint() - before
        XCTAssertLessThan(growth, 30 * mib, "memory grew by \(growth / mib) MiB for a 40 MiB file")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int, 40 * mib)
        // Spot-check content equality by hash, streamed.
        XCTAssertEqual(try Self.sha256(of: src), try Self.sha256(of: out))
    }

    private static func sha256(of url: URL) throws -> Data {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return Data(hasher.finalize())
    }

    private static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // MARK: known answers (computed with openssl kdf / dgst, not with this code)

    func testKnownAnswerVectors() throws {
        let salt = Data((0..<16).map { UInt8(0xA0 + $0) })
        let objKey = CloudCrypto.objectKey(master: master, salt: salt)
        XCTAssertEqual(objKey.withUnsafeBytes { Data($0) }.cloudHex, "bb87465148b3459effdeacd78f0acb0602a616918f365d0b40852a2c91086799")

        let auth = CloudCrypto.authKey(master: master)
        XCTAssertEqual(auth.withUnsafeBytes { Data($0) }.cloudHex, "43b7e32817068c0eefe588fc8653cd23796c8f7c1a5d9a91ac441d18b327a260")
        XCTAssertEqual(CloudCrypto.verifier(authKey: auth).cloudHex, "4339b85f014ed0713ed7ec763b4742f343a17d3728448517eb0126a61223d671")
        let kek = try CloudRecoveryKey.kek(recoveryKey: Data((0..<32).map { UInt8($0) }))
        XCTAssertEqual(kek.withUnsafeBytes { Data($0) }.cloudHex, "4586365c5f67a6c258d0648d7831cff5ecbe21b4a11e7041ca8e264f7c970025")
    }

    func testCRC32CKnownAnswers() {
        XCTAssertEqual(CloudCRC32C.checksum(Data("123456789".utf8)), 0xE306_9283)
        XCTAssertEqual(CloudCRC32C.checksum(Data()), 0)
        XCTAssertEqual(CloudCRC32C.checksum(Data(count: 32)), 0x8A91_36AA)   // RFC 3720 B.4: 32 zero bytes
        var c = CloudCRC32C(); c.update(Data("1234".utf8)); c.update(Data("56789".utf8))
        XCTAssertEqual(c.value, 0xE306_9283)
        XCTAssertEqual(CloudCRC32C.base64(0xE306_9283), "4waSgw==")
    }

    func testNonceIsBigEndianCounter() throws {
        let n = try CloudCrypto.nonce(chunkIndex: 0x0102)
        XCTAssertEqual(n.withUnsafeBytes { Array($0) }, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2])
    }

    // MARK: device key

    func testDeviceKeySignatureLayoutAndId() throws {
        let kc = InMemoryCloudKeychain()
        let key = try CloudDeviceKey.loadOrCreate(keychain: kc)
        let again = try CloudDeviceKey.loadOrCreate(keychain: kc)
        XCTAssertEqual(key.deviceId, again.deviceId)
        XCTAssertEqual(key.publicKeyX963.count, 65)
        XCTAssertEqual(key.deviceId, Data(SHA256.hash(data: key.publicKeyX963).prefix(16)).cloudHex)
        XCTAssertEqual(key.deviceId.count, 32)
        XCTAssertEqual(Data(base64Encoded: key.publicKeyBase64), key.publicKeyX963)

        let nonce = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        let sig = try key.sign(nonceHex: nonce, purpose: "session")
        XCTAssertEqual(Data(base64Encoded: sig)?.count, 64, "raw r||s, standard base64")
        XCTAssertTrue(CloudDeviceKey.verify(signature: sig, nonceHex: nonce, purpose: "session", publicKeyX963: key.publicKeyX963))
        XCTAssertFalse(CloudDeviceKey.verify(signature: sig, nonceHex: nonce, purpose: "account.create", publicKeyX963: key.publicKeyX963))
        XCTAssertFalse(CloudDeviceKey.verify(signature: sig, nonceHex: String(nonce.dropLast()) + "e", purpose: "session", publicKeyX963: key.publicKeyX963))
        // Independent check of the layout: raw nonce BYTES then the purpose, hashed and verified by CryptoKit directly.
        let pub = try P256.Signing.PublicKey(x963Representation: key.publicKeyX963)
        let message = Data((0..<32).map { UInt8($0) }) + Data("session".utf8)
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: try XCTUnwrap(Data(base64Encoded: sig))), for: message))
    }

    /// Values produced by the server's own Go code (server/internal/devauth): the Mac must accept its signature and
    /// reproduce its key proofs byte for byte.
    func testWireFormatMatchesTheGoServer() throws {
        let pub = try XCTUnwrap(Data(base64Encoded: "BJEiKxI81j441bUkoO87HcSCtdWfw+k/HH6ygZOd7sAH3+kwuO7J9yNGbEZHQcBPB3E5yrK7YJrNrW7WNq3qU9c="))
        XCTAssertEqual(CloudDeviceKey.deviceId(forPublicKeyX963: pub), "6c9e095dba71bd2867b6ecc05ddfbdf0")
        let goSignature = "XykKTXNuRnOP3BpBekgH+I17yroW9L9W1ktjmARrgrpvHmhQKw0q26jX0qXanH4PbxJvT25zxc23X2btaoOP+w=="
        let nonce = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        XCTAssertTrue(CloudDeviceKey.verify(signature: goSignature, nonceHex: nonce, purpose: "session", publicKeyX963: pub),
                      "a signature made by the server's reference code must verify with the Mac's layout")

        // The server derives the proof key from the verifier it stores; here the verifier is given directly.
        let verifier = try XCTUnwrap(Data(cloudHex: "b66b7ced60005079f92b6673fe86e7da1839ef9b2319e44be86c38c4db01ba9e"))
        func proof(_ challenge: String, suffix: String) -> String {
            let key = SymmetricKey(data: verifier)
            let message = Data(cloudHex: challenge)! + Data("ffeeddccbbaa99887766554433221100".utf8) + Data(suffix.utf8)
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).cloudHex
        }
        XCTAssertEqual(proof("00112233445566778899aabbccddeeff", suffix: ""), "ffdca45c36f52d9a42d923be7e6ea1ad5233bd9d84850638c36f4ab8c4e32ff0")
        XCTAssertEqual(proof(nonce, suffix: "library.recovery"), "0b4333eb5c250ddf4cd48061789f8c79da0abcd0ad895090d92cbcce4121621b")
    }

    func testKeyProofUsesTheVerifierAsTheHMACKey() throws {
        let auth = CloudCrypto.authKey(master: master)
        let viaAPI = try CloudCrypto.keyProof(authKey: auth, challengeHex: "00112233445566778899aabbccddeeff", deviceId: "ffeeddccbbaa99887766554433221100")
        let key = SymmetricKey(data: CloudCrypto.verifier(authKey: auth))
        let message = Data(cloudHex: "00112233445566778899aabbccddeeff")! + Data("ffeeddccbbaa99887766554433221100".utf8)
        XCTAssertEqual(viaAPI, Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).cloudHex)
        XCTAssertThrowsError(try CloudCrypto.keyProof(authKey: auth, challengeHex: "xyz", deviceId: "d"))
    }
}
