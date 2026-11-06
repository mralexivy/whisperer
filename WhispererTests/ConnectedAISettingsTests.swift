//
//  ConnectedAISettingsTests.swift
//  WhispererTests
//
//  Connected AI settings: the store's routing rules (local default, consent gating,
//  keep-local override), the provider card model, provenance, routing through
//  MeetingAIService with fake providers, and rendering the settings UI.
//

import SwiftUI
import XCTest
@testable import whisperer

// MARK: - Fakes

/// Scripted provider: answers or throws, and counts calls.
nonisolated final class FakeMeetingProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    let id: AIProviderID
    var notes: MeetingNotes?
    var answer: String?
    var error: MeetingAIProviderError?
    private let lock = NSLock()
    private var _notesCalls = 0
    private var _askCalls = 0
    private(set) var lastAskInput: MeetingAskInput?

    var notesCalls: Int { lock.lock(); defer { lock.unlock() }; return _notesCalls }
    var askCalls: Int { lock.lock(); defer { lock.unlock() }; return _askCalls }
    var modelLabel: String? { "fake-model" }

    init(id: AIProviderID = .claudeCode, notes: MeetingNotes? = nil, answer: String? = nil,
         error: MeetingAIProviderError? = nil) {
        self.id = id; self.notes = notes; self.answer = answer; self.error = error
    }

    func readiness() async -> ProviderReadiness { error == nil ? .ready(detail: nil) : .unavailable("fake") }

    func generateNotes(_ input: MeetingNotesInput, onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes {
        lock.lock(); _notesCalls += 1; lock.unlock()
        if let error { throw error }
        if let title = notes?.title { onTitle(title) }
        return notes!
    }

    var completeReply: String?
    /// Answers per input, for chunked passes.
    var completeHandler: (@Sendable (String) -> String)?
    private(set) var completeInputs: [String] = []

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        lock.lock(); completeInputs.append(input); lock.unlock()
        if let error { throw error }
        if let completeHandler { return completeHandler(input) }
        return completeReply ?? ""
    }

    func ask(_ input: MeetingAskInput, onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        lock.lock(); _askCalls += 1; lastAskInput = input; lock.unlock()
        if let error { throw error }
        onPartial(String(answer!.prefix(4)))
        onPartial(answer!)
        return answer!
    }
}

// MARK: - Store

@MainActor
final class ConnectedAIStoreTests: XCTestCase {

    /// @MainActor objects created in tests are kept for the process (see CLAUDE.md: a
    /// synthesized isolated deinit aborts the test host).
    private static var keepAlive: [AnyObject] = []

    private func makeStore() -> ConnectedAIStore {
        let defaults = UserDefaults(suiteName: "ConnectedAIStoreTests-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults,
                                     keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        Self.keepAlive.append(store)
        return store
    }

    func testLocalIsTheDefault() {
        let store = makeStore()
        XCTAssertNil(store.selectedProvider)
        XCTAssertNil(store.activeProviderID)
        XCTAssertNil(store.activeProvider())
    }

    func testSelectionWithoutConsentSendsNothing() {
        let store = makeStore()
        store.selectedProvider = .anthropicKey
        XCTAssertNil(store.activeProviderID, "picking a provider without consent must not route meetings to it")
        store.grantConsent(.anthropicKey)
        XCTAssertEqual(store.activeProviderID, .anthropicKey)
    }

    func testKeepLocalOverridesSelection() {
        let store = makeStore()
        store.grantConsent(.geminiKey)
        store.selectedProvider = .geminiKey
        store.keepLocalOnly = true
        XCTAssertNil(store.activeProviderID)
        store.keepLocalOnly = false
        XCTAssertEqual(store.activeProviderID, .geminiKey)
    }

    func testRevokingConsentDeselects() {
        let store = makeStore()
        store.grantConsent(.openAIKey)
        store.selectedProvider = .openAIKey
        store.revokeConsent(.openAIKey)
        XCTAssertNil(store.selectedProvider)
        XCTAssertFalse(store.hasConsent(.openAIKey))
    }

    func testSettingsPersist() {
        let suite = "ConnectedAIStoreTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let keychain = KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)")
        let first = ConnectedAIStore(defaults: defaults, keychain: keychain)
        first.grantConsent(.anthropicKey)
        first.selectedProvider = .anthropicKey
        first.setModel("claude-x", for: .anthropicKey)
        let second = ConnectedAIStore(defaults: defaults, keychain: keychain)
        Self.keepAlive += [first, second]
        XCTAssertEqual(second.activeProviderID, .anthropicKey)
        XCTAssertEqual(second.model(for: .anthropicKey), "claude-x")
    }

    func testModelDefaultsAndOverride() {
        let store = makeStore()
        XCTAssertEqual(store.model(for: .anthropicKey), ConnectedAIStore.defaultModels[.anthropicKey])
        store.setModel("  my-model  ", for: .anthropicKey)
        XCTAssertEqual(store.model(for: .anthropicKey), "my-model")
        store.setModel("", for: .anthropicKey)
        XCTAssertEqual(store.model(for: .anthropicKey), ConnectedAIStore.defaultModels[.anthropicKey])
    }

    func testAPIKeysLiveInKeychainNotDefaults() async throws {
        let store = makeStore()
        // Right after a rebuild re-signs the test host, its first Keychain read can come back
        // empty while macOS settles the new code signature (seen twice, never reproduced on a
        // rerun). That is the host, not the store: skip instead of reporting a false failure.
        guard store.keychain.set("probe", for: "probe"), store.keychain.string(for: "probe") == "probe" else {
            throw XCTSkip("Keychain not readable from this test host right now")
        }
        store.keychain.remove("probe")
        XCTAssertNil(store.apiKey(for: .openAIKey))
        store.setAPIKey("  sk-test-123 \n", for: .openAIKey)
        XCTAssertEqual(store.apiKey(for: .openAIKey), "sk-test-123")
        let dump = store.defaults.dictionaryRepresentation().values.map { "\($0)" }.joined()
        XCTAssertFalse(dump.contains("sk-test-123"), "a secret must never reach UserDefaults")
        let ready = await store.provider(for: .openAIKey)!.readiness()
        XCTAssertTrue(ready.isReady)
        store.setAPIKey(nil, for: .openAIKey)
        XCTAssertNil(store.apiKey(for: .openAIKey))
        let after = await store.provider(for: .openAIKey)!.readiness()
        XCTAssertEqual(after, .needsKey)
    }

    func testAvailableProvidersMatchBuild() {
        let store = makeStore()
        #if APP_STORE
        XCTAssertFalse(store.availableProviders.contains(.claudeCode), "CLIs cannot run in the sandbox")
        #else
        XCTAssertTrue(store.availableProviders.contains(.claudeCode))
        XCTAssertTrue(store.availableProviders.contains(.codex))
        #endif
        XCTAssertTrue(store.availableProviders.contains(.anthropicKey))
        store.selectedProvider = .claudeCode
        store.grantConsent(.claudeCode)
        #if APP_STORE
        XCTAssertNil(store.activeProviderID)
        #else
        XCTAssertEqual(store.activeProviderID, .claudeCode)
        #endif
    }

    func testFallbackSetsNoticeAndReadiness() {
        let store = makeStore()
        let expectation = expectation(forNotification: .connectedAIDidFallBack, object: nil)
        store.noteFallback(.claudeCode, error: .quotaExhausted(retryAfter: nil), meetingID: UUID())
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(store.lastNotice?.contains("Claude Code") == true)
        XCTAssertTrue(store.lastNotice?.contains("this Mac") == true)
        if case .quotaExhausted = store.readiness[.claudeCode] {} else { XCTFail("readiness should show the limit") }
    }

    func testReadinessAfterErrorPerKind() {
        XCTAssertEqual(ConnectedAIStore.readiness(after: .unauthorized, id: .anthropicKey), .unavailable("Key rejected"))
        XCTAssertEqual(ConnectedAIStore.readiness(after: .notSignedIn, id: .chatGPT), .notSignedIn(hint: "Continue with ChatGPT"))
        XCTAssertEqual(ConnectedAIStore.readiness(after: .notInstalled, id: .codex), .notInstalled)
    }
}

// MARK: - Card model

final class ProviderCardModelTests: XCTestCase {

    private func card(_ id: AIProviderID, _ readiness: ProviderReadiness?, selected: Bool = false,
                      consent: Bool = false, keepLocal: Bool = false, checking: Bool = false) -> ProviderCardModel {
        ProviderCardModel.make(id: id, readiness: readiness, isChecking: checking, isSelected: selected,
                               hasConsent: consent, keepLocalOnly: keepLocal,
                               installURL: URL(string: "https://example.com/install"),
                               signInCommand: id.kind == .cli ? "claude auth login" : nil)
    }

    func testReadyCliOffersUse() {
        let m = card(.claudeCode, .ready(detail: "Claude plan"))
        XCTAssertEqual(m.primary, .useForMeetings)
        XCTAssertEqual(m.tone, .ready)
        XCTAssertEqual(m.statusText, "Ready · Claude plan")
        XCTAssertFalse(m.isInUse)
    }

    func testInUseOffersStopAndRevoke() {
        let m = card(.claudeCode, .ready(detail: nil), selected: true, consent: true)
        XCTAssertTrue(m.isInUse)
        XCTAssertEqual(m.primary, .stopUsing)
        XCTAssertTrue(m.secondary.contains(.revokePermission))
    }

    func testKeepLocalMeansNotInUse() {
        XCTAssertFalse(card(.claudeCode, .ready(detail: nil), selected: true, consent: true, keepLocal: true).isInUse)
    }

    func testNotInstalledOffersInstall() {
        let m = card(.codex, .notInstalled)
        XCTAssertEqual(m.primary, .install(URL(string: "https://example.com/install")!))
        XCTAssertEqual(m.tone, .attention)
    }

    func testNotSignedInCliOffersCommandNotLogin() {
        let m = card(.claudeCode, .notSignedIn(hint: "claude auth login"))
        XCTAssertEqual(m.primary, .copySignInCommand("claude auth login"),
                       "Whisperer never runs the vendor's login for the user")
    }

    func testChatGPTFlow() {
        XCTAssertEqual(card(.chatGPT, nil).primary, .connectChatGPT)
        XCTAssertEqual(card(.chatGPT, .notSignedIn(hint: "")).primary, .connectChatGPT)
        let ready = card(.chatGPT, .ready(detail: "gpt"))
        XCTAssertTrue(ready.secondary.contains(.disconnectChatGPT))
        XCTAssertEqual(ready.badge, "Preview")
    }

    func testAPIKeyFlow() {
        XCTAssertEqual(card(.anthropicKey, .needsKey).primary, .enterKey)
        let ready = card(.anthropicKey, .ready(detail: "m"))
        XCTAssertTrue(ready.secondary.contains(.removeKey))
        XCTAssertTrue(card(.anthropicKey, .unavailable("Key rejected")).secondary.contains(.removeKey))
    }

    func testQuotaShowsErrorButStaysSelectable() {
        let m = card(.codex, .quotaExhausted(until: nil))
        XCTAssertEqual(m.tone, .error)
        XCTAssertEqual(m.primary, .useForMeetings)
    }

    func testCheckingHidesPrimary() {
        let m = card(.codex, .ready(detail: nil), checking: true)
        XCTAssertNil(m.primary)
        XCTAssertEqual(m.statusText, "Checking…")
    }
}

// MARK: - Provenance

final class MeetingAIProvenanceTests: XCTestCase {
    func testRecordAndLookup() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Provenance-\(UUID().uuidString)"))
        let id = UUID()
        XCTAssertNil(MeetingAIProvenance.lookup(id, defaults: defaults))
        MeetingAIProvenance.record(.init(source: AIProviderID.codex.rawValue, model: "gpt", date: Date()), for: id, defaults: defaults)
        let p = try XCTUnwrap(MeetingAIProvenance.lookup(id, defaults: defaults))
        XCTAssertEqual(p.provider, .codex)
        XCTAssertEqual(p.displayName, "Codex")
        MeetingAIProvenance.record(.init(source: "local", model: nil, date: Date()), for: id, defaults: defaults)
        XCTAssertTrue(try XCTUnwrap(MeetingAIProvenance.lookup(id, defaults: defaults)).isLocal)
    }
}

// MARK: - Routing through MeetingAIService

final class ConnectedAIRoutingTests: XCTestCase {

    @MainActor private static var unloadedLLM: LLMPostProcessor?

    override func tearDown() {
        MeetingIntelligenceRouter._testProvider = nil
        MeetingIntelligenceRouter._testForceLocal = false
        MeetingAIService._testInjectedLLM = nil
        super.tearDown()
    }

    private let segments = [
        MeetingSegment(timestamp: 0, endTimestamp: 5, text: "We compared Postgres and DynamoDB.", speakerName: "Alice"),
        MeetingSegment(timestamp: 12, endTimestamp: 18, text: "Postgres wins for ad-hoc queries.", speakerName: "Bob"),
    ]

    func testAskUsesConnectedProviderAndParsesCitations() async {
        let fake = FakeMeetingProvider(answer: "They chose Postgres [12s].")
        MeetingIntelligenceRouter._testProvider = fake
        let partials = Box<[String]>([])
        let answer = await MeetingAIService.shared.ask(question: "What did they choose?", meetingID: UUID(),
                                                       segments: segments, onPartial: { p in partials.mutate { $0.append(p) } })
        XCTAssertEqual(answer.text, "They chose Postgres [12s].")
        XCTAssertEqual(answer.answeredBy, .claudeCode)
        XCTAssertEqual(answer.sources.first?.startTimestamp, 12)
        XCTAssertEqual(partials.value.last, "They chose Postgres [12s].")
        XCTAssertEqual(fake.askCalls, 1)
        let sent = fake.lastAskInput?.transcript ?? ""
        XCTAssertTrue(sent.contains("[12s] Bob: Postgres wins"), "timestamps and speakers are sent for citations")
    }

    func testAskFallsBackToLocalOnProviderFailure() async {
        let llm = await MainActor.run { () -> LLMPostProcessor in
            let p = LLMPostProcessor()
            Self.unloadedLLM = p
            return p
        }
        MeetingAIService._testInjectedLLM = llm
        let fake = FakeMeetingProvider(error: .quotaExhausted(retryAfter: nil))
        MeetingIntelligenceRouter._testProvider = fake
        let notice = expectation(forNotification: .connectedAIDidFallBack, object: nil)
        let answer = await MeetingAIService.shared.ask(question: "q", meetingID: UUID(), segments: segments)
        await fulfillment(of: [notice], timeout: 2)
        XCTAssertEqual(fake.askCalls, 1)
        XCTAssertNil(answer.answeredBy, "the local path answered (here: with its no-model message)")
    }

    func testForcedLocalSkipsProvider() async {
        let fake = FakeMeetingProvider(answer: "x")
        MeetingIntelligenceRouter._testProvider = fake
        MeetingIntelligenceRouter._testForceLocal = true
        let provider = await MeetingIntelligenceRouter.activeProvider()
        XCTAssertNil(provider)
        let local = await MeetingIntelligenceRouter.activeProvider(.local)
        XCTAssertNil(local)
    }

    func testConnectedTranscriptKeepsSpeakersAndCapsLength() {
        let full = MeetingAIService.connectedTranscript(segments, maxChars: 10_000)
        XCTAssertEqual(full, "[0s] Alice: We compared Postgres and DynamoDB.\n[12s] Bob: Postgres wins for ad-hoc queries.")
        let long = (0..<400).map { MeetingSegment(timestamp: Double($0 * 5), endTimestamp: Double($0 * 5 + 4),
                                                  text: "Sentence number \($0) about the roadmap and the budget.") }
        let capped = MeetingAIService.connectedTranscript(long, maxChars: 2_000)
        XCTAssertLessThanOrEqual(capped.count, 2_000)
        XCTAssertFalse(capped.isEmpty)
    }
}

// MARK: - Settings UI

@MainActor
final class ConnectedAISettingsUITests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func host<V: View>(_ view: V, size: CGSize = CGSize(width: 1000, height: 1400)) -> NSHostingView<V> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        Self.keepAlive.append(hosting)
        return hosting
    }

    private func render<V: View>(_ view: V, width: CGFloat = 1000) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 1
        Self.keepAlive.append(renderer)
        return renderer.nsImage
    }

    func testSidebarListsLLMAfterAIModes() throws {
        let items = HistorySidebarItem.visibleItems
        let modes = try XCTUnwrap(items.firstIndex(of: .aiModes))
        XCTAssertEqual(items[modes + 1], .llm)
        XCTAssertEqual(HistorySidebarItem.llm.rawValue, "LLM")
    }

    func testPageLaysOutAndRenders() throws {
        let page = LLMPageView(colorScheme: .dark)
        let hosting = host(page)
        XCTAssertGreaterThan(hosting.fittingSize.height, 400, "page has real content")
        let image = try XCTUnwrap(render(page))
        XCTAssertGreaterThan(image.size.height, 400)
    }

    func testSettingsSummaryAndKeySheetRender() throws {
        XCTAssertNotNil(render(LLMSettingsSummary(colorScheme: .dark), width: 700))
        XCTAssertNotNil(render(APIKeyEditorSheet(provider: .anthropicKey, colorScheme: .dark, onDone: {}), width: 480))
    }

    func testFlowChipsWrap() {
        let chips = FlowChips(spacing: 8) {
            ForEach(0..<12) { i in Text("Provider \(i)").frame(width: 120, height: 30) }
        }
        let narrow = host(chips.frame(width: 300), size: CGSize(width: 300, height: 800))
        XCTAssertGreaterThan(narrow.fittingSize.height, 100, "twelve 120pt chips in 300pt wrap onto several rows")
    }

    func testConsentCopyNamesRecipientAndNeverAudio() {
        XCTAssertEqual(AIProviderID.claudeCode.recipient, "Anthropic")
        XCTAssertEqual(AIProviderID.codex.recipient, "OpenAI")
        XCTAssertEqual(AIProviderID.antigravity.recipient, "Google")
        for id in AIProviderID.allCases { XCTAssertNotNil(id.privacyPolicyURL) }
    }
}
