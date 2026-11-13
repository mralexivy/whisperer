//
//  CloudPanelModel.swift
//  Whisperer
//
//  Behaviour of the Cloud panel (DESIGN.md: logic in a model, the view only renders). It mirrors the account
//  state machine, owns the little state a screen needs of its own (a typed phrase, an open confirmation, the
//  "I have saved it" tick), and forwards every action to the account. The recovery key lives only in the
//  controller's `showRecoveryKey(String)` payload; this model never stores or logs it.
//

import SwiftUI
import Combine

@MainActor
final class CloudPanelModel: ObservableObject {

    enum Step: Equatable { case purchasing, creatingAccount, creatingLibrary, confirming, resetting }

    /// What the panel shows. One value per screen, derived from the account state.
    enum Screen: Equatable {
        case intro
        case awaitingApproval
        case progress(Step)
        case offerRecoveryKey
        case showRecoveryKey(String)
        case ready
        case readOnly(CloudReadOnlyReason)
        /// `nil` while the Mac is still being added; the needs-key details once the library says it has no key here.
        case newMac(CloudNeedsKey?)
        case deviceRevoked
        case unavailable(CloudAccountProblem)
    }

    struct Usage: Equatable {
        var storedBytes: Int64
        var quotaBytes: Int64
        var downloadBytes: Int64
        var downloadQuotaBytes: Int64
        var fraction: Double { quotaBytes > 0 ? min(1, Double(storedBytes) / Double(quotaBytes)) : 0 }
        var downloadFraction: Double { downloadQuotaBytes > 0 ? min(1, Double(downloadBytes) / Double(downloadQuotaBytes)) : 0 }
        var overBytes: Int64 { max(0, storedBytes - quotaBytes) }
    }

    /// Hook that supplies the real account when the app builds the panel by itself. The release wiring
    /// replaces it with the configured `CloudAccountController`.
    static var makeLiveAccount: @MainActor () -> any CloudAccountDriving = { CloudUnconfiguredAccount() }
    static func live() -> CloudPanelModel { CloudPanelModel(account: makeLiveAccount()) }

    let account: any CloudAccountDriving
    let sync: any CloudSyncStatusSource
    let environment: CloudPanelEnvironment
    /// "Export my history": the host unfolds its Export panel.
    var onExportHistory: (() -> Void)?

    // Screen-local state
    @Published var keyConfirmed = false
    @Published private(set) var keyCopied = false
    @Published private(set) var keyFileSaved = false
    @Published var keyEntry = ""
    @Published var resetPhrase = ""
    @Published var advancedOpen = false
    @Published private(set) var revokeCandidate: String?
    @Published var showsPlans = false
    @Published var confirmsNewRecoveryKey = false
    @Published private(set) var isBusy = false

    private var bag = Set<AnyCancellable>()
    private var lastScreen: Screen
    private var copiedTask: Task<Void, Never>?

    init(account: any CloudAccountDriving, sync: (any CloudSyncStatusSource)? = nil,
         environment: CloudPanelEnvironment = .live, onExportHistory: (() -> Void)? = nil) {
        self.account = account
        self.sync = sync ?? NoopCloudSyncStatusSource()
        self.environment = environment
        self.onExportHistory = onExportHistory
        self.lastScreen = Self.screen(for: account.state, pending: account.isPurchasePending)
        account.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.accountChanged() }
            .store(in: &bag)
        self.sync.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }

    // MARK: Derived state

    var state: CloudAccountState { account.state }
    var info: CloudAccountInfo? { account.accountInfo }
    var lastError: String? { account.lastError }
    var screen: Screen { Self.screen(for: account.state, pending: account.isPurchasePending) }

    nonisolated static func screen(for state: CloudAccountState, pending: Bool) -> Screen {
        switch state {
        case .notSubscribed: return pending ? .awaitingApproval : .intro
        case .purchasing: return .progress(.purchasing)
        case .creatingAccount: return .progress(.creatingAccount)
        case .creatingLibrary: return .progress(.creatingLibrary)
        case .confirming: return .progress(.confirming)
        case .resetting: return .progress(.resetting)
        case .offerRecoveryKey: return .offerRecoveryKey
        case .showRecoveryKey(let key): return .showRecoveryKey(key)
        case .ready: return .ready
        case .readOnly(let reason): return .readOnly(reason)
        case .enrolPending: return .newMac(nil)
        case .needsKey(let needs): return .newMac(needs)
        case .deviceRevoked: return .deviceRevoked
        case .unavailable(let problem): return .unavailable(problem)
        }
    }

    var usage: Usage? {
        guard let info else { return nil }
        return Usage(storedBytes: info.usage?.storedBytes ?? 0, quotaBytes: info.plan.storedBytes,
                     downloadBytes: info.usage?.downloadBytes ?? 0, downloadQuotaBytes: info.plan.monthlyDownloadBytes)
    }

    /// How much must go (or be bought) before uploads work again; nil when the library fits.
    var overQuotaBytes: Int64? {
        guard let over = usage?.overBytes, over > 0 else { return nil }
        return over
    }

    /// Authorized and waiting Macs, this one first. Revoked ones are gone from the user's point of view.
    var devices: [CloudDeviceInfo] {
        (info?.devices ?? []).filter { $0.state != .revoked }
            .sorted { ($0.current ? 0 : 1, $0.enrolledAt) < ($1.current ? 0 : 1, $1.enrolledAt) }
    }

    var planTitle: String {
        guard let name = info?.plan.name else { return "Whisperer Cloud" }
        return CloudTier(rawValue: name.lowercased())?.title ?? name.capitalized
    }

    var recoveryKeyIsSet: Bool { info?.library.recoveryAvailable ?? false }
    var canRevoke: Bool { !isBusy }
    var resetPhraseMatches: Bool { CloudResetPhrase.matches(resetPhrase) }
    var keyEntryHasText: Bool { !keyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The letters and digits typed so far, ignoring spaces, hyphens and case, as the key parser does.
    var keyEntryCharacterCount: Int {
        keyEntry.filter { !$0.isWhitespace && $0 != "-" }.count
    }

    // MARK: Account changes

    private func accountChanged() {
        objectWillChange.send()
        let now = screen
        guard now != lastScreen else { return }
        let before = lastScreen
        lastScreen = now
        if case .showRecoveryKey = before { keyConfirmed = false; keyCopied = false; keyFileSaved = false }
        if case .showRecoveryKey = now { keyConfirmed = false; keyCopied = false; keyFileSaved = false }
        revokeCandidate = nil
        confirmsNewRecoveryKey = false
        switch now {
        case .ready, .readOnly:
            showsPlans = false
            if info == nil { Task { [weak self] in await self?.account.refreshAccount() } }
        case .intro, .newMac:
            break
        default: break
        }
    }

    /// Call when the panel appears: reconcile with the server, then load the account details.
    func start() async {
        await account.refresh()
        switch account.state {
        case .ready, .readOnly: await account.refreshAccount()
        default: break
        }
    }

    private func run(_ work: @escaping @MainActor (CloudPanelModel) async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        Task { [weak self] in
            guard let self else { return }
            await work(self)
            self.isBusy = false
        }
    }

    // MARK: Actions

    func restorePurchases() { run { await $0.account.restorePurchases() } }
    func tryAgain() { run { await $0.account.refresh() } }
    func checkApproval() { run { await $0.account.restorePurchases() } }
    func recheckKey() { run { await $0.account.recheckKey() } }
    func startOver() { run { await $0.account.startOver() } }
    func planPurchased() async { await account.refresh() }

    func showResubscribe() { showsPlans = true }

    func submitRecoveryKey() {
        guard keyEntryHasText else { return }
        let text = keyEntry
        run { model in
            await model.account.submitRecoveryKey(text)
            if case .needsKey = model.account.state {} else { model.keyEntry = "" }
        }
    }

    func pasteRecoveryKey() {
        if let text = environment.readClipboard(), !text.isEmpty { keyEntry = text }
    }

    func createRecoveryKey() {
        confirmsNewRecoveryKey = false
        run { await $0.account.createRecoveryKey() }
    }

    func skipRecoveryKey() { account.finishRecoveryKey() }

    /// Only after the user ticked "I have saved it".
    func finishRecoveryKey() {
        guard keyConfirmed else { return }
        account.finishRecoveryKey()
    }

    func copyRecoveryKey() {
        guard case .showRecoveryKey(let key) = account.state else { return }
        environment.copy(key, true)
        keyCopied = true
        copiedTask?.cancel()
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.keyCopied = false
        }
    }

    func saveRecoveryKeyFile() {
        guard case .showRecoveryKey(let key) = account.state else { return }
        if environment.saveRecoveryKeyFile(key) { keyFileSaved = true }
    }

    func printRecoveryKey() {
        guard case .showRecoveryKey(let key) = account.state else { return }
        environment.printRecoveryKey(key)
    }

    func requestRevoke(_ id: String) { revokeCandidate = id }
    func cancelRevoke() { revokeCandidate = nil }

    func confirmRevoke() {
        guard let id = revokeCandidate else { return }
        revokeCandidate = nil
        run { await $0.account.revokeDevice(id: id) }
    }

    func toggleSyncPaused() {
        if sync.status == .paused { sync.resume() } else { sync.pause() }
    }

    func syncNow() { run { await $0.sync.syncNow() } }

    func manageSubscription() { environment.openSubscriptionManagement() }

    func exportHistory() { onExportHistory?() }

    /// Delete cloud data: only with the exact phrase.
    func resetLibrary() {
        guard resetPhraseMatches else { return }
        let phrase = resetPhrase
        resetPhrase = ""
        advancedOpen = false
        run { await $0.account.resetLibrary(confirmation: phrase) }
    }

    // MARK: Wording

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    func date(_ date: Date) -> String { date.formatted(.dateTime.day().month(.wide).year()) }

    func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: environment.now())
    }
}
