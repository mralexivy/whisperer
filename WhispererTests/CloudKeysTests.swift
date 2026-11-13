import XCTest
import CryptoKit
@testable import whisperer

final class CloudKeysTests: XCTestCase {
    private func store(_ kc: CloudKeychain = InMemoryCloudKeychain()) -> CloudKeyStore { CloudKeyStore(keychain: kc) }

    // MARK: state machine

    func testStateMachine() throws {
        let s = store()
        XCTAssertEqual(try s.state(libraryExists: false), .noKey)
        XCTAssertEqual(try s.state(libraryExists: true), .needsKey)
        try s.generateFirstKey(libraryExists: false)
        XCTAssertEqual(try s.state(libraryExists: true), .hasKey(version: 1))
        XCTAssertEqual(try s.state(libraryExists: true, serverKeyVersion: 1), .hasKey(version: 1))
        XCTAssertEqual(try s.state(libraryExists: true, serverKeyVersion: 2), .needsKey)
    }

    func testNeverCreatesKeyWhenLibraryExists() throws {
        let s = store()
        XCTAssertThrowsError(try s.generateFirstKey(libraryExists: true)) { XCTAssertEqual($0 as? CloudKeyError, .libraryAlreadyExists) }
        XCTAssertTrue(try s.loadRing().isEmpty)
        try s.generateFirstKey(libraryExists: false)
        XCTAssertThrowsError(try s.generateFirstKey(libraryExists: false)) { XCTAssertEqual($0 as? CloudKeyError, .keyAlreadyExists) }
    }

    func testGeneratedKeyIsStoredAndRandom() throws {
        let a = store(), b = store()
        let ka = try a.generateFirstKey(libraryExists: false), kb = try b.generateFirstKey(libraryExists: false)
        XCTAssertEqual(ka.bitCount, 256)
        XCTAssertNotEqual(ka.withUnsafeBytes { Data($0) }, kb.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try a.loadRing().keys[1], ka.withUnsafeBytes { Data($0) })
    }

    func testKeychainAttributesViaInMemory() throws {
        let kc = InMemoryCloudKeychain()
        let s = store(kc)
        try s.generateFirstKey(libraryExists: false)
        XCTAssertEqual(try kc.accounts(service: CloudKeyStore.service, synchronizable: true), ["master.v1"])
        XCTAssertEqual(try kc.accounts(service: CloudKeyStore.service, synchronizable: false), [])
        try s.deleteAll()
        XCTAssertTrue(try s.loadRing().isEmpty)
    }

    func testKeyRingMultipleVersions() throws {
        let s = store()
        var ring = CloudKeyRing()
        try ring.insert(Data(repeating: 1, count: 32), version: 1)
        try ring.insert(Data(repeating: 3, count: 32), version: 3)
        try ring.insert(Data(repeating: 2, count: 32), version: 2)
        XCTAssertEqual(ring.versions, [1, 2, 3])
        XCTAssertEqual(ring.currentVersion, 3)
        XCTAssertThrowsError(try ring.insert(Data(count: 5), version: 4))
        try s.saveRing(ring)
        XCTAssertEqual(try s.loadRing(), ring)
        XCTAssertEqual(try s.state(libraryExists: true, serverKeyVersion: 2), .hasKey(version: 3))
        let round = try CloudKeyRing(serialized: ring.serialized())
        XCTAssertEqual(round, ring)
        XCTAssertThrowsError(try CloudKeyRing(serialized: ring.serialized().dropLast()))
        XCTAssertThrowsError(try CloudKeyRing(serialized: Data("XXXX".utf8) + Data([0])))
        // Old object stays decryptable after rotation.
        let ctx = CloudObjectContext(accountId: "a", epoch: 1, objectName: "o")
        let old = try CloudCrypto.encrypt(Data("old".utf8), key: ring.symmetricKey(version: 1)!, keyVersion: 1, context: ctx)
        XCTAssertEqual(try CloudCrypto.decrypt(old, keyForVersion: { ring.symmetricKey(version: $0) }, context: ctx), Data("old".utf8))
    }

    func testInMemoryKeychainSemantics() throws {
        let kc = InMemoryCloudKeychain()
        XCTAssertNil(try kc.read(service: "s", account: "a", synchronizable: true))
        try kc.write(Data([1]), service: "s", account: "a", synchronizable: true)
        try kc.write(Data([2]), service: "s", account: "a", synchronizable: true)
        XCTAssertEqual(try kc.read(service: "s", account: "a", synchronizable: true), Data([2]))
        XCTAssertNil(try kc.read(service: "s", account: "a", synchronizable: false))
        XCTAssertNil(try kc.read(service: "t", account: "a", synchronizable: true))
        try kc.delete(service: "s", account: "a", synchronizable: true)
        XCTAssertNil(try kc.read(service: "s", account: "a", synchronizable: true))
        try kc.delete(service: "s", account: "a", synchronizable: true)   // idempotent
    }

    func testRealKeychainRoundTrip() throws {
        let service = "com.ivy.whisperer.cloud.library.test.\(UUID().uuidString)"
        let s = CloudKeyStore(keychain: SystemCloudKeychain(), service: service)
        defer { try? s.deleteAll() }
        do {
            try s.generateFirstKey(libraryExists: false)
        } catch let e as CloudKeyError where e.isKeychainUnavailable {
            throw XCTSkip("the test host has no data-protection keychain access")
        }
        XCTAssertEqual(try s.loadRing().versions, [1])
        XCTAssertEqual(try s.state(libraryExists: true), .hasKey(version: 1))
    }

    func testRealDeviceKeyStable() throws {
        let service = "com.ivy.whisperer.cloud.device-key.test.\(UUID().uuidString)"
        defer { try? CloudDeviceKey.delete(service: service) }
        let first: CloudDeviceKey
        do { first = try CloudDeviceKey.loadOrCreate(service: service) }
        catch let e as CloudKeyError where e.isKeychainUnavailable { throw XCTSkip("the test host has no data-protection keychain access") }
        XCTAssertEqual(try CloudDeviceKey.loadOrCreate(service: service).deviceId, first.deviceId)
    }

    // MARK: recovery key

    func testRecoveryKeyEncodeDecode() throws {
        for _ in 0..<20 {
            let k = try CloudRecoveryKey.generate()
            let text = try CloudRecoveryKey.encode(k)
            XCTAssertEqual(text.split(separator: "-").count, 13)
            XCTAssertTrue(text.split(separator: "-").allSatisfy { $0.count == 4 })
            XCTAssertEqual(try CloudRecoveryKey.decode(text), k)
            XCTAssertEqual(try CloudRecoveryKey.decode(text.lowercased()), k)
            XCTAssertEqual(try CloudRecoveryKey.decode(text.replacingOccurrences(of: "-", with: " \n")), k)
            XCTAssertEqual(try CloudRecoveryKey.decode("  " + text.replacingOccurrences(of: "-", with: "") + "\t"), k)
        }
    }

    func testRecoveryKeyKnownEncodings() throws {
        XCTAssertEqual(try CloudRecoveryKey.encode(Data(count: 32)), Array(repeating: "0000", count: 13).joined(separator: "-"))
        let ones = try CloudRecoveryKey.encode(Data(repeating: 0xFF, count: 32))
        XCTAssertEqual(ones, (Array(repeating: "ZZZZ", count: 12) + ["ZZZG"]).joined(separator: "-"))
        XCTAssertEqual(try CloudRecoveryKey.decode(ones), Data(repeating: 0xFF, count: 32))
        // Crockford aliases
        XCTAssertEqual(try CloudRecoveryKey.decode(Array(repeating: "OOOO", count: 13).joined()), Data(count: 32))
    }

    func testRecoveryKeyRejectsBadInput() throws {
        let text = try CloudRecoveryKey.encode(try CloudRecoveryKey.generate())
        XCTAssertThrowsError(try CloudRecoveryKey.decode(""))
        XCTAssertThrowsError(try CloudRecoveryKey.decode(String(text.dropLast())))
        XCTAssertThrowsError(try CloudRecoveryKey.decode(text + "0"))
        XCTAssertThrowsError(try CloudRecoveryKey.decode("U" + text.dropFirst()))   // U is not in the alphabet
        XCTAssertThrowsError(try CloudRecoveryKey.decode("!" + text.dropFirst()))
        // Non-zero pad bits in the last character.
        XCTAssertThrowsError(try CloudRecoveryKey.decode(Array(repeating: "0000", count: 12).joined() + "0001"))
        XCTAssertThrowsError(try CloudRecoveryKey.encode(Data(count: 31)))
    }

    func testWrapUnwrap() throws {
        var ring = CloudKeyRing()
        try ring.insert(Data((0..<32).map { UInt8($0) }), version: 1)
        try ring.insert(Data((0..<32).map { UInt8(255 - $0) }), version: 2)
        let rk = try CloudRecoveryKey.generate()
        let wrapped = try CloudRecoveryKey.wrap(ring: ring, recoveryKey: rk, accountId: "acct", keyVersion: 2)
        XCTAssertEqual(wrapped.count, 12 + (5 + 66) + 16)
        XCTAssertEqual(try CloudRecoveryKey.unwrap(wrapped, recoveryKey: rk, accountId: "acct", keyVersion: 2), ring)
        XCTAssertThrowsError(try CloudRecoveryKey.unwrap(wrapped, recoveryKey: rk, accountId: "other", keyVersion: 2))
        XCTAssertThrowsError(try CloudRecoveryKey.unwrap(wrapped, recoveryKey: rk, accountId: "acct", keyVersion: 1))
        XCTAssertThrowsError(try CloudRecoveryKey.unwrap(wrapped, recoveryKey: try CloudRecoveryKey.generate(), accountId: "acct", keyVersion: 2)) {
            XCTAssertEqual($0 as? CloudKeyError, .unwrapFailed)
        }
        var t = wrapped; t[t.count - 1] ^= 1
        XCTAssertThrowsError(try CloudRecoveryKey.unwrap(t, recoveryKey: rk, accountId: "acct", keyVersion: 2))
        XCTAssertThrowsError(try CloudRecoveryKey.unwrap(Data(count: 5), recoveryKey: rk, accountId: "acct", keyVersion: 2))
    }

    func testRecoveryRestoresAccessEndToEnd() throws {
        let mac1 = store()
        let key = try mac1.generateFirstKey(libraryExists: false)
        let rk = try CloudRecoveryKey.generate()
        let wrapped = try CloudRecoveryKey.wrap(ring: try mac1.loadRing(), recoveryKey: rk, accountId: "acct", keyVersion: 1)
        let ctx = CloudObjectContext(accountId: "acct", epoch: 1, objectName: "n")
        let blob = try CloudCrypto.encrypt(Data("data".utf8), key: key, keyVersion: 1, context: ctx)

        let mac2 = store()
        XCTAssertEqual(try mac2.state(libraryExists: true), .needsKey)
        let typed = try CloudRecoveryKey.encode(rk).lowercased()
        let ring = try CloudRecoveryKey.unwrap(wrapped, recoveryKey: try CloudRecoveryKey.decode(typed), accountId: "acct", keyVersion: 1)
        try mac2.saveRing(ring)
        XCTAssertEqual(try mac2.state(libraryExists: true), .hasKey(version: 1))
        XCTAssertEqual(try CloudCrypto.decrypt(blob, keyForVersion: { ring.symmetricKey(version: $0) }, context: ctx), Data("data".utf8))
        // Both Macs derive the same verifier.
        XCTAssertEqual(CloudCrypto.verifier(authKey: CloudCrypto.authKey(master: key)),
                       CloudCrypto.verifier(authKey: CloudCrypto.authKey(master: ring.symmetricKey(version: 1)!)))
    }
}
