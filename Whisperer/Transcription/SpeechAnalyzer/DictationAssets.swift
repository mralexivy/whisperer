//
//  DictationAssets.swift
//  Whisperer
//
//  The one place that decides whether Apple dictation can stream a locale, and the only caller of
//  Apple's asset APIs for live text. Every reader — the status shown in Settings, the launch-time
//  auto-install, a session opening its analyzer — goes through `prepare`, so they cannot disagree.
//
//  What Apple does, measured on two Macs (2026-11-05):
//  - Installed assets: `assetInstallationRequest` returns nil.
//  - On a second Mac it returned a request for installed en/ru/he on every call; completing it took
//    0.4 s (a real download ~25 s). A request is therefore not "missing": it is completed here, and
//    whether that is quick decides between "ready" and "installing".
//  - At most `maximumReservedLocales` (5) locales per app, kept across launches. Past that every
//    request throws SFSpeechErrorDomain 11, "Too many allocated locales", and nothing ever frees a
//    slot on its own — so a locale no longer in use is released to make room.
//  - `installedLocales` and `AssetInventory.status` are hints only: the first listed en-US on the
//    Mac whose request still had to run; the second never reports `.installed` for locales
//    System Settings installed.
//

import Foundation
import Speech

/// One install Apple handed out: the asset download, or just the allocation step.
nonisolated protocol DictationAssetJob: AnyObject, Sendable {
    var fractionCompleted: Double { get }
    func run() async throws
}

/// Apple's asset state, behind a seam so tests can stand in for each behavior above.
nonisolated protocol DictationAssetStore: Sendable {
    /// Nil when Apple has nothing to install for `locale`.
    func job(for locale: Locale) async throws -> (any DictationAssetJob)?
    func reservedLocaleIDs() async -> [String]
    var maximumReserved: Int { get }
    func release(_ localeID: String) async
}

/// Readiness of one locale.
nonisolated enum DictationAssetOutcome: Equatable, Sendable {
    case ready
    /// Still downloading in the background; the fraction done.
    case installing(Double)
    case failed(String)
}

actor DictationAssets {
    static let shared = DictationAssets()

    private var store: any DictationAssetStore = AppleDictationAssetStore()
    /// Locales usable in this process: nothing to install, or an install that finished here.
    private var ready: Set<String> = []
    private var inFlight: [String: (task: Task<Bool, Never>, job: any DictationAssetJob)] = [:]

    /// Ready, installing or failed, waiting at most `budget` seconds for an install to finish.
    /// Never starts a second install of the same locale, and never asks Apple again once ready.
    func prepare(_ locale: Locale, within budget: Double) async -> DictationAssetOutcome {
        let id = locale.identifier(.bcp47)
        if ready.contains(id) { return .ready }
        if let running = inFlight[id] { return await wait(id, running.task, running.job, budget) }

        let job: (any DictationAssetJob)?
        do {
            job = try await requestMakingRoom(locale, id: id)
        } catch {
            Logger.warning("System dictation: \(id) unavailable — \(error.localizedDescription)", subsystem: .model)
            return .failed(error.localizedDescription)
        }
        // Reentrancy: another caller may have started or finished the same locale meanwhile.
        if ready.contains(id) { return .ready }
        if let running = inFlight[id] { return await wait(id, running.task, running.job, budget) }
        guard let job else {
            ready.insert(id)
            return .ready
        }

        Logger.info("System dictation: installing \(id)", subsystem: .model)
        let started = Date()
        let task = Task { () -> Bool in
            do { try await job.run(); return true } catch {
                Logger.warning("System dictation: installing \(id) failed — \(error.localizedDescription)", subsystem: .model)
                return false
            }
        }
        inFlight[id] = (task, job)
        Task { [weak self] in
            let ok = await task.value
            await self?.finish(id, ok: ok, seconds: Date().timeIntervalSince(started))
        }
        return await wait(id, task, job, budget)
    }

    /// Install `locale` to the end, reporting progress. For the UI's explicit install.
    func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        while true {
            switch await prepare(locale, within: 0.2) {
            case .ready:
                progress(1)
                return
            case .installing(let fraction):
                progress(fraction)
            case .failed(let reason):
                throw NSError(domain: "Whisperer.DictationAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
        }
    }

    /// Whether `id` is known usable in this process, without asking Apple.
    func isReady(_ id: String) -> Bool { ready.contains(id) }

    /// Locales another component may release: not used for live text in this process.
    func isInUse(_ id: String) -> Bool { ready.contains(id) || inFlight[id] != nil }

    func useStoreForTesting(_ store: any DictationAssetStore) {
        self.store = store
        ready = []
        inFlight = [:]
    }

    // MARK: - Private

    private func wait(_ id: String, _ task: Task<Bool, Never>, _ job: any DictationAssetJob, _ budget: Double) async -> DictationAssetOutcome {
        switch await Self.result(of: task, within: budget) {
        case true?:
            ready.insert(id)
            return .ready
        case false?:
            return .failed("installation failed")
        case nil:
            return .installing(job.fractionCompleted)
        }
    }

    private func finish(_ id: String, ok: Bool, seconds: Double) {
        inFlight[id] = nil
        guard ok else { return }
        ready.insert(id)
        Logger.info(String(format: "System dictation: installed \(id) in %.1fs", seconds), subsystem: .model)
    }

    /// Asks Apple for `locale`; when every reservation slot is taken, releases one this process
    /// does not use and asks once more.
    private func requestMakingRoom(_ locale: Locale, id: String) async throws -> (any DictationAssetJob)? {
        do {
            return try await store.job(for: locale)
        } catch where Self.isTooManyLocales(error) {
            let reserved = await store.reservedLocaleIDs()
            guard let spare = reserved.first(where: { $0 != id && !isInUse($0) }) else { throw error }
            Logger.warning("System dictation: all \(store.maximumReserved) language slots taken (\(reserved.joined(separator: ", "))) — releasing \(spare) for \(id)", subsystem: .model)
            await store.release(spare)
            return try await requestMakingRoom(locale, id: id)
        }
    }

    nonisolated static func isTooManyLocales(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == "SFSpeechErrorDomain" && e.code == 11
    }

    /// The task's result if it finishes within `seconds`, else nil. The task keeps running.
    ///
    /// Not a task group: a group waits for every child before returning, and a child awaiting
    /// `task.value` ignores cancellation, so the "budget" waited out the whole download.
    nonisolated static func result(of task: Task<Bool, Never>, within seconds: Double) async -> Bool? {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task { once.resume(await task.value) }
            Task {
                try? await Task.sleep(for: .seconds(max(seconds, 0)))
                once.resume(nil)
            }
        }
    }
}

/// Resumes a continuation with whichever value arrives first.
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool?, Never>?
    init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }
    func resume(_ value: Bool?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

// MARK: - Apple

nonisolated struct AppleDictationAssetStore: DictationAssetStore {
    func job(for locale: Locale) async throws -> (any DictationAssetJob)? {
        let module = DictationTranscriber(locale: locale, preset: SystemLivePreviewBridge.preset)
        return try await AssetInventory.assetInstallationRequest(supporting: [module]).map(AppleDictationAssetJob.init)
    }

    func reservedLocaleIDs() async -> [String] {
        await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }
    }

    var maximumReserved: Int { AssetInventory.maximumReservedLocales }

    func release(_ localeID: String) async {
        guard let locale = await AssetInventory.reservedLocales.first(where: { $0.identifier(.bcp47) == localeID }) else { return }
        await AssetInventory.release(reservedLocale: locale)
    }
}

nonisolated final class AppleDictationAssetJob: DictationAssetJob, @unchecked Sendable {
    private let request: AssetInstallationRequest
    init(_ request: AssetInstallationRequest) { self.request = request }
    var fractionCompleted: Double { request.progress.fractionCompleted }
    func run() async throws { try await request.downloadAndInstall() }
}
