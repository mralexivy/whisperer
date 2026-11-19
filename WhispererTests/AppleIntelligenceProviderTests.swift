//
//  AppleIntelligenceProviderTests.swift
//  WhispererTests
//
//  The on-device Apple Intelligence provider: how it routes (no consent, not stopped by "keep all
//  meeting AI on this Mac"), how it windows a long transcript for a small context window, how it
//  merges per-window digests, and — when the Mac has the model — real requests in English,
//  Hebrew and Russian. The live half skips itself where Apple Intelligence is off.
//

import FoundationModels
import XCTest
@testable import whisperer

// MARK: - Routing and card

@MainActor
final class AppleIntelligenceRoutingTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    private func makeStore() -> ConnectedAIStore {
        let defaults = UserDefaults(suiteName: "AppleIntelligenceRoutingTests-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults,
                                     keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        Self.keepAlive.append(store)
        return store
    }

    func testOnlyOnDeviceProvidersStayOnTheMac() {
        XCTAssertFalse(AIProviderID.appleIntelligence.leavesTheMac)
        for id in AIProviderID.allCases where id != .appleIntelligence {
            XCTAssertTrue(id.leavesTheMac, "\(id) sends text elsewhere")
        }
    }

    func testNeedsNoConsent() {
        let store = makeStore()
        XCTAssertTrue(store.hasConsent(.appleIntelligence))
        store.selectedProvider = .appleIntelligence
        XCTAssertEqual(store.activeProviderID, .appleIntelligence)
    }

    func testKeepLocalDoesNotStopIt() {
        let store = makeStore()
        store.selectedProvider = .appleIntelligence
        store.keepLocalOnly = true
        XCTAssertEqual(store.activeProviderID, .appleIntelligence,
                       "nothing leaves the Mac, so the privacy switch has nothing to stop")
        store.grantConsent(.geminiKey)
        store.selectedProvider = .geminiKey
        XCTAssertNil(store.activeProviderID, "a cloud provider is still stopped")
    }

    func testNoMarketOrEditionHidesIt_MacOSDecidesAvailability() {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        defer { MarketPolicy.testOverride = nil }
        #endif
        XCTAssertTrue(AIProviderID.appleIntelligence.isAvailableInThisBuild,
                      "a model built into macOS is not a third-party AI; `readiness` reports whether this Mac has it")
    }

    func testListedUnderThisMacNotAmongSubscriptions() {
        let controller = ConnectedAIPageController(store: makeStore())
        XCTAssertFalse(controller.subscriptionProviders.contains(.appleIntelligence))
        XCTAssertFalse(controller.apiKeyProviders.contains(.appleIntelligence))
        if AIProviderID.appleIntelligence.isAvailableInThisBuild {
            XCTAssertEqual(controller.onDeviceProviders, [.appleIntelligence])
        }
    }

    func testCardOffersNoPermissionToRevoke() {
        let card = ProviderCardModel.make(
            id: .appleIntelligence, readiness: .ready(detail: nil), isChecking: false,
            isSelected: true, hasConsent: true, keepLocalOnly: true, installURL: nil, signInCommand: nil)
        XCTAssertTrue(card.isInUse, "keep-local does not switch an on-device model off")
        XCTAssertEqual(card.primary, .stopUsing)
        XCTAssertFalse(card.secondary.contains(.revokePermission))
    }

    func testUnavailableCardHasNoSignInOrKeyStep() {
        let card = ProviderCardModel.make(
            id: .appleIntelligence, readiness: .unavailable("Turn on Apple Intelligence in System Settings"),
            isChecking: false, isSelected: false, hasConsent: true, keepLocalOnly: false,
            installURL: nil, signInCommand: nil)
        XCTAssertEqual(card.tone, .error)
        XCTAssertEqual(card.primary, .test)
    }

    func testUnavailabilityReadsAsAnInstructionNotACode() {
        let eligible = AppleIntelligenceProvider.readiness(for: .unavailable(.appleIntelligenceNotEnabled))
        XCTAssertEqual(eligible.statusText, "Turn on Apple Intelligence in System Settings")
        XCTAssertFalse(eligible.isReady)
        XCTAssertTrue(AppleIntelligenceProvider.readiness(for: .available).isReady)
    }
}

// MARK: - Windowing and merging

final class AppleIntelligenceWindowingTests: XCTestCase {

    func testWindowBudgetFollowsTheContextSize() {
        XCTAssertEqual(AppleIntelligenceProvider.windowChars(contextSize: 8192), (8192 - 2_400) * 2)
        XCTAssertEqual(AppleIntelligenceProvider.windowChars(contextSize: 4096), (4096 - 2_400) * 2)
        XCTAssertEqual(AppleIntelligenceProvider.windowChars(contextSize: 2_000), 2_000, "never below a usable floor")
    }

    func testWindowsBreakOnLineBoundaries() {
        let lines = (0..<40).map { "[\($0 * 5)s] Dana: line number \($0) with some words" }
        let windows = AppleIntelligenceProvider.windows(of: lines.joined(separator: "\n"), maxChars: 300)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.count <= 300 })
        XCTAssertEqual(windows.joined(separator: "\n"), lines.joined(separator: "\n"), "nothing lost or reordered")
        XCTAssertTrue(windows.allSatisfy { $0.hasPrefix("[") }, "a marker is never separated from its text")
    }

    func testShortTranscriptIsOneWindow() {
        XCTAssertEqual(AppleIntelligenceProvider.windows(of: "[0s] A: hi\n[3s] B: hello", maxChars: 1_000).count, 1)
        XCTAssertTrue(AppleIntelligenceProvider.windows(of: "", maxChars: 1_000).isEmpty)
    }

    func testOneEnormousLineIsStillCut() {
        let line = "[0s] A: " + String(repeating: "word ", count: 1_000)
        let windows = AppleIntelligenceProvider.windows(of: line, maxChars: 500)
        XCTAssertTrue(windows.allSatisfy { $0.count <= 500 })
        XCTAssertEqual(windows.joined(), line)
    }

    func testHebrewAndRussianWindowsStayWithinBudget() {
        let he = String(repeating: "אנחנו צריכים לשלוח את הגרסה ביום חמישי. ", count: 200)
        let ru = String(repeating: "мы должны отправить сборку в четверг. ", count: 200)
        for text in [he, ru] {
            let transcript = (0..<30).map { "[\($0)s] A: \(text.prefix(400))" }.joined(separator: "\n")
            let windows = AppleIntelligenceProvider.windows(of: transcript, maxChars: 11_600)
            XCTAssertTrue(windows.allSatisfy { $0.count <= 11_600 })
        }
    }

    func testMergeDropsRepeatsKeepsOrderAndNeverInventsOwners() throws {
        let a = AINotesDigest(
            title: "Launch plan", summary: "First half.",
            topics: [.init(text: "Pricing", seconds: 10), .init(text: "Timeline", seconds: 60)],
            decisions: [.init(label: "Ship", text: "Ship Thursday", seconds: 70)],
            openQuestions: [.init(text: "Who owns QA?", seconds: 80)],
            nextMeeting: nil,
            actionItems: [.init(task: "Send the build", owner: "Dana", due: "Thursday")])
        let b = AINotesDigest(
            title: "Launch plan", summary: "Second half.",
            topics: [.init(text: "pricing", seconds: 900), .init(text: "Support", seconds: 950)],
            decisions: [],
            openQuestions: [],
            nextMeeting: "Monday 10:00",
            actionItems: [.init(task: "Update the site", owner: "Unknown", due: nil)])
        let merged = AppleIntelligenceProvider.merge([a, b], title: "Launch plan", overview: "Whole story.")
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(object: merged))

        XCTAssertEqual(notes.title, "Launch plan")
        XCTAssertEqual(notes.summary.overview, "Whole story.")
        XCTAssertEqual(notes.summary.keyTopics.map(\.text), ["Pricing", "Timeline", "Support"], "repeat dropped, first kept")
        XCTAssertEqual(notes.summary.decisions.map(\.text), ["Ship Thursday"])
        XCTAssertEqual(notes.summary.nextMeeting, "Monday 10:00")
        XCTAssertEqual(notes.summary.actionItems.map(\.ownerName), ["Dana", ""], "'Unknown' is not a person")
    }

    func testMergeCapsALongMeetingsLists() throws {
        let many = (0..<100).map { AIStampedNote(text: "Topic \($0)", seconds: $0) }
        let digest = AINotesDigest(title: "T", summary: "S", topics: many, decisions: [], openQuestions: [],
                                   nextMeeting: nil, actionItems: [])
        let merged = AppleIntelligenceProvider.merge([digest], title: "T", overview: "S")
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(object: merged))
        XCTAssertEqual(notes.summary.keyTopics.count, 14)
    }

    func testErrorsMapToTheRoutersVocabulary() {
        XCTAssertEqual(AppleIntelligenceProvider.map(MeetingAIProviderError.timeout) as? MeetingAIProviderError, .timeout)
        XCTAssertTrue(AppleIntelligenceProvider.map(CancellationError()) is CancellationError)
        XCTAssertTrue(AppleIntelligenceProvider.map(URLError(.badURL)) is MeetingAIProviderError)
    }
}

// MARK: - Polish uses the line format

/// A small-context provider: asks for `id | text` lines and answers in them.
private final class LineProvider: MeetingIntelligenceProvider, @unchecked Sendable {
    let id: AIProviderID = .appleIntelligence
    var polishesInLines: Bool { true }
    private let lock = NSLock()
    private var _schemas: [String?] = []
    var schemas: [String?] { lock.lock(); defer { lock.unlock() }; return _schemas }

    func readiness() async -> ProviderReadiness { .ready(detail: nil) }
    func generateNotes(_ input: MeetingNotesInput, onTitle: @escaping @Sendable (String) -> Void) async throws -> MeetingNotes { throw MeetingAIProviderError.cancelled }
    func ask(_ input: MeetingAskInput, onPartial: @escaping @Sendable (String) -> Void) async throws -> String { "" }

    func complete(instructions: String, input: String, jsonSchema: String?) async throws -> String {
        lock.lock(); _schemas.append(jsonSchema); lock.unlock()
        // "0 | um we picked postgres" → "0 | We picked Postgres."
        return input.split(separator: "\n").map { line in
            let id = line.split(separator: "|").first!.trimmingCharacters(in: .whitespaces)
            return "\(id) | We picked Postgres."
        }.joined(separator: "\n")
    }
}

final class AppleIntelligencePolishRoutingTests: XCTestCase {
    func testASmallModelPolishesInLinesWithoutAJSONSchema() async throws {
        let provider = LineProvider()
        let segments = [MeetingSegment(timestamp: 0, endTimestamp: 4, text: "um we we picked postgres")]
        let outcome = try await MeetingTranscriptPolisher.polish(
            segments, with: provider, languageName: "English", onProgress: { _, _ in })
        XCTAssertEqual(outcome.segments.first?.text, "We picked Postgres.")
        XCTAssertEqual(outcome.segments.first?.rawText, "um we we picked postgres", "the original stays recoverable")
        XCTAssertEqual(provider.schemas.count, 1)
        XCTAssertNil(provider.schemas[0] ?? nil, "no JSON schema is sent to a model that polishes in lines")
    }

    func testThisProviderAsksForLineFormatAndKeepsAskWindowSmall() {
        let p = AppleIntelligenceProvider()
        XCTAssertTrue(p.polishesInLines)
        XCTAssertLessThan(p.maxTranscriptChars, 20_000, "Ask AI must fit the model's window")
        XCTAssertGreaterThan(p.maxNotesChars, 100_000, "notes cover a whole meeting by windowing")
    }
}

// MARK: - Dictation rewrite modes

@MainActor
final class AppleIntelligenceDictationTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testPickerOffersItExactlyWhenMacOSHasIt() {
        XCTAssertEqual(LLMModelVariant.available.contains(.appleIntelligence), SystemLanguageModel.default.isAvailable)
        XCTAssertEqual(LLMModelVariant.appleIntelligence.isAvailableInThisMarket, SystemLanguageModel.default.isAvailable)
        XCTAssertTrue(LLMPostProcessor.isOnDisk(.appleIntelligence), "nothing to download")
    }

    func testItIsNeverTheDefault() {
        XCTAssertNotEqual(LLMModelVariant.marketDefault, .appleIntelligence)
    }

    private func loaded() async throws -> LLMPostProcessor {
        try XCTSkipUnless(SystemLanguageModel.default.isAvailable, "Apple Intelligence is not available on this Mac")
        let processor = LLMPostProcessor()
        Self.keepAlive.append(processor)
        try await processor.loadModel(.appleIntelligence)
        return processor
    }

    func testLoadingNeedsNoWeights() async throws {
        let p = try await loaded()
        XCTAssertTrue(p.isModelLoaded)
        XCTAssertEqual(p.loadedVariant, .appleIntelligence)
        XCTAssertNil(p.modelContainer)
        XCTAssertEqual(p.loadPhase, .ready)
    }

    func testRewriteModesRunInEnglishHebrewAndRussian() async throws {
        let p = try await loaded()
        let system = "Rewrite the text in [INPUT] with correct punctuation and capitalization and without filler words. Keep the same language. Reply with the rewritten text only."
        let cases = [
            "um so i think we should uh ship the build on thursday",
            "אז אני חושבת שאנחנו צריכים כאילו לשלוח את הגרסה ביום חמישי",
            "ну я думаю что мы должны это самое отправить сборку в четверг",
        ]
        for text in cases {
            let out = try await p.process(text: text, systemPrompt: system, userMessage: "[INPUT]\n\(text)\n[/INPUT]",
                                          maxTokensCap: 256, throwOnFallback: true)
            XCTAssertFalse(out.isEmpty)
            XCTAssertNotEqual(out, text, "the text was rewritten")
            let scripts: (Unicode.Scalar) -> Bool = { (0x0590...0x05FF).contains($0.value) || (0x0400...0x04FF).contains($0.value) }
            if text.unicodeScalars.contains(where: scripts) {
                XCTAssertTrue(out.unicodeScalars.contains(where: scripts), "stays in its language, not translated: \(out)")
            }
        }
    }

    func testBatchKeepsOrderAndReturnsOneResultPerRow() async throws {
        let p = try await loaded()
        let rows = ["um hello there", "uh good morning everyone"].map {
            LLMBatchRequest(text: $0, userMessage: "[INPUT]\n\($0)\n[/INPUT]", maxTokens: 64, outputCharLimit: nil)
        }
        let out = await p.processBatch(
            requests: rows,
            instructions: "Fix punctuation and remove filler words in [INPUT]. Reply with the text only.")
        XCTAssertEqual(out.count, 2)
        XCTAssertTrue(out[0].localizedCaseInsensitiveContains("hello"))
        XCTAssertTrue(out[1].localizedCaseInsensitiveContains("morning"))
    }

    func testUnavailableModelReturnsTheOriginalTextWhenNotAskedToThrow() async throws {
        let p = LLMPostProcessor()
        Self.keepAlive.append(p)
        let text = "leave me alone"
        let out = try await p.process(text: text, systemPrompt: "x", userMessage: text)
        XCTAssertEqual(out, text, "nothing loaded: the text is returned unchanged")
    }
}

// MARK: - Live (this Mac's model)

final class AppleIntelligenceLiveTests: XCTestCase {

    private func provider() throws -> AppleIntelligenceProvider {
        let p = AppleIntelligenceProvider()
        guard case .available = p.model.availability else {
            throw XCTSkip("Apple Intelligence is not available on this Mac")
        }
        return p
    }

    func testPolishLineFormatInThreeLanguages() async throws {
        let p = try provider()
        let cases = [
            "0 | um so i think we should uh ship the the build on thursday",
            "0 | אז אני חושבת שאנחנו צריכים כאילו לשלוח את הגרסה ביום חמישי",
            "0 | ну я думаю что мы должны это самое отправить сборку в четверг",
        ]
        for input in cases {
            let reply = try await p.complete(
                instructions: MeetingTranscriptPolisher.localInstructions(languageName: nil),
                input: input, jsonSchema: nil)
            let parsed = MeetingTranscriptPolisher.parseLines(reply, speakers: [:])
            let out = try XCTUnwrap(parsed[0], "no `0 | text` line in: \(reply)")
            XCTAssertFalse(out.isEmpty)
            XCTAssertTrue(MeetingTranscriptPolisher.accept(original: String(input.dropFirst(4)), polished: out),
                          "the polisher's own guard rejects: \(out)")
        }
    }

    func testNotesFromAShortTranscript() async throws {
        let p = try provider()
        let transcript = """
        [0s] Dana: Okay, so the launch. I think we ship Thursday.
        [9s] Omar: Agreed. I'll send the build to QA tomorrow morning.
        [17s] Dana: Good. Who is writing the release notes?
        [22s] Omar: Not decided yet. Let's meet again Monday at ten.
        """
        let titled = OnceFlag()
        let notes = try await p.generateNotes(
            MeetingNotesInput(transcript: transcript, languageName: "English", wordCount: 45, isShortNote: false)
        ) { _ in _ = titled.take() }
        XCTAssertFalse(notes.summary.overview.isEmpty)
        XCTAssertNotNil(notes.title)
        XCTAssertFalse(titled.take(), "the title callback fires")
        Logger.info("AFM notes: \(notes.title ?? "-") | \(notes.summary.overview) | decisions=\(notes.summary.decisions.map(\.text)) actions=\(notes.summary.actionItems.map { "\($0.ownerName): \($0.text)" }) next=\(notes.summary.nextMeeting ?? "-")", subsystem: .transcription)
        XCTAssertTrue(notes.summary.overview.localizedCaseInsensitiveContains("thursday"),
                      "the overview keeps the specifics: \(notes.summary.overview)")
    }

    func testNotesAcrossSeveralWindowsInHebrew() async throws {
        var p = try provider()
        p.windowCharsOverride = 130          // forces map → reduce on a short transcript
        let lines = [
            "[0s] דנה: אז נתחיל מהתמחור. אני חושבת שהמחיר צריך להישאר חמש עשרה דולר.",
            "[12s] עומר: מסכים. אבל צריך להסביר ללקוחות למה זה כולל הכול.",
            "[25s] דנה: בסדר. עכשיו לוח הזמנים, אנחנו שולחים את הגרסה ביום חמישי.",
            "[38s] עומר: אני אשלח את הגרסה ל-QA מחר בבוקר.",
            "[50s] דנה: מי כותב את הערות השחרור?",
            "[58s] עומר: עוד לא החלטנו. ניפגש שוב ביום שני בעשר.",
        ]
        XCTAssertGreaterThanOrEqual(
            AppleIntelligenceProvider.windows(of: lines.joined(separator: "\n"), maxChars: 130).count, 3,
            "the transcript must really span several windows")
        let notes = try await p.generateNotes(
            MeetingNotesInput(transcript: lines.joined(separator: "\n"), languageName: "Hebrew",
                              wordCount: 70, isShortNote: false)) { _ in }
        Logger.info("AFM he notes: \(notes.title ?? "-") | \(notes.summary.overview) | topics=\(notes.summary.keyTopics.map(\.text)) actions=\(notes.summary.actionItems.map { "\($0.ownerName): \($0.text)" })", subsystem: .transcription)
        XCTAssertGreaterThan(notes.summary.overview.count, 40)
        XCTAssertTrue(notes.summary.overview.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) },
                      "the overview is written in Hebrew: \(notes.summary.overview)")
    }

    func testSummariesThatOutgrowAWindowAreFoldedFirst() async throws {
        var p = try provider()
        p.windowCharsOverride = 130
        p.reduceCharsOverride = 400          // four summaries do not fit: the fold step runs
        let transcript = [
            "[0s] Lena: The ad spend is 40k a month and I want to cut it to 25k.",
            "[12s] Ravi: The autumn campaign is already booked, so cutting now costs us the deposit.",
            "[25s] Lena: Then we cut from January. Ravi, please confirm the contract end date.",
            "[38s] Ravi: I'll email the agency tomorrow and report back on Friday.",
        ].joined(separator: "\n")
        let notes = try await p.generateNotes(
            MeetingNotesInput(transcript: transcript, languageName: "English", wordCount: 60, isShortNote: false)) { _ in }
        Logger.info("AFM folded notes: \(notes.title ?? "-") | \(notes.summary.overview)", subsystem: .transcription)
        XCTAssertFalse(notes.summary.overview.isEmpty)
    }

    func testAskStreamsAnAnswer() async throws {
        let p = try provider()
        let partials = LockedBox<[String]>([])
        let answer = try await p.ask(MeetingAskInput(
            question: "When do we ship?",
            transcript: "[0s] Dana: We ship on Thursday.\n[6s] Omar: Great, Thursday it is.")) { text in partials.mutate { $0.append(text) } }
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("thursday"), answer)
        XCTAssertFalse(partials.value.isEmpty)
    }
}

/// Collects values from `@Sendable` callbacks.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
