//
//  DictationAssetsTests.swift
//  WhispererTests
//
//  Every Apple asset behavior seen in the field, against `DictationAssets`, the only place that
//  decides whether live text can stream a locale. The fake stands in for Apple; the last test runs
//  the full-slots case against real Apple dictation.
//

import XCTest
import Speech
@testable import whisperer

/// Apple's asset state, scripted per locale.
private actor FakeDictationStore: DictationAssetStore {
    enum Behavior { case installed, request(seconds: Double), failing }

    private var behavior: [String: Behavior] = [:]
    private(set) var reserved: [String] = []
    private(set) var released: [String] = []
    private(set) var requests = 0
    private(set) var jobsRun = 0
    let maximumReserved: Int

    init(maximumReserved: Int = 5) { self.maximumReserved = maximumReserved }

    func set(_ id: String, _ b: Behavior) { behavior[id] = b }
    func reserve(_ ids: [String]) { reserved = ids }

    nonisolated func job(for locale: Locale) async throws -> (any DictationAssetJob)? {
        try await job(id: locale.identifier(.bcp47))
    }

    private func job(id: String) throws -> (any DictationAssetJob)? {
        requests += 1
        if !reserved.contains(id) {
            guard reserved.count < maximumReserved else {
                throw NSError(domain: "SFSpeechErrorDomain", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, \(maximumReserved) maximum"])
            }
            reserved.append(id)
        }
        switch behavior[id] ?? .installed {
        case .installed: return nil
        case .request(let seconds): return FakeJob(seconds: seconds, fails: false) { [weak self] in await self?.ranJob() }
        case .failing: return FakeJob(seconds: 0.05, fails: true) { [weak self] in await self?.ranJob() }
        }
    }

    private func ranJob() { jobsRun += 1 }

    nonisolated func reservedLocaleIDs() async -> [String] { await reserved }
    nonisolated func release(_ localeID: String) async { await drop(localeID) }
    private func drop(_ id: String) { reserved.removeAll { $0 == id }; released.append(id) }
}

private final class FakeJob: DictationAssetJob, @unchecked Sendable {
    let seconds: Double, fails: Bool, onRun: @Sendable () async -> Void
    private let started = Date()
    init(seconds: Double, fails: Bool, onRun: @escaping @Sendable () async -> Void) {
        self.seconds = seconds; self.fails = fails; self.onRun = onRun
    }
    var fractionCompleted: Double { min(1, Date().timeIntervalSince(started) / seconds) }
    func run() async throws {
        await onRun()
        try await Task.sleep(for: .seconds(seconds))
        if fails { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "network down"]) }
    }
}

final class DictationAssetsTests: XCTestCase {

    private let he = Locale(identifier: "he-IL"), ru = Locale(identifier: "ru-RU"), en = Locale(identifier: "en-US")

    private func fresh(_ configure: (FakeDictationStore) async -> Void = { _ in }) async -> (DictationAssets, FakeDictationStore) {
        let assets = DictationAssets()
        let store = FakeDictationStore()
        await configure(store)
        await assets.useStoreForTesting(store)
        return (assets, store)
    }

    /// Installed assets: ready, and Apple is asked once, however often the status is read.
    func testInstalledIsReadyAndAskedOnce() async {
        let (assets, store) = await fresh()
        for _ in 0..<6 {
            let outcome = await assets.prepare(he, within: 1.5)
            XCTAssertEqual(outcome, .ready)
        }
        let requests = await store.requests
        XCTAssertEqual(requests, 1)
    }

    /// The second Mac: a request for installed assets on every call, completing in 0.4 s. Must be
    /// ready on the first read and never install again — the loop that kept the banner up.
    func testAllocationOnlyRequestInstallsOnceThenStaysReady() async {
        let (assets, store) = await fresh { await $0.set("he-IL", .request(seconds: 0.4)) }
        let first = await assets.prepare(he, within: 1.5)
        XCTAssertEqual(first, .ready, "a 0.4 s request must not read as 'not installed'")
        for _ in 0..<10 {
            let again = await assets.prepare(he, within: 1.5)
            XCTAssertEqual(again, .ready)
        }
        let jobs = await store.jobsRun, requests = await store.requests
        XCTAssertEqual(jobs, 1, "installed once, never again this run")
        XCTAssertEqual(requests, 1)
    }

    /// A real download: reported as installing, never started twice, ready once it finishes.
    func testRealDownloadRunsOnceAndBecomesReady() async throws {
        let (assets, store) = await fresh { await $0.set("ru-RU", .request(seconds: 1.0)) }
        guard case .installing = await assets.prepare(ru, within: 0.1) else { return XCTFail("expected installing") }
        // Everyone asking meanwhile — Settings, a session start, the launch refresh — shares it.
        async let a = assets.prepare(ru, within: 0.1)
        async let b = assets.prepare(ru, within: 0.1)
        _ = await (a, b)
        let done = await assets.prepare(ru, within: 3)
        XCTAssertEqual(done, .ready)
        let jobs = await store.jobsRun
        XCTAssertEqual(jobs, 1, "concurrent callers must not start a second download")
    }

    /// All 5 slots taken by locales live text no longer uses: one is released and the request
    /// succeeds. Before, every request threw "Too many allocated locales" forever.
    func testFullSlotsReleaseAnUnusedLocale() async {
        let (assets, store) = await fresh { await $0.reserve(["fr-FR", "de-DE", "es-ES", "it-IT", "ja-JP"]) }
        let outcome = await assets.prepare(he, within: 1.5)
        XCTAssertEqual(outcome, .ready)
        let released = await store.released, reserved = await store.reserved
        XCTAssertEqual(released.count, 1)
        XCTAssertTrue(reserved.contains("he-IL"))
    }

    /// A slot in use by live text is never the one released.
    func testFullSlotsNeverReleaseALocaleInUse() async {
        let (assets, store) = await fresh()
        _ = await assets.prepare(en, within: 1.5)          // en in use
        await store.reserve(["en-US", "fr-FR", "de-DE", "es-ES", "it-IT"])
        _ = await assets.prepare(he, within: 1.5)
        let released = await store.released
        XCTAssertFalse(released.contains("en-US"))
    }

    /// Every slot in use: an honest failure, nothing released, no crash.
    func testAllSlotsInUseFailsWithoutReleasing() async {
        let (assets, store) = await fresh()
        for id in ["en-US", "ru-RU", "fr-FR", "de-DE", "es-ES"] { _ = await assets.prepare(Locale(identifier: id), within: 1.5) }
        let outcome = await assets.prepare(he, within: 1.5)
        guard case .failed = outcome else { return XCTFail("expected failed, got \(outcome)") }
        let released = await store.released
        XCTAssertTrue(released.isEmpty)
    }

    /// A failed download is retried on the next read, not stuck failed or stuck installing.
    func testFailedInstallIsRetried() async {
        let (assets, store) = await fresh { await $0.set("he-IL", .failing) }
        let first = await assets.prepare(he, within: 1)
        guard case .failed = first else { return XCTFail("expected failed, got \(first)") }
        await store.set("he-IL", .request(seconds: 0.1))
        let second = await assets.prepare(he, within: 1)
        XCTAssertEqual(second, .ready)
    }

    /// The session-start budget must actually bound the wait: a 25 s download must not freeze a
    /// session for 25 s. (A task-group implementation waited the whole install.)
    func testBudgetBoundsTheWaitForASlowDownload() async {
        let (assets, _) = await fresh { await $0.set("ru-RU", .request(seconds: 5)) }
        let started = Date()
        let outcome = await assets.prepare(ru, within: 0.3)
        let waited = Date().timeIntervalSince(started)
        guard case .installing = outcome else { return XCTFail("expected installing, got \(outcome)") }
        XCTAssertLessThan(waited, 1.0, "waited \(waited)s for a 0.3 s budget")
    }

    /// The UI's explicit install reports progress and ends at 1.
    func testInstallReportsProgressToCompletion() async throws {
        let (assets, _) = await fresh { await $0.set("ru-RU", .request(seconds: 0.8)) }
        final class Box: @unchecked Sendable { var values: [Double] = [] }
        let box = Box()
        try await assets.install(ru) { box.values.append($0) }
        XCTAssertEqual(box.values.last, 1)
        XCTAssertGreaterThan(box.values.count, 2, "progress must be reported while it downloads")
    }
}

// MARK: - Real Apple dictation

/// The full-slots case on this Mac's real Apple dictation. Fills every reservation slot of the test
/// host (which is Whisperer, so these are the app's own reservations) with foreign locales, then
/// asks live text for Hebrew. Restores nothing else: the app re-reserves what it uses on launch.
final class DictationAssetsAppleTests: XCTestCase {

    func testHebrewStreamsWhenEveryReservationSlotWasTaken() async throws {
        await DictationAssets.shared.useStoreForTesting(AppleDictationAssetStore())
        for l in await AssetInventory.reservedLocales { await AssetInventory.release(reservedLocale: l) }
        var fillers: [Locale] = []
        for tag in ["fr", "de", "es", "it", "ja"] {
            guard let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: tag)) else { continue }
            if (try? await AssetInventory.reserve(locale: l)) == true { fillers.append(l) }
        }
        defer { Task { for l in fillers { await AssetInventory.release(reservedLocale: l) } } }
        let full = await AssetInventory.reservedLocales.count
        guard full >= AssetInventory.maximumReservedLocales else { throw XCTSkip("could not fill the slots (\(full))") }

        let status = await SystemLivePreviewBridge.status(for: .hebrew)
        XCTAssertEqual(status, .ready, "a full set of slots must not leave Hebrew unavailable")

        let testData = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("TestData")
        let samples = try loadAudioSamples(from: testData.appendingPathComponent("hebrew_sample.wav"))
        let bridge = SystemLivePreviewBridge(preferredLanguages: [.hebrew])
        await bridge.beginSession(language: .hebrew)
        let streaming = await bridge.isStreaming()
        XCTAssertTrue(streaming, "Apple dictation must stream after a slot was freed")
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            await bridge.feed(samples: Array(samples[start..<min(start + 1_600, samples.count)]))
            try? await Task.sleep(for: .milliseconds(25))
        }
        let text = await bridge.endSession()
        XCTAssertTrue(text.contains("העברית"), "final: \(text)")
    }
}
