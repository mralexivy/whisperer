//
//  CloudAccountController.swift
//  Whisperer
//
//  The state machine the Cloud UI binds to (docs/exec-plans/cloud-sync-implementation.md sections 2, 6, 10):
//
//    first Mac:  notSubscribed -> purchasing -> creatingAccount -> creatingLibrary -> offerRecoveryKey
//                -> showRecoveryKey (or skip) -> ready
//    new Mac:    enrolPending -> needsKey (iCloud Keychain not here yet / recovery key) -> confirming -> ready
//    otherwise:  readOnly(reason), deviceRevoked, resetting, unavailable(problem)
//
//  Rules this file enforces:
//   - a library key is generated ONLY after the server said no library exists, and a 409 `library_exists`
//     discards it again (the winner's key is adopted through Keychain or the recovery key);
//   - a Mac that finds a library but no key waits in `needsKey`; it never invents one;
//   - tokens, JWS values, keys and the recovery key are never logged (`CloudAccountState` prints without payload).
//
//  The decisions are pure (`CloudKeyDecision`, `CloudReadOnlyReason`, `CloudAccountProblem`, `CloudResetPhrase`)
//  and tested without a network; the controller only sequences them.
//

import Foundation
import Combine
import CryptoKit
import StoreKit

// MARK: - Pure pieces

nonisolated enum CloudResetPhrase {
    static let phrase = "RESET MY LIBRARY"
    /// Exact match, case-sensitive; only surrounding whitespace is forgiven.
    static func matches(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines) == phrase }
}

nonisolated enum CloudReadOnlyReason: Equatable, Sendable {
    case paymentRetry   // Apple is retrying the charge
    case expired        // the subscription ended: read and export until the deletion date
    case refunded       // refunded or revoked
    case sealed         // later in the lapse: text can be exported, audio is no longer served
    case removed        // soft-deleted or deleted on the server

    /// The server's state decides; StoreKit's view only refines the wording of a plain `lapsed`.
    static func from(server: CloudServerState, local: CloudAccess) -> CloudReadOnlyReason {
        switch server {
        case .sealed: return .sealed
        case .softDeleted, .deleted: return .removed
        default:
            switch local {
            case .retry: return .paymentRetry
            case .revoked: return .refunded
            default: return .expired
            }
        }
    }
}

/// A problem the user can read about and retry; never a state of the library itself.
nonisolated enum CloudAccountProblem: Equatable, Sendable {
    case offline
    case deviceLimit
    case tooManyPending
    case rateLimited(retryAfter: TimeInterval?)
    case wrongProduct
    case keychain
    case server(code: String)

    init(_ error: CloudAPIError) {
        if error.isOffline { self = .offline; return }
        switch error.code {
        case "device_limit": self = .deviceLimit
        case "too_many_pending": self = .tooManyPending
        case "rate_limited": self = .rateLimited(retryAfter: error.retryAfter)
        case "wrong_product", "wrong_app", "wrong_environment", "invalid_transaction": self = .wrongProduct
        default: self = .server(code: error.code)
        }
    }
}

nonisolated struct CloudNeedsKey: Equatable, Sendable {
    /// The library has a recovery blob: the recovery key can unlock it.
    var recoveryAvailable: Bool
    /// A key was found but the server rejected its proof (a stale or foreign key).
    var wrongKey = false
    /// The recovery key the user typed did not unlock the library.
    var wrongRecoveryKey = false
}

nonisolated enum CloudKeyDecision: Equatable, Sendable {
    case noLibrary                 // the server has none: this Mac may create the first key
    case prove(version: UInt8)     // the ring holds the key of the library's version
    case needsKey                  // the library exists and this Mac has no key for it

    static func decide(library: CloudLibraryInfo, ring: CloudKeyRing) -> CloudKeyDecision {
        guard library.exists else { return .noLibrary }
        if let version = UInt8(exactly: library.keyVersion), ring.symmetricKey(version: version) != nil { return .prove(version: version) }
        return .needsKey
    }
}

/// What the sync engine needs to build its `CloudObjectContext`s (account id and epoch are bound into every chunk).
nonisolated struct CloudAccountIdentity: Equatable, Sendable {
    var accountId: String
    var deviceId: String
    var epoch: UInt64
    var keyVersion: UInt8
    var readOnly: Bool
}

nonisolated enum CloudAccountState: Equatable, Sendable, CustomStringConvertible {
    case notSubscribed
    case purchasing
    case creatingAccount
    case creatingLibrary
    /// The library exists; the Mac may now create a recovery key (or skip).
    case offerRecoveryKey
    /// The recovery key, shown once. Never persisted by the app.
    case showRecoveryKey(String)
    case ready
    case readOnly(CloudReadOnlyReason)
    case enrolPending
    case needsKey(CloudNeedsKey)
    case confirming
    case resetting
    case deviceRevoked
    case unavailable(CloudAccountProblem)

    /// A name with no payload: safe for the log (the recovery key is a payload of `showRecoveryKey`).
    var description: String {
        switch self {
        case .notSubscribed: return "notSubscribed"
        case .purchasing: return "purchasing"
        case .creatingAccount: return "creatingAccount"
        case .creatingLibrary: return "creatingLibrary"
        case .offerRecoveryKey: return "offerRecoveryKey"
        case .showRecoveryKey: return "showRecoveryKey"
        case .ready: return "ready"
        case .readOnly(let reason): return "readOnly(\(reason))"
        case .enrolPending: return "enrolPending"
        case .needsKey: return "needsKey"
        case .confirming: return "confirming"
        case .resetting: return "resetting"
        case .deviceRevoked: return "deviceRevoked"
        case .unavailable(let problem): return "unavailable(\(problem))"
        }
    }
}

// MARK: - Purchases

/// Where the subscription comes from. The app uses StoreKit; tests substitute a source that mints transactions.
@MainActor
protocol CloudPurchasing: AnyObject {
    var access: CloudAccess { get }
    func purchase(_ product: CloudProduct) async -> CloudPurchaseOutcome?
    /// The signed transaction the server verifies against Apple's root; nil when there is none.
    func currentTransactionJWS() async -> String?
    /// Re-reads the subscription state (Restore Purchases / launch).
    func refresh() async
}

@MainActor
final class CloudStoreKitPurchasing: CloudPurchasing {
    private let store: CloudSubscriptionStore
    init(store: CloudSubscriptionStore) { self.store = store }

    var access: CloudAccess { store.access }

    func purchase(_ product: CloudProduct) async -> CloudPurchaseOutcome? {
        if store.products.isEmpty { await store.loadProducts() }
        guard let match = store.products.first(where: { $0.id == product.id }) else { return nil }
        return await store.purchase(match)
    }

    func currentTransactionJWS() async -> String? { await store.currentTransactionJWS() }
    func refresh() async { await store.restore() }
}

// MARK: - Controller

@MainActor
final class CloudAccountController: ObservableObject {
    @Published private(set) var state: CloudAccountState = .notSubscribed
    /// Who this Mac is signed in as, once it holds a session.
    @Published private(set) var identity: CloudAccountIdentity?
    @Published private(set) var accountInfo: CloudAccountInfo?
    /// A short, user-presentable message about the last failed action; never contains a secret.
    @Published private(set) var lastError: String?
    /// Ask to Buy / SCA: the purchase completes later.
    @Published private(set) var isPurchasePending = false

    private let http: CloudHTTP
    private let purchasing: CloudPurchasing
    private let keyStore: CloudKeyStore
    private let deviceKeychain: CloudKeychain
    private let deviceKeyService: String
    private let appVersion: String?
    private let now: () -> Date
    private let epochDefaults: UserDefaults

    private var deviceKey: CloudDeviceKey?
    private var session: CloudSession?
    private var pendingEnrollment: CloudEnrollment?
    private var renewal: Task<CloudSession, Error>?
    private var reconcileTask: Task<Void, Never>?

    init(http: CloudHTTP, purchasing: CloudPurchasing, keyStore: CloudKeyStore = CloudKeyStore(),
         deviceKeychain: CloudKeychain = SystemCloudKeychain(), deviceKeyService: String = CloudDeviceKey.service,
         appVersion: String? = nil, keyEpochDefaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.http = http
        self.purchasing = purchasing
        self.keyStore = keyStore
        self.deviceKeychain = deviceKeychain
        self.deviceKeyService = deviceKeyService
        self.appVersion = appVersion
        self.now = now
        self.epochDefaults = keyEpochDefaults
    }

    // MARK: For the sync engine

    /// The provider every authenticated call uses: returns the cached token while it has time left, renews it
    /// (one in flight at a time) when it does not or after a 401.
    nonisolated var tokenProvider: CloudTokenProvider {
        { [weak self] forceRefresh in
            guard let self else { throw CloudTransportError.unauthorized }
            return try await self.sessionToken(forceRefresh: forceRefresh)
        }
    }

    /// A transport that speaks to the server as this Mac (shares the token provider).
    func makeTransport(configuration: CloudHTTPTransport.Configuration = .init(), blobSession: URLSession? = nil) -> CloudHTTPTransport {
        var configuration = configuration
        if configuration.onDeviceRevoked == nil {
            configuration.onDeviceRevoked = { [weak self] in Task { @MainActor [weak self] in self?.serverRemovedThisDevice() } }
        }
        return CloudHTTPTransport(api: http, tokens: tokenProvider, blobSession: blobSession, configuration: configuration)
    }

    /// A sync route answered device_revoked: the session is useless from now on, so sign out immediately (the engine stops
    /// with the account state; a fresh start creates a new device identity).
    func serverRemovedThisDevice() {
        guard state != .deviceRevoked else { return }
        session = nil; identity = nil; accountInfo = nil
        setState(.deviceRevoked)
    }

    var keys: CloudKeyStore { keyStore }

    private var client: CloudClient { CloudClient(http: http, tokens: tokenProvider) }

    func sessionToken(forceRefresh: Bool) async throws -> String {
        if !forceRefresh, let s = session, s.expiresAt.timeIntervalSince(now()) > 60 { return s.token }
        return try await renewSession().token
    }

    private func renewSession() async throws -> CloudSession {
        if let renewal { return try await renewal.value }
        let task = Task { try await self.performRenewal() }
        renewal = task
        defer { renewal = nil }
        return try await task.value
    }

    private func performRenewal() async throws -> CloudSession {
        let jws = await purchasing.currentTransactionJWS()
        do {
            let s = try await requestSession(jws: jws)
            adopt(s)
            return s
        } catch let error as CloudAPIError {
            throw sessionFailure(error)
        }
    }

    /// POST /v1/session; a transaction that belongs to another account is dropped and the call repeated without it.
    private func requestSession(jws: String?) async throws -> CloudSession {
        let device = try loadDevice()
        do {
            return try await client.session(device: device, transactionJWS: jws)
        } catch let error as CloudAPIError where error.code == "wrong_account" && jws != nil {
            return try await client.session(device: device, transactionJWS: nil)
        }
    }

    /// Records what a failed renewal means for this Mac and returns what the caller should see.
    private func sessionFailure(_ error: CloudAPIError) -> CloudTransportError {
        switch error.code {
        case "device_revoked":
            session = nil; identity = nil; setState(.deviceRevoked)
            return .deviceRevoked
        case "unknown_device", "device_pending", "enrollment_expired":
            session = nil; identity = nil
            return .unauthorized
        default:
            return CloudTransportError(api: error)
        }
    }

    private func adopt(_ s: CloudSession) {
        session = s
        let version = UInt8(exactly: s.library.keyVersion) ?? 1
        identity = CloudAccountIdentity(accountId: s.accountId, deviceId: s.deviceId, epoch: UInt64(max(0, s.epoch)), keyVersion: version, readOnly: s.readOnly)
        switch state {
        case .ready where s.readOnly, .readOnly:
            setState(readOnlyOrReady(s))
        default: break
        }
    }

    private func readOnlyOrReady(_ s: CloudSession) -> CloudAccountState {
        if s.state == .softDeleted || s.state == .deleted { return .readOnly(.removed) }
        if s.readOnly { return .readOnly(.from(server: s.state, local: purchasing.access)) }
        return .ready
    }

    private func setState(_ new: CloudAccountState) {
        guard new != state else { return }
        Logger.info("Cloud: account \(state) -> \(new)", subsystem: .app)
        state = new
    }

    private func loadDevice() throws -> CloudDeviceKey {
        if let deviceKey { return deviceKey }
        do {
            let key = try CloudDeviceKey.loadOrCreate(keychain: deviceKeychain, service: deviceKeyService)
            deviceKey = key
            return key
        } catch {
            Logger.error("Cloud: the device key is unavailable", subsystem: .app)
            throw CloudAPIError(status: 0, code: "keychain", message: "The device key is unavailable", retryAfter: nil, body: Data())
        }
    }

    // MARK: Launch / wake / retry

    /// Works out where this Mac stands from the server's own answer (a signed `POST /v1/session` tells an
    /// authorized, pending, unknown or revoked device apart) and moves the state machine there. Call at launch,
    /// on wake, after the Keychain may have changed, and for "Try again". Safe to call at any time.
    func refresh() async {
        if let reconcileTask { await reconcileTask.value; return }
        switch state {
        case .purchasing, .resetting, .creatingAccount, .creatingLibrary, .confirming: return
        default: break
        }
        let task = Task { await self.reconcile() }
        reconcileTask = task
        await task.value
        reconcileTask = nil
    }

    private func reconcile() async {
        let jws = await purchasing.currentTransactionJWS()
        do {
            let s = try await requestSession(jws: jws)
            adopt(s)
            await afterSession(s)
        } catch let error as CloudAPIError {
            await handleSessionFailure(error, jws: jws)
        } catch {
            setState(.unavailable(.server(code: "unexpected")))
        }
    }

    private func handleSessionFailure(_ error: CloudAPIError, jws: String?) async {
        switch error.code {
        case "unknown_device":
            session = nil; identity = nil
            if let jws { await setUp(jws: jws) } else { setState(.notSubscribed) }
        case "device_pending", "enrollment_expired":
            session = nil; identity = nil
            if let jws { await enrol(jws: jws) } else { setState(.enrolPending) }
        case "device_revoked":
            session = nil; identity = nil; setState(.deviceRevoked)
        case "subscription_expired":
            setState(.readOnly(.removed))
        case "keychain":
            setState(.unavailable(.keychain))
        default:
            setState(.unavailable(CloudAccountProblem(error)))
        }
    }

    /// Call when the Keychain may have received the library key (wake, launch, the user tapping "Check again").
    func recheckKey() async {
        guard case .needsKey = state else { return }
        if let pending = pendingEnrollment {
            await confirm(pending)
        } else if let s = session {
            await afterSession(s)
        } else {
            await refresh()
        }
    }

    // MARK: Purchase and account creation

    private var canStartPurchase: Bool {
        if case .unavailable = state { return true }
        return state == .notSubscribed
    }

    func purchase(_ product: CloudProduct) async {
        guard canStartPurchase else { return }
        lastError = nil
        setState(.purchasing)
        let outcome = await purchasing.purchase(product)
        switch outcome {
        case .purchased:
            isPurchasePending = false
            await continueAfterPurchase()
        case .pending:
            isPurchasePending = true
            setState(.notSubscribed)
        case .cancelled:
            setState(.notSubscribed)
        case nil:
            lastError = "The purchase could not be completed. You have not been charged."
            setState(.notSubscribed)
        }
    }

    /// Restore Purchases: re-read the subscription, then continue as if it had just been bought.
    func restorePurchases() async {
        lastError = nil
        await purchasing.refresh()
        if canStartPurchase { await continueAfterPurchase() }
    }

    private func continueAfterPurchase() async {
        guard let jws = await purchasing.currentTransactionJWS() else {
            lastError = "The purchase has not arrived yet. Try again in a moment."
            setState(.notSubscribed)
            return
        }
        await setUp(jws: jws)
    }

    /// A subscription exists and this Mac is unknown to the server: create the account, or — when the
    /// subscription already has one — enrol this Mac into it.
    private func setUp(jws: String) async {
        setState(.creatingAccount)
        do {
            let s = try await client.createAccount(transactionJWS: jws, device: try loadDevice(), appVersion: appVersion)
            adopt(s)
            await afterSession(s)
        } catch let error as CloudAPIError where error.code == "already_bound" {
            await enrol(jws: jws)
        } catch let error as CloudAPIError {
            await handleSetUpFailure(error)
        } catch {
            setState(.unavailable(.server(code: "unexpected")))
        }
    }

    private func handleSetUpFailure(_ error: CloudAPIError) async {
        switch error.code {
        case "subscription_expired": setState(.readOnly(.removed))
        case "device_bound": // this device key belongs to another account: it can never be reused
            setState(.deviceRevoked)
        case "keychain": setState(.unavailable(.keychain))
        default: setState(.unavailable(CloudAccountProblem(error)))
        }
    }

    // MARK: New Mac: enrolment and the key

    private func enrol(jws: String) async {
        setState(.enrolPending)
        do {
            let enrollment = try await client.enrollDevice(transactionJWS: jws, device: try loadDevice(), appVersion: appVersion)
            pendingEnrollment = enrollment
            await confirm(enrollment)
        } catch let error as CloudAPIError where error.code == "device_enrolled" {
            // Raced with ourselves: the device is authorized already. Reconcile from the session.
            await reconcileAfterRace(jws: jws)
        } catch let error as CloudAPIError where error.code == "device_revoked" {
            setState(.deviceRevoked)
        } catch let error as CloudAPIError where error.code == "subscription_expired" {
            setState(.readOnly(.removed))
        } catch let error as CloudAPIError {
            setState(.unavailable(CloudAccountProblem(error)))
        } catch {
            setState(.unavailable(.server(code: "unexpected")))
        }
    }

    private func reconcileAfterRace(jws: String) async {
        do {
            let s = try await requestSession(jws: jws)
            adopt(s)
            await afterSession(s)
        } catch let error as CloudAPIError {
            setState(.unavailable(CloudAccountProblem(error)))
        } catch {
            setState(.unavailable(.server(code: "unexpected")))
        }
    }

    /// Proves the library key for a pending Mac, or waits for it.
    private func confirm(_ enrollment: CloudEnrollment) async {
        do {
            let device = try loadDevice()
            let ring = try keyStore.loadRing()
            switch CloudKeyDecision.decide(library: enrollment.library, ring: ring) {
            case .noLibrary:
                setState(.confirming)
                let s = try await client.confirmDevice(device: device, keyProof: "")
                pendingEnrollment = nil
                adopt(s)
                await afterSession(s)
            case .needsKey:
                setState(.needsKey(CloudNeedsKey(recoveryAvailable: enrollment.library.recoveryAvailable)))
            case .prove(let version):
                setState(.confirming)
                guard let master = ring.symmetricKey(version: version) else { setState(.needsKey(CloudNeedsKey(recoveryAvailable: enrollment.library.recoveryAvailable))); return }
                let proof = try CloudCrypto.keyProof(authKey: CloudCrypto.authKey(master: master), challengeHex: enrollment.enrollChallenge, deviceId: device.deviceId)
                do {
                    let s = try await client.confirmDevice(device: device, keyProof: proof)
                    pendingEnrollment = nil
                    adopt(s)
                    await afterSession(s)
                } catch let error as CloudAPIError where error.code == "bad_key_proof" {
                    // The key in this Mac's Keychain is not the library's (stale, or from another library).
                    setState(.needsKey(CloudNeedsKey(recoveryAvailable: enrollment.library.recoveryAvailable, wrongKey: true)))
                }
            }
        } catch let error as CloudAPIError {
            switch error.code {
            case "device_limit": setState(.unavailable(.deviceLimit))
            case "enrollment_changed", "enrollment_expired": pendingEnrollment = nil; await refresh()
            default: setState(.unavailable(CloudAccountProblem(error)))
            }
        } catch {
            setState(.unavailable(.keychain))
        }
    }

    /// The user typed their recovery key. It unlocks the key ring through the server's recovery blob (usable
    /// before enrolment), the ring goes into the Keychain, and the key proof follows.
    func submitRecoveryKey(_ text: String) async {
        guard case .needsKey(let needs) = state else { return }
        lastError = nil
        let fail = { (wrong: Bool) in
            var updated = needs; updated.wrongRecoveryKey = wrong
            self.setState(.needsKey(updated))
        }
        guard let recoveryKey = try? CloudRecoveryKey.decode(text) else { fail(true); return }
        guard let jws = await purchasing.currentTransactionJWS() else {
            lastError = "Your subscription could not be read. Try again in a moment."
            return
        }
        do {
            let blob = try await client.recoveryBlob(device: try loadDevice(), transactionJWS: jws)
            guard let wrapped = Data(base64Encoded: blob.wrapped), let version = UInt8(exactly: blob.keyVersion),
                  let accountId = CloudRecoveryBlobCodec.accountId(fromKdf: blob.kdf) ?? session?.accountId else {
                lastError = "The recovery information on the server could not be read."
                return
            }
            let ring: CloudKeyRing
            do {
                ring = try CloudRecoveryKey.unwrap(wrapped, recoveryKey: recoveryKey, accountId: accountId, keyVersion: version)
            } catch { fail(true); return }
            try keyStore.saveRing(ring)
            if let pending = pendingEnrollment { await confirm(pending) } else if let s = session { await afterSession(s) } else { await refresh() }
        } catch let error as CloudAPIError {
            lastError = error.code == "no_recovery" ? "This library has no recovery key." : Self.message(for: error)
        } catch {
            lastError = "The key could not be saved to the Keychain."
        }
    }

    // MARK: After a session exists

    /// This Mac is an authorized device with a session: decide between creating the library, using the key it
    /// holds, or waiting for one.
    private func afterSession(_ s: CloudSession) async {
        pendingEnrollment = nil
        do {
            switch CloudKeyDecision.decide(library: s.library, ring: try keyStore.loadRing()) {
            case .noLibrary: await createLibrary()
            case .prove(let version):
                if try keyIsStaleAfterReset(s, version: version) {
                    setState(.needsKey(CloudNeedsKey(recoveryAvailable: s.library.recoveryAvailable, wrongKey: true)))
                } else {
                    setState(readOnlyOrReady(s))
                }
            case .needsKey: setState(.needsKey(CloudNeedsKey(recoveryAvailable: s.library.recoveryAvailable)))
            }
        } catch {
            setState(.unavailable(.keychain))
        }
    }

    // MARK: Stale key after a reset elsewhere

    /// Records that this Mac's key is the right one for `epoch` (it created the library, or proved the key).
    private func rememberKeyEpoch(accountId: String, epoch: Int, version: UInt8) {
        guard let master = try? keyStore.loadRing().keys[version] else { return }
        let fingerprint = SHA256.hash(data: master).map { String(format: "%02x", $0) }.joined()
        epochDefaults.set("\(epoch):\(fingerprint)", forKey: "WhispererCloud.keyEpoch.\(accountId)")
    }

    /// A reset on another Mac starts a new epoch with a NEW key, but the new library's key version is 1 again, so a Mac that
    /// still holds the OLD key looks fine to `CloudKeyDecision` and an existing device gets its session without a key proof.
    /// Such a Mac would then encrypt its history under the dead key into the clean library and poison it for every other Mac.
    /// So this Mac remembers, per account, the epoch it last used a key in and which key (a fingerprint, never the key). A
    /// newer epoch with the very same key means a reset happened and the key has not been replaced yet: wait for it.
    private func keyIsStaleAfterReset(_ s: CloudSession, version: UInt8) throws -> Bool {
        guard let master = try keyStore.loadRing().keys[version] else { return false }
        let fingerprint = SHA256.hash(data: master).map { String(format: "%02x", $0) }.joined()
        let slot = "WhispererCloud.keyEpoch.\(s.accountId)"
        if let saved = epochDefaults.string(forKey: slot) {
            let parts = saved.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let epoch = Int(parts[0]), epoch < s.epoch, parts[1] == fingerprint { return true }
        }
        rememberKeyEpoch(accountId: s.accountId, epoch: s.epoch, version: version)
        return false
    }

    /// Generates the first key — only because the server just said there is no library — and registers it.
    private func createLibrary() async {
        setState(.creatingLibrary)
        do {
            // The server has no library: any key already in the Keychain belongs to a library that no longer exists.
            try keyStore.deleteAll()
            let master = try keyStore.generateFirstKey(libraryExists: false)
            let masterBytes = master.withUnsafeBytes { Data($0) }
            let verifier = CloudCrypto.verifier(authKey: CloudCrypto.authKey(master: master)).cloudHex
            switch try await client.createLibrary(keyVerifierHex: verifier, keyVersion: 1) {
            case .created(let version):
                session?.library = CloudLibraryInfo(exists: true, keyVersion: version, recoveryAvailable: false)
                if let s = session { adopt(s) }
                if let s = session, let v = UInt8(exactly: version) { rememberKeyEpoch(accountId: s.accountId, epoch: s.epoch, version: v) }
                setState(.offerRecoveryKey)
            case .alreadyExists(let info):
                discardGeneratedKey(masterBytes)
                session?.library = info
                if let s = session { adopt(s); await afterSession(s) }
            }
        } catch let error as CloudAPIError {
            // The generated key stays: the request may have reached the server. The next refresh sorts it out
            // (a library with this key is adopted; no library means the key was never used and is replaced).
            setState(.unavailable(CloudAccountProblem(error)))
        } catch {
            setState(.unavailable(.keychain))
        }
    }

    /// Removes the key this Mac just generated after losing the creation race. Only that exact key: if iCloud
    /// Keychain has meanwhile delivered the winner's key into the same slot, it is left alone.
    private func discardGeneratedKey(_ generated: Data) {
        guard let ring = try? keyStore.loadRing() else { return }
        if ring.keys[1] == generated { try? keyStore.keychain.delete(service: keyStore.service, account: "master.v1", synchronizable: true) }
    }

    // MARK: Recovery key

    /// Wraps the key ring under a fresh recovery key, stores the wrapped blob on the server, and shows the recovery
    /// key once (`showRecoveryKey`). Callable from `offerRecoveryKey` and later from `ready` ("create a new
    /// recovery key").
    func createRecoveryKey() async {
        guard let s = session else { return }
        lastError = nil
        do {
            let ring = try keyStore.loadRing()
            guard let version = UInt8(exactly: s.library.keyVersion), let master = ring.symmetricKey(version: version) else {
                lastError = "This Mac does not hold the library key."
                return
            }
            let recovery = try CloudRecoveryKey.generate()
            let wrapped = try CloudRecoveryKey.wrap(ring: ring, recoveryKey: recovery, accountId: s.accountId, keyVersion: version)
            try await client.putRecovery(device: try loadDevice(), authKey: CloudCrypto.authKey(master: master),
                                         wrapped: wrapped.base64EncodedString(), kdf: CloudRecoveryBlobCodec.kdf(accountId: s.accountId))
            session?.library.recoveryAvailable = true
            setState(.showRecoveryKey(try CloudRecoveryKey.encode(recovery)))
        } catch let error as CloudAPIError {
            lastError = Self.message(for: error)
        } catch {
            lastError = "The recovery key could not be created."
        }
    }

    /// The user saved the recovery key (or chose to skip): on to `ready`.
    func finishRecoveryKey() {
        guard let s = session else { return }
        switch state {
        case .offerRecoveryKey, .showRecoveryKey: setState(readOnlyOrReady(s))
        default: break
        }
    }

    // MARK: Reset

    /// Starts the library over: a new epoch, no key, no recovery blob; local history is untouched. Requires the
    /// typed phrase. Works from an authorized Mac (session) and from one stuck in `needsKey` (device signature +
    /// transaction).
    func resetLibrary(confirmation: String) async {
        guard CloudResetPhrase.matches(confirmation) else {
            lastError = "Type RESET MY LIBRARY exactly to confirm."
            return
        }
        lastError = nil
        let previous = state
        setState(.resetting)
        do {
            let phrase = CloudResetPhrase.phrase
            if session != nil {
                _ = try await client.resetLibrary(confirm: phrase)
            } else {
                guard let jws = await purchasing.currentTransactionJWS() else {
                    lastError = "Your subscription could not be read. Try again in a moment."
                    setState(previous)
                    return
                }
                _ = try await client.resetLibrary(confirm: phrase, device: try loadDevice(), transactionJWS: jws)
            }
            try? keyStore.deleteAll()
            pendingEnrollment = nil
            accountInfo = nil
            let s = try await requestSession(jws: await purchasing.currentTransactionJWS())
            adopt(s)
            await afterSession(s)
        } catch let error as CloudAPIError {
            lastError = Self.message(for: error)
            setState(previous)
        } catch {
            lastError = "The reset could not be completed."
            setState(previous)
        }
    }

    // MARK: Devices

    func refreshAccount() async {
        do { accountInfo = try await client.account() } catch let error as CloudAPIError {
            lastError = Self.message(for: error)
        } catch {}
    }

    /// Removes a Mac from the account. Removing this very Mac signs it out.
    func revokeDevice(id: String) async {
        lastError = nil
        do {
            try await client.revokeDevice(id: id)
            if id == identity?.deviceId {
                session = nil; identity = nil; accountInfo = nil
                setState(.deviceRevoked)
            } else {
                await refreshAccount()
            }
        } catch let error as CloudAPIError {
            lastError = Self.message(for: error)
        } catch {}
    }

    /// A revoked device key can never enrol again. This makes a new one and starts over (the library key is
    /// still in the Keychain, so the Mac re-enrols without typing anything).
    func startOver() async {
        try? CloudDeviceKey.delete(keychain: deviceKeychain, service: deviceKeyService)
        deviceKey = nil; session = nil; identity = nil; pendingEnrollment = nil; accountInfo = nil
        setState(.notSubscribed)
        await refresh()
    }

    // MARK: Messages

    private static func message(for error: CloudAPIError) -> String {
        if error.isOffline { return "You are offline. Try again when you are connected." }
        switch error.code {
        case "bad_key_proof": return "That key does not match this library."
        case "rate_limited": return "Too many attempts. Try again later."
        case "device_limit": return "This plan's device limit is reached. Remove a Mac first."
        case "read_only": return "Your subscription is not active."
        default: return "Something went wrong (\(error.code)). Try again."
        }
    }
}
