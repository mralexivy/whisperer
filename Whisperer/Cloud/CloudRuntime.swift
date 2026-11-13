//
//  CloudRuntime.swift
//  Whisperer
//
//  Owns Whisperer Cloud at runtime: builds the account controller for the right service, starts the sync
//  engine when (and only when) the account is ready or read-only and holds a verified key, stops it when the
//  account is not, and exposes the engine's status to the Cloud panel. Started once at launch, and only when
//  `CloudFeature.isAvailable` — the App Store build once Cloud is live.
//
//  One sync ledger and outbox per account *and epoch*: a reset starts a clean library, and a second Apple
//  Account on the same Mac can never mix into the first one's ledger.
//

import Foundation
import AppKit
import Combine

@MainActor
final class CloudRuntime: ObservableObject, CloudSyncStatusSource {
    static let shared = CloudRuntime()

    @Published private(set) var status: CloudSyncStatus = .idle
    @Published private(set) var lastSyncedAt: Date?
    @Published private(set) var pendingChanges = 0

    private(set) var account: CloudAccountController?

    private var engine: SyncEngine?
    private var engineIdentity: SyncIdentity?
    private var statusTask: Task<Void, Never>?
    private var observer: SyncChangeObserver?
    private var cancellables = Set<AnyCancellable>()
    private var systemObservers: [NSObjectProtocol] = []
    private var started = false
    private var lastAccountCheck = Date.distantPast

    private init() {}

    /// Launch hook. Safe to call more than once.
    func start() async {
        guard !started, CloudFeature.isAvailable else { return }
        started = true
        let environment = await CloudConfig.detectEnvironment()
        let controller = CloudAccountController(
            http: CloudHTTP(baseURL: CloudConfig.baseURL(for: environment)),
            purchasing: CloudStoreKitPurchasing(store: .shared),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        account = controller
        CloudPanelModel.makeLiveAccount = { controller }
        Logger.info("Cloud: runtime started (\(environment == .production ? "production" : "sandbox") service)", subsystem: .app)

        // The published values change before the property is set, so reconcile on the next turn.
        controller.$state.combineLatest(controller.$identity)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.reconcile() }
            .store(in: &cancellables)
        observeSystem()
        await controller.refresh()
    }

    // MARK: CloudSyncStatusSource

    func pause() { Task { [engine] in await engine?.pause() } }
    func resume() { Task { [engine] in await engine?.resume() } }
    func syncNow() async { _ = await engine?.syncNow() }

    // MARK: Engine lifecycle

    private func reconcile() {
        guard let account else { return }
        switch account.state {
        case .ready, .readOnly:
            guard let id = account.identity else { stopEngine(); return }
            let identity = SyncIdentity(accountId: id.accountId, epoch: Int(id.epoch), deviceId: id.deviceId)
            if engine != nil, engineIdentity == identity { return }
            startEngine(identity, account: account)
        default:
            stopEngine()
        }
    }

    private func startEngine(_ identity: SyncIdentity, account: CloudAccountController) {
        stopEngine()
        guard let environment = SyncStoreEnvironment.app() else {
            status = .error("Your history could not be opened, so it cannot sync.")
            Logger.error("Cloud: history store unavailable, sync not started", subsystem: .app)
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("Whisperer/Cloud/\(identity.accountId)/e\(identity.epoch)", isDirectory: true)
        let keys = account.keys
        let engine: SyncEngine
        do {
            engine = try SyncEngine(identity: identity, transport: account.makeTransport(), environment: environment,
                                    cloudDirectory: directory, keyProvider: { try? keys.loadRing() })
        } catch {
            status = .error("Sync could not start on this Mac.")
            Logger.error("Cloud: sync ledger could not be opened: \(error.localizedDescription)", subsystem: .app)
            return
        }
        self.engine = engine
        engineIdentity = identity
        observer = SyncChangeObserver(coordinator: HistoryDatabase.shared.persistentContainer?.persistentStoreCoordinator) { [weak engine] keys in
            guard let engine else { return }
            Task { await engine.noteLocalChange(keys: keys) }
        }
        statusTask = Task { [weak self] in
            await engine.markKeyVerified() // the account layer only reaches ready after the key proof passed
            await engine.start(foreground: NSApp?.isActive ?? true)
            for await s in await engine.statusUpdates() {
                guard let self else { return }
                self.apply(s)
            }
        }
        Logger.info("Cloud: sync engine started", subsystem: .app)
    }

    private func stopEngine() {
        statusTask?.cancel()
        statusTask = nil
        observer = nil
        if let engine { Task { await engine.stop() } }
        engine = nil
        engineIdentity = nil
        status = .idle
        pendingChanges = 0
    }

    private func apply(_ s: SyncStatus) {
        lastSyncedAt = s.lastSyncAt
        pendingChanges = s.pendingChanges + s.pendingAudio
        recheckAccountIfNeeded(for: s.phase)
        switch s.phase {
        case .idle: status = .idle
        case .syncing:
            if let initial = s.initialUpload, initial.total > 0 {
                status = .syncing(progress: min(1, Double(initial.done) / Double(initial.total)))
            } else {
                status = .syncing(progress: nil)
            }
        case .offline: status = .offline
        case .paused: status = .paused
        case .readOnly: status = .readOnly
        case .needsKey: status = .needsKey
        case .overQuota: status = .overQuota
        case .error(let message): status = .error(message)
        }
    }

    /// An engine error or a missing key can mean the account moved under us — another Mac reset the library or
    /// removed this one. Ask the server again (at most once a minute) so the panel shows the true state at once
    /// instead of at the next launch or token renewal.
    private func recheckAccountIfNeeded(for phase: SyncPhase) {
        switch phase {
        case .error, .needsKey: break
        default: return
        }
        let now = Date()
        guard now.timeIntervalSince(lastAccountCheck) > 60, let account else { return }
        lastAccountCheck = now
        Task { await account.refresh() }
    }

    // MARK: System events

    private func observeSystem() {
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.engine?.setForeground(true) }
        })
        systemObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.engine?.setForeground(false) }
        })
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.engine?.wake()
                await self?.account?.recheckKey()
            }
        })
    }
}

