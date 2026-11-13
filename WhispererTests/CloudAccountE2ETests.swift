import XCTest
import CryptoKit
@testable import whisperer

/// End-to-end tests against the REAL Go server (server/cmd/devserver: real handlers, in-memory stores, a fake
/// Cloud Storage that speaks the signed-URL / resumable protocol, and a test Apple root that signs minted
/// transactions). Opt in with TEST_RUNNER_CLOUD_DEVSERVER=http://127.0.0.1:8787 while `go run ./cmd/devserver` is
/// running (xcodebuild passes TEST_RUNNER_* variables to the test process with the prefix removed).
final class CloudAccountE2ETests: XCTestCase {
    // MARK: Dev server client

    nonisolated struct DevServer: Sendable {
        let base: URL

        func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, "\(path): \(String(data: data, encoding: .utf8) ?? "")")
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        func stats() async throws -> [String: Int] {
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("dev/stats"))
            return (try JSONSerialization.jsonObject(with: data) as? [String: Int]) ?? [:]
        }

        func advanceClock(seconds: Int) async throws { _ = try await post("dev/advance-clock", ["seconds": seconds]) }
        func fault(_ body: [String: Any]) async throws { _ = try await post("dev/fault", body) }
    }

    /// One Apple Account's subscription: every Mac signed into it receives transactions with these ids.
    struct Subscription {
        let originalTransactionId = "e2e-\(UUID().uuidString)"
        let appAccountToken = UUID().uuidString.lowercased()
        var expiresInSeconds = 30 * 24 * 3600
        var product = CloudProduct(tier: .standard, period: .monthly)

        func mint(_ server: DevServer, revoked: Bool = false) async throws -> String {
            let out = try await server.post("dev/mint-transaction", [
                "productId": product.id, "originalTransactionId": originalTransactionId, "appAccountToken": appAccountToken,
                "expiresInSeconds": expiresInSeconds, "environment": "Sandbox", "revoked": revoked,
            ])
            return try XCTUnwrap(out["jws"] as? String)
        }
    }

    /// A simulated Mac: its own device key, its own key store (iCloud Keychain is simulated by copying keys
    /// between Macs), the real HTTP stack, the real controller.
    @MainActor
    final class SimMac {
        let deviceKeychain = InMemoryCloudKeychain()
        let libraryKeychain = InMemoryCloudKeychain()
        let purchasing = FakePurchasing()
        let controller: CloudAccountController
        var keys: CloudKeyStore { CloudKeyStore(keychain: libraryKeychain) }

        init(server: DevServer) {
            controller = CloudAccountController(http: CloudHTTP(baseURL: server.base), purchasing: purchasing, keyStore: CloudKeyStore(keychain: libraryKeychain),
                                                deviceKeychain: deviceKeychain, deviceKeyService: "e2e-device",
                                                keyEpochDefaults: UserDefaults(suiteName: "e2e-epoch-\(UUID().uuidString)")!)
        }

        var deviceId: String { (try? CloudDeviceKey.loadOrCreate(keychain: deviceKeychain, service: "e2e-device").deviceId) ?? "" }

        /// iCloud Keychain delivering this Mac's library key to `other`.
        func shareKeys(with other: SimMac) throws { try other.keys.saveRing(try keys.loadRing()) }

        func transport(download: Int = 8 << 20) -> CloudHTTPTransport {
            var c = CloudHTTPTransport.Configuration()
            c.downloadChunkSize = download
            c.sleep = { _ in }
            c.partialDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-partials-\(UUID().uuidString)")
            return controller.makeTransport(configuration: c)
        }
    }

    private var server: DevServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let raw = ProcessInfo.processInfo.environment["CLOUD_DEVSERVER"] ?? ProcessInfo.processInfo.environment["TEST_RUNNER_CLOUD_DEVSERVER"]
        guard let raw, let url = URL(string: raw) else { throw XCTSkip("Set TEST_RUNNER_CLOUD_DEVSERVER=http://127.0.0.1:PORT with `go run ./cmd/devserver` running") }
        server = DevServer(base: url)
        // Each test starts with no fault armed.
    }

    override func tearDown() async throws {
        if server != nil { try? await server.fault(["dropChunks": [:], "dropGets": [:], "errorNext": [:]]) }
        try await super.tearDown()
    }

    // MARK: Helpers

    private func random(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    /// Mac A buys, creates the account and library, and finishes the recovery step.
    private func firstMac(_ sub: Subscription, recoveryKey: Bool = true) async throws -> (mac: SimMac, recoveryKey: String?) {
        let a = await SimMac(server: server)
        await MainActor.run { a.purchasing.onPurchase = { [server] _ in try? await sub.mint(server!) } }
        await a.controller.purchase(sub.product)
        let state = await a.controller.state
        XCTAssertEqual(state, .offerRecoveryKey)
        var text: String?
        if recoveryKey {
            await a.controller.createRecoveryKey()
            guard case .showRecoveryKey(let shown) = await a.controller.state else { XCTFail("no recovery key shown"); return (a, nil) }
            text = shown
        }
        await a.controller.finishRecoveryKey()
        let ready = await a.controller.state
        XCTAssertEqual(ready, .ready)
        return (a, text)
    }

    /// A second Mac on the same Apple Account: same subscription, its own device, no key yet.
    private func secondMac(_ sub: Subscription) async throws -> SimMac {
        let b = await SimMac(server: server)
        let jws = try await sub.mint(server)
        await MainActor.run { b.purchasing.jws = jws }
        return b
    }

    private func context(_ identity: CloudAccountIdentity, _ name: String) -> CloudObjectContext {
        CloudObjectContext(accountId: identity.accountId, epoch: identity.epoch, objectName: name)
    }

    // MARK: The big one

    func testPurchaseAccountLibraryUploadWithInterruptedResumableThenSecondMacDownloads() async throws {
        let sub = Subscription()
        let (a, recoveryKey) = try await firstMac(sub)
        XCTAssertNotNil(recoveryKey)
        let identityA = try await XCTUnwrap(a.controller.identity)
        let keyA = try await XCTUnwrap(a.keys.loadRing().symmetricKey(version: 1))

        // A change batch (small, simple PUT) and a 20 MB audio object (resumable, with a cut connection).
        let change = Data(#"{"ops":[{"kind":"dictation","text":"hello from mac A"}]}"#.utf8)
        let audio = random(20 << 20)
        let audioId = random(16).cloudHex
        let changeName = "changes/\(identityA.deviceId)/000000000001", audioName = "audio/\(audioId)"
        let changeBlob = try CloudCrypto.encrypt(change, key: keyA, keyVersion: 1, context: context(identityA, changeName))
        let audioBlob = try CloudCrypto.encrypt(audio, key: keyA, keyVersion: 1, context: context(identityA, audioName))

        let transportA = await a.transport()
        let grants = try await transportA.requestUploads([
            CloudUploadRequest(ref: .change(device: identityA.deviceId, seq: 1), size: Int64(changeBlob.count)),
            CloudUploadRequest(ref: .audio(id: audioId), size: Int64(audioBlob.count)),
        ])
        XCTAssertEqual(grants.count, 2)
        XCTAssertNotEqual(grants[0].resumable, true)
        XCTAssertEqual(grants[1].resumable, true, "a 20 MB object gets a resumable session")
        XCTAssertEqual(grants[1].headers?["x-goog-resumable"], "start")

        let before = try await server.stats()
        try await server.fault(["dropChunks": ["after": 1, "count": 1, "persist": false]]) // the second 8 MiB chunk dies on the wire
        try await transportA.upload(changeBlob, with: grants[0])
        try await transportA.upload(audioBlob, with: grants[1])
        let after = try await server.stats()
        XCTAssertEqual((after["dropped"] ?? 0) - (before["dropped"] ?? 0), 1)
        XCTAssertEqual((after["sessionStarts"] ?? 0) - (before["sessionStarts"] ?? 0), 1, "one session: the interruption resumed it")
        XCTAssertGreaterThanOrEqual((after["statusQueries"] ?? 0) - (before["statusQueries"] ?? 0), 1, "the resume asked 'bytes */total'")
        XCTAssertEqual((after["chunkPuts"] ?? 0) - (before["chunkPuts"] ?? 0), 4, "3 chunks of the object + the one that was cut")

        // Uploading again is harmless: 412 (object exists) counts as success.
        let regrant = try await transportA.requestUploads([CloudUploadRequest(ref: .change(device: identityA.deviceId, seq: 1), size: Int64(changeBlob.count))])
        try await transportA.upload(changeBlob, with: regrant[0])

        let committed = try await transportA.commit(device: identityA.deviceId, seq: 1, crc: CloudCRC32C.checksum(changeBlob), extra: [.audio(id: audioId)], snapshot: nil)
        XCTAssertEqual(committed.head, CloudHead(seq: 1, crc: CloudCRC32C.checksum(changeBlob)))

        // Mac B: same Apple Account, no key yet -> waits (never invents one) -> iCloud delivers -> enrolled.
        let b = try await secondMac(sub)
        await b.controller.refresh()
        var stateB = await b.controller.state
        XCTAssertEqual(stateB, .needsKey(CloudNeedsKey(recoveryAvailable: true)))
        let emptyRing = try b.keys.loadRing()
        XCTAssertTrue(emptyRing.isEmpty)
        let identityBeforeKey = await b.controller.identity
        XCTAssertNil(identityBeforeKey)

        try a.shareKeys(with: b)
        await b.controller.recheckKey()
        stateB = await b.controller.state
        XCTAssertEqual(stateB, .ready)
        let identityB = try await XCTUnwrap(b.controller.identity)
        XCTAssertEqual(identityB.accountId, identityA.accountId)
        XCTAssertEqual(identityB.epoch, identityA.epoch)
        XCTAssertNotEqual(identityB.deviceId, identityA.deviceId)

        // B downloads and decrypts both objects (the audio through ranged GETs, with one cut connection).
        let transportB = await b.transport()
        let heads = try await transportB.heads(since: nil)
        XCTAssertEqual(heads.heads?[identityA.deviceId]?.seq, 1)
        let downloads = try await transportB.requestDownloads([.change(device: identityA.deviceId, seq: 1), .audio(id: audioId)])
        let keyB = try await XCTUnwrap(b.keys.loadRing().symmetricKey(version: 1))
        let changeGot = try await transportB.download(with: downloads[0])
        XCTAssertEqual(changeGot, changeBlob)
        XCTAssertEqual(try CloudCrypto.decrypt(changeGot, key: keyB, keyVersion: 1, context: context(identityB, changeName)), change)

        let getsBefore = try await server.stats()
        try await server.fault(["dropGets": ["after": 1, "count": 1]])
        let audioGot = try await transportB.download(with: downloads[1])
        let getsAfter = try await server.stats()
        XCTAssertEqual(audioGot.count, audioBlob.count)
        XCTAssertEqual(CloudCRC32C.checksum(audioGot), CloudCRC32C.checksum(audioBlob))
        XCTAssertGreaterThanOrEqual((getsAfter["rangedGets"] ?? 0) - (getsBefore["rangedGets"] ?? 0), 4, "20 MB in 8 MiB ranges, plus the retried one")
        XCTAssertEqual(try CloudCrypto.decrypt(audioGot, key: keyB, keyVersion: 1, context: context(identityB, audioName)), audio)

        // The same bytes under the wrong object name do not decrypt: the AAD binds the object to its place.
        XCTAssertThrowsError(try CloudCrypto.decrypt(changeGot, key: keyB, keyVersion: 1, context: context(identityB, "changes/other/000000000001")))

        // Both Macs appear in the account, B is marked current for itself.
        await b.controller.refreshAccount()
        let info = await b.controller.accountInfo
        XCTAssertEqual(info?.devices.count, 2)
        XCTAssertEqual(info?.devices.first(where: { $0.current })?.id, identityB.deviceId)
        XCTAssertEqual(info?.usage?.storedBytes ?? 0, Int64(changeBlob.count + audioBlob.count))
    }

    // MARK: Keys

    func testMacWithTheWrongKeyStaysNeedsKeyAndNeverGetsASession() async throws {
        let sub = Subscription()
        _ = try await firstMac(sub)
        let c = try await secondMac(sub)
        try c.keys.save(random(32), version: 1) // a stale/foreign key
        await c.controller.refresh()
        let state = await c.controller.state
        XCTAssertEqual(state, .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongKey: true)))
        let identity = await c.controller.identity
        XCTAssertNil(identity)
        let transport = await c.transport()
        do { _ = try await transport.requestUploads([CloudUploadRequest(ref: .audio(id: random(16).cloudHex), size: 10)]); XCTFail("no session, no access") } catch {
            XCTAssertEqual(error as? CloudTransportError, .unauthorized)
        }
    }

    func testRecoveryKeyUnlocksANewMacThatHasNoKeychainKey() async throws {
        let sub = Subscription()
        let (a, recoveryKey) = try await firstMac(sub)
        let b = try await secondMac(sub)
        await b.controller.refresh()
        let waiting = await b.controller.state
        XCTAssertEqual(waiting, .needsKey(CloudNeedsKey(recoveryAvailable: true)))

        await b.controller.submitRecoveryKey(try CloudRecoveryKey.encode(try CloudRecoveryKey.generate()))
        let stillWaiting = await b.controller.state
        XCTAssertEqual(stillWaiting, .needsKey(CloudNeedsKey(recoveryAvailable: true, wrongRecoveryKey: true)))

        await b.controller.submitRecoveryKey(try XCTUnwrap(recoveryKey))
        let ready = await b.controller.state
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(try b.keys.loadRing().keys, try a.keys.loadRing().keys, "the unwrapped ring equals the original")
    }

    func testTwoMacsStartingTogetherCreateExactlyOneLibrary() async throws {
        // Both Macs of one Apple Account refresh at the same moment: whoever gets the library first wins, the other
        // never keeps a key of its own (it adopts through Keychain or the recovery key).
        let sub = Subscription()
        let a = await SimMac(server: server), b = await SimMac(server: server)
        let jws = try await sub.mint(server)
        await MainActor.run { a.purchasing.jws = jws; b.purchasing.jws = jws }
        async let ra: Void = a.controller.refresh()
        async let rb: Void = b.controller.refresh()
        _ = await (ra, rb)
        let states = [await a.controller.state, await b.controller.state]
        XCTAssertEqual(states.filter { $0 == .offerRecoveryKey }.count, 1, "exactly one Mac created the library: \(states)")
        let loser = states[0] == .offerRecoveryKey ? b : a
        let loserState = await loser.controller.state
        XCTAssertEqual(loserState, .needsKey(CloudNeedsKey(recoveryAvailable: false)))
        XCTAssertTrue(try loser.keys.loadRing().isEmpty, "the loser holds no key of its own")
    }

    // MARK: Devices

    func testRevokedDeviceIsRefusedEverywhere() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub)
        let b = try await secondMac(sub)
        try a.shareKeys(with: b)
        await b.controller.refresh()
        let ready = await b.controller.state
        XCTAssertEqual(ready, .ready)
        let identityB = try await XCTUnwrap(b.controller.identity)
        let transportB = await b.transport()
        _ = try await transportB.requestUploads([CloudUploadRequest(ref: .audio(id: random(16).cloudHex), size: 10)]) // works

        await a.controller.refreshAccount()
        await a.controller.revokeDevice(id: identityB.deviceId)
        let stateA = await a.controller.state
        XCTAssertEqual(stateA, .ready)
        await a.controller.refreshAccount()
        let listed = await a.controller.accountInfo
        let identityA = try await XCTUnwrap(a.controller.identity)
        XCTAssertEqual(listed?.devices.map(\.id), [identityA.deviceId], "a revoked device disappears from the list")

        // B still holds a valid token for up to an hour, but every state-changing route refuses it at once.
        do { _ = try await transportB.requestUploads([CloudUploadRequest(ref: .audio(id: random(16).cloudHex), size: 10)]); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .deviceRevoked)
        }
        do { _ = try await transportB.requestDownloads([.audio(id: random(16).cloudHex)]); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .deviceRevoked)
        }
        // And it cannot get a new session: it is signed out.
        do { _ = try await b.controller.sessionToken(forceRefresh: true); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .deviceRevoked)
        }
        let stateB = await b.controller.state
        XCTAssertEqual(stateB, .deviceRevoked)

        // A fresh start makes a new device key; the library key is still in the Keychain, so it re-enrols by itself.
        await b.controller.startOver()
        let again = await b.controller.state
        XCTAssertEqual(again, .ready)
        let newIdentity = await b.controller.identity
        XCTAssertNotEqual(newIdentity?.deviceId, identityB.deviceId)
    }

    // MARK: Reset

    func testResetStartsANewEpochWithANewKeyAndEmptyHeads() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub)
        let identity1 = try await XCTUnwrap(a.controller.identity)
        let oldKey = try a.keys.loadRing().keys[1]

        // Some data under epoch 1.
        let keyA = try await XCTUnwrap(a.keys.loadRing().symmetricKey(version: 1))
        let blob = try CloudCrypto.encrypt(Data("old".utf8), key: keyA, keyVersion: 1, context: context(identity1, "changes/x"))
        let transport = await a.transport()
        let grant = try await transport.requestUploads([CloudUploadRequest(ref: .change(device: identity1.deviceId, seq: 1), size: Int64(blob.count))])
        try await transport.upload(blob, with: grant[0])
        _ = try await transport.commit(device: identity1.deviceId, seq: 1, crc: CloudCRC32C.checksum(blob), extra: [], snapshot: nil)

        await a.controller.resetLibrary(confirmation: "reset my library")
        let rejected = await a.controller.state
        XCTAssertEqual(rejected, .ready, "a wrong phrase changes nothing")

        await a.controller.resetLibrary(confirmation: CloudResetPhrase.phrase)
        let state = await a.controller.state
        XCTAssertEqual(state, .offerRecoveryKey)
        let identity2 = try await XCTUnwrap(a.controller.identity)
        XCTAssertEqual(identity2.epoch, identity1.epoch + 1)
        XCTAssertNotEqual(try a.keys.loadRing().keys[1], oldKey)

        let heads = try await a.transport().heads(since: nil)
        XCTAssertEqual(heads.epoch, 2)
        XCTAssertTrue(heads.heads?.isEmpty ?? true, "the new epoch starts empty; this Mac re-uploads its local history")
        // The commit counter starts over too.
        let g2 = try await a.transport().requestUploads([CloudUploadRequest(ref: .change(device: identity2.deviceId, seq: 1), size: 10)])
        XCTAssertEqual(g2.count, 1)
    }

    func testResetFromAMacThatLostTheKey() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub)
        let c = try await secondMac(sub)
        await c.controller.refresh()
        let waiting = await c.controller.state
        XCTAssertEqual(waiting, .needsKey(CloudNeedsKey(recoveryAvailable: true)))

        await c.controller.resetLibrary(confirmation: CloudResetPhrase.phrase) // lost-key path: device signature + transaction
        let state = await c.controller.state
        XCTAssertEqual(state, .offerRecoveryKey)
        let identity = try await XCTUnwrap(c.controller.identity)
        XCTAssertEqual(identity.epoch, 2)
        // The first Mac's key is now for a dead library; the second Mac owns the new one.
        XCTAssertNotEqual(try a.keys.loadRing().keys[1], try c.keys.loadRing().keys[1])
        await a.controller.refresh()
        let stateA = await a.controller.state
        XCTAssertEqual(stateA, .needsKey(CloudNeedsKey(recoveryAvailable: false, wrongKey: true)), "A still holds the dead key of the old epoch: it waits for the new one instead of writing under it")
    }

    // MARK: Subscription lifecycle

    func testReadOnlyAfterExpiryReadsStillWorkAndWritesAreRefused() async throws {
        var sub = Subscription()
        sub.expiresInSeconds = 600
        let (a, _) = try await firstMac(sub, recoveryKey: false)
        let identity = try await XCTUnwrap(a.controller.identity)
        let key = try await XCTUnwrap(a.keys.loadRing().symmetricKey(version: 1))
        let blob = try CloudCrypto.encrypt(Data("before expiry".utf8), key: key, keyVersion: 1, context: context(identity, "changes/1"))
        let transport = await a.transport()
        let grant = try await transport.requestUploads([CloudUploadRequest(ref: .change(device: identity.deviceId, seq: 1), size: Int64(blob.count))])
        try await transport.upload(blob, with: grant[0])
        _ = try await transport.commit(device: identity.deviceId, seq: 1, crc: CloudCRC32C.checksum(blob), extra: [], snapshot: nil)

        try await server.advanceClock(seconds: 7200) // past the expiry AND the old token's life
        // The old token is dead: the first call renews it by itself (401 -> new session) and finds the library read-only.
        let heads = try await transport.heads(since: nil)
        XCTAssertEqual(heads.heads?[identity.deviceId]?.seq, 1, "reads keep working")
        XCTAssertEqual(heads.readOnly, true)
        let state = await a.controller.state
        XCTAssertEqual(state, .readOnly(.expired))

        do { _ = try await transport.requestUploads([CloudUploadRequest(ref: .audio(id: random(16).cloudHex), size: 10)]); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .readOnly)
        }
        do { _ = try await transport.commit(device: identity.deviceId, seq: 2, crc: 1, extra: [], snapshot: nil); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .readOnly)
        }
        let downloads = try await transport.requestDownloads([.change(device: identity.deviceId, seq: 1)])
        let got = try await transport.download(with: downloads[0])
        XCTAssertEqual(try CloudCrypto.decrypt(got, key: key, keyVersion: 1, context: context(identity, "changes/1")), Data("before expiry".utf8))
        // Deleting stays allowed so an over-quota user can free space.
        let deleted = try await transport.delete([.change(device: identity.deviceId, seq: 1)])
        XCTAssertEqual(deleted, 1)

        // Resubscribing (a newer transaction on the same chain) brings write access back.
        var renewed = sub; renewed.expiresInSeconds = 30 * 24 * 3600
        let jws = try await renewed.mint(server)
        await MainActor.run { a.purchasing.jws = jws }
        _ = try await a.controller.sessionToken(forceRefresh: true)
        let back = await a.controller.state
        XCTAssertEqual(back, .ready)
    }

    func testRefundedSubscriptionIsReadOnlyImmediately() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub, recoveryKey: false)
        let refund = try await sub.mint(server, revoked: true)
        await MainActor.run { a.purchasing.jws = refund; a.purchasing.access = .revoked }
        _ = try await a.controller.sessionToken(forceRefresh: true)
        let state = await a.controller.state
        XCTAssertEqual(state, .readOnly(.refunded))
    }

    func testAnExpiredTokenIsRenewedTransparentlyOn401() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub, recoveryKey: false)
        let transport = await a.transport()
        _ = try await transport.heads(since: nil)
        try await server.advanceClock(seconds: 2 * 3600) // the one-hour token is now invalid on the server
        let heads = try await transport.heads(since: nil)
        XCTAssertNotNil(heads.serverTime)
        let state = await a.controller.state
        XCTAssertEqual(state, .ready)
    }

    // MARK: Failure injection on the data plane

    func testStorageOutageSurfacesAsTransientErrorsAndRecovers() async throws {
        let sub = Subscription()
        let (a, _) = try await firstMac(sub, recoveryKey: false)
        let identity = try await XCTUnwrap(a.controller.identity)
        let transport = await a.transport()
        let blob = random(1000)
        let grant = try await transport.requestUploads([CloudUploadRequest(ref: .change(device: identity.deviceId, seq: 1), size: 1000)])
        try await server.fault(["errorNext": ["code": 503, "count": 1]])
        do { try await transport.upload(blob, with: grant[0]); XCTFail() } catch { XCTAssertEqual(error as? CloudTransportError, .server(status: 503)) }
        try await transport.upload(blob, with: grant[0]) // the engine retries; the quota reservation is reused
        _ = try await transport.commit(device: identity.deviceId, seq: 1, crc: CloudCRC32C.checksum(blob), extra: [], snapshot: nil)
    }
}
