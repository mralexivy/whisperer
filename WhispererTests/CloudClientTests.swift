import XCTest
import CryptoKit
@testable import whisperer

final class CloudClientTests: XCTestCase {
    private let base = URL(string: "https://api.test")!
    nonisolated(unsafe) private var device: CloudDeviceKey!

    override func setUpWithError() throws {
        try super.setUpWithError()
        device = try CloudDeviceKey.loadOrCreate(keychain: InMemoryCloudKeychain(), service: "client-tests")
    }

    override func tearDown() {
        CloudStubProtocol.uninstall()
        super.tearDown()
    }

    private func client(tokens: CloudTokenProvider? = { _ in "tok" }) -> CloudClient {
        CloudClient(http: CloudHTTP(baseURL: base, session: CloudStubProtocol.session()), tokens: tokens)
    }

    private nonisolated func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    // MARK: DTOs

    func testSessionDecodesTheServerBody() throws {
        let text = CloudTestJSON.session(device: device.deviceId, epoch: 3, state: "grace", readOnly: false, libraryExists: true, keyVersion: 2, recovery: true)
        let s = try CloudJSON.decoder.decode(CloudSession.self, from: Data(text.utf8))
        XCTAssertEqual(s.accountId, CloudTestJSON.accountId)
        XCTAssertEqual(s.epoch, 3)
        XCTAssertEqual(s.state, .grace)
        XCTAssertEqual(s.library, CloudLibraryInfo(exists: true, keyVersion: 2, recoveryAvailable: true))
        XCTAssertEqual(s.plan.name, "standard")
        XCTAssertFalse(s.description.contains(s.token), "a session never prints its token")
    }

    func testUnknownServerStatesDoNotBreakDecoding() throws {
        let text = CloudTestJSON.session(device: device.deviceId, state: "something_new", libraryExists: false)
        XCTAssertEqual(try CloudJSON.decoder.decode(CloudSession.self, from: Data(text.utf8)).state, .unknown)
    }

    func testAccountDecodesGoStructFieldNamesAndDeviceList() throws {
        let text = """
        {"accountId":"\(CloudTestJSON.accountId)","epoch":2,"state":"lapsed","paidUntil":"2026-10-01T00:00:00Z","autoRenew":false,"deleteAfter":"2027-01-01T00:00:00.25Z",
         "plan":{"name":"starter","storedBytes":5,"monthlyDownloadBytes":6,"monthlyUploadGrants":7},"deviceLimit":2,
         "usage":{"StoredBytes":123,"DownloadBytes":45,"UploadGrants":6},"library":{"exists":true,"keyVersion":1,"recoveryAvailable":false},
         "devices":[{"id":"\(device.deviceId)","state":"authorized","current":true,"enrolledAt":"2026-09-01T00:00:00Z","lastSeenAt":"2026-11-01T00:00:00Z"},
                    {"id":"\(String(repeating: "9", count: 32))","state":"pending","current":false,"enrolledAt":"2026-11-10T00:00:00Z","expiresAt":"2026-11-17T00:00:00Z"}]}
        """
        let a = try CloudJSON.decoder.decode(CloudAccountInfo.self, from: Data(text.utf8))
        XCTAssertEqual(a.state, .lapsed)
        XCTAssertEqual(a.usage, CloudUsage(storedBytes: 123, downloadBytes: 45, uploadGrants: 6))
        XCTAssertNotNil(a.deleteAfter)
        XCTAssertEqual(a.devices.map(\.state), [.authorized, .pending])
        XCTAssertEqual(a.devices.first?.current, true)
        XCTAssertNotNil(a.devices.last?.expiresAt)
    }

    func testRecoveryBlobCodecCarriesTheAccountId() {
        let kdf = CloudRecoveryBlobCodec.kdf(accountId: CloudTestJSON.accountId)
        XCTAssertEqual(CloudRecoveryBlobCodec.accountId(fromKdf: kdf), CloudTestJSON.accountId)
        XCTAssertNil(CloudRecoveryBlobCodec.accountId(fromKdf: "other-scheme;acct=abc"))
        XCTAssertNil(CloudRecoveryBlobCodec.accountId(fromKdf: "whisperer-recovery-v1"))
        XCTAssertLessThanOrEqual(kdf.count, 256, "the server limits kdf to 256 bytes")
    }

    // MARK: device-signed routes

    func testEveryDeviceSignedRouteSignsItsOwnPurpose() async throws {
        let seen = CloudLocked<[String: (nonce: String, sig: String, key: String?)]>([:])
        CloudStubProtocol.install { request, body in
            let path = request.url!.path
            if path == "/v1/auth/challenge" {
                XCTAssertEqual(self.json(body)["deviceId"] as? String, self.device.deviceId)
                return .json(CloudTestJSON.challenge())
            }
            let b = self.json(body)
            seen.with { $0[path] = (b["nonce"] as? String ?? "", b["sig"] as? String ?? "", b["devicePublicKey"] as? String) }
            switch path {
            case "/v1/devices": return .json(CloudTestJSON.enrollment(device: self.device.deviceId, exists: false))
            case "/v1/library/recovery-blob": return .json(#"{"wrapped":"AAAA","kdf":"k","keyVersion":1}"#)
            case "/v1/library/reset": return .json(#"{"epoch":2,"token":"t","expiresAt":"2026-11-13T12:00:00Z","library":{"exists":false,"keyVersion":0,"recoveryAvailable":false}}"#)
            case "/v1/accounts": return .json(CloudTestJSON.session(device: self.device.deviceId, libraryExists: false), status: 201)
            default: return .json(CloudTestJSON.session(device: self.device.deviceId, libraryExists: false))
            }
        }
        let c = client()
        _ = try await c.createAccount(transactionJWS: "jws", device: device, appVersion: "1.0")
        _ = try await c.enrollDevice(transactionJWS: "jws", device: device)
        _ = try await c.confirmDevice(device: device, keyProof: "")
        _ = try await c.session(device: device, transactionJWS: nil)
        _ = try await c.recoveryBlob(device: device, transactionJWS: "jws")
        _ = try await c.resetLibrary(confirm: "RESET MY LIBRARY", device: device, transactionJWS: "jws")

        let purposes = ["/v1/accounts": "account.create", "/v1/devices": "device.enroll", "/v1/devices/confirm": "device.confirm",
                        "/v1/session": "session", "/v1/library/recovery-blob": "library.recovery-blob", "/v1/library/reset": "library.reset"]
        for (path, purpose) in purposes {
            let entry = try XCTUnwrap(seen.snapshot[path], path)
            XCTAssertTrue(CloudDeviceKey.verify(signature: entry.sig, nonceHex: CloudTestJSON.nonce, purpose: purpose, publicKeyX963: device.publicKeyX963), "\(path) must sign \(purpose)")
            for other in purposes.values where other != purpose {
                XCTAssertFalse(CloudDeviceKey.verify(signature: entry.sig, nonceHex: CloudTestJSON.nonce, purpose: other, publicKeyX963: device.publicKeyX963), "\(path) signature must not verify for \(other)")
            }
        }
        XCTAssertEqual(seen.snapshot["/v1/accounts"]?.key, device.publicKeyBase64)
        XCTAssertEqual(Data(base64Encoded: device.publicKeyBase64)?.count, 65)
    }

    func testCreateAccountBodyCarriesLabelAndAppVersionOnlyWhenGiven() async throws {
        let bodies = CloudLocked<[[String: Any]]>([])
        CloudStubProtocol.install { request, body in
            if request.url!.path == "/v1/auth/challenge" { return .json(CloudTestJSON.challenge()) }
            bodies.with { $0.append(self.json(body)) }
            return .json(CloudTestJSON.session(device: self.device.deviceId, libraryExists: false), status: 201)
        }
        _ = try await client().createAccount(transactionJWS: "j", device: device)
        _ = try await client().createAccount(transactionJWS: "j", device: device, labelEnc: "enc", appVersion: "2.0")
        XCTAssertNil(bodies.snapshot[0]["labelEnc"])
        XCTAssertEqual(bodies.snapshot[1]["labelEnc"] as? String, "enc")
        XCTAssertEqual(bodies.snapshot[1]["appVersion"] as? String, "2.0")
        XCTAssertEqual(bodies.snapshot[0]["transactionJWS"] as? String, "j")
    }

    func testConfirmSendsTheKeyProofAndDeviceId() async throws {
        let body = CloudLocked<[String: Any]>([:])
        CloudStubProtocol.install { request, data in
            if request.url!.path == "/v1/auth/challenge" { return .json(CloudTestJSON.challenge()) }
            body.with { $0 = self.json(data) }
            return .json(CloudTestJSON.session(device: self.device.deviceId, libraryExists: true))
        }
        _ = try await client().confirmDevice(device: device, keyProof: "abc123")
        XCTAssertEqual(body.snapshot["keyProof"] as? String, "abc123")
        XCTAssertEqual(body.snapshot["deviceId"] as? String, device.deviceId)
    }

    func testServerErrorsCarryTheirCode() async {
        CloudStubProtocol.install { request, _ in
            request.url!.path == "/v1/auth/challenge" ? .json(CloudTestJSON.challenge()) : .err(409, "already_bound")
        }
        do { _ = try await client().createAccount(transactionJWS: "j", device: device); XCTFail() } catch let e as CloudAPIError {
            XCTAssertEqual(e.status, 409); XCTAssertEqual(e.code, "already_bound")
        } catch { XCTFail("\(error)") }
    }

    func testOfflineSurfacesAsAnOfflineError() async {
        CloudStubProtocol.install { _, _ in .fail(.notConnectedToInternet) }
        do { _ = try await client().challenge(deviceId: device.deviceId); XCTFail() } catch let e as CloudAPIError { XCTAssertTrue(e.isOffline) } catch { XCTFail("\(error)") }
    }

    // MARK: session-token routes

    func testCreateLibraryCreatedAndLibraryExists() async throws {
        let body = CloudLocked<[String: Any]>([:])
        let exists = CloudLocked(false)
        CloudStubProtocol.install { request, data in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            body.with { $0 = self.json(data) }
            return exists.snapshot
                ? .err(409, "library_exists", #","library":{"exists":true,"keyVersion":2,"recoveryAvailable":true}"#)
                : .json(#"{"keyVersion":1}"#, status: 201)
        }
        let verifier = String(repeating: "ab", count: 32)
        let created = try await client().createLibrary(keyVerifierHex: verifier, keyVersion: 1)
        XCTAssertEqual(created, .created(keyVersion: 1))
        XCTAssertEqual(body.snapshot["keyVerifier"] as? String, verifier)
        XCTAssertEqual(body.snapshot["keyVersion"] as? Int, 1)

        exists.with { $0 = true }
        let lost = try await client().createLibrary(keyVerifierHex: verifier, keyVersion: 1)
        XCTAssertEqual(lost, .alreadyExists(CloudLibraryInfo(exists: true, keyVersion: 2, recoveryAvailable: true)))
    }

    func testPutRecoverySendsAKeyProofForTheSessionDevice() async throws {
        let master = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
        let authKey = CloudCrypto.authKey(master: master)
        let body = CloudLocked<[String: Any]>([:])
        CloudStubProtocol.install { request, data in
            if request.url!.path == "/v1/auth/challenge" { return .json(CloudTestJSON.challenge()) }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/library/recovery")
            body.with { $0 = self.json(data) }
            return CloudStubProtocol.Reply(status: 204)
        }
        try await client().putRecovery(device: device, authKey: authKey, wrapped: "d3JhcHBlZA==", kdf: "kdf")
        let expected = try CloudCrypto.keyProof(authKey: authKey, challengeHex: CloudTestJSON.nonce, deviceId: device.deviceId, suffix: "library.recovery")
        XCTAssertEqual(body.snapshot["keyProof"] as? String, expected)
        XCTAssertEqual(body.snapshot["nonce"] as? String, CloudTestJSON.nonce)
        XCTAssertEqual(body.snapshot["wrapped"] as? String, "d3JhcHBlZA==")
        XCTAssertEqual(body.snapshot["kdf"] as? String, "kdf")
    }

    func testAccountDevicesRevokeAndResetByToken() async throws {
        let seen = CloudLocked<[String]>([])
        CloudStubProtocol.install { request, data in
            seen.with { $0.append("\(request.httpMethod ?? "") \(request.url!.path)") }
            switch request.url!.path {
            case "/v1/account":
                return .json(#"{"accountId":"\#(CloudTestJSON.accountId)","epoch":1,"state":"active","paidUntil":"2026-12-01T00:00:00Z","autoRenew":true,"plan":{"name":"standard","storedBytes":1,"monthlyDownloadBytes":1,"monthlyUploadGrants":1},"deviceLimit":4,"library":{"exists":true,"keyVersion":1,"recoveryAvailable":false},"devices":[]}"#)
            case "/v1/library/reset":
                XCTAssertEqual(self.json(data)["confirm"] as? String, "RESET MY LIBRARY")
                return .json(#"{"epoch":2,"token":"t2","expiresAt":"2026-11-13T13:00:00Z","library":{"exists":false,"keyVersion":0,"recoveryAvailable":false}}"#)
            default: return CloudStubProtocol.Reply(status: 204)
            }
        }
        let c = client()
        let info = try await c.account()
        XCTAssertEqual(info.deviceLimit, 4)
        try await c.revokeDevice(id: String(repeating: "7", count: 32))
        let reset = try await c.resetLibrary(confirm: "RESET MY LIBRARY")
        XCTAssertEqual(reset.epoch, 2)
        XCTAssertEqual(seen.snapshot, ["GET /v1/account", "DELETE /v1/devices/\(String(repeating: "7", count: 32))", "POST /v1/library/reset"])
    }

    func testTokenRoutesRenewOnceOn401() async throws {
        let forced = CloudLocked<[Bool]>([])
        CloudStubProtocol.install { request, _ in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? CloudStubProtocol.Reply(status: 204) : .err(401, "unauthorized")
        }
        let c = client(tokens: { force in forced.with { $0.append(force) }; return force ? "fresh" : "old" })
        try await c.revokeDevice(id: String(repeating: "7", count: 32))
        XCTAssertEqual(forced.snapshot, [false, true])
    }

    func testTokenRoutesWithoutAProviderAre401() async {
        CloudStubProtocol.install { _, _ in XCTFail("no request should be sent"); return CloudStubProtocol.Reply() }
        do { _ = try await client(tokens: nil).account(); XCTFail() } catch let e as CloudAPIError { XCTAssertEqual(e.status, 401) } catch { XCTFail("\(error)") }
    }
}
