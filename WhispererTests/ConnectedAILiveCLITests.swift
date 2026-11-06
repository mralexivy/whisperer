//
//  ConnectedAILiveCLITests.swift
//  WhispererTests
//
//  Opt-in: runs the real Claude Code / Codex / Antigravity adapters against the CLIs the
//  developer is signed in to. Costs a little of their plan's usage, so it is skipped unless
//  enabled:
//
//    TEST_RUNNER_WHISPERER_LIVE_CLI=1 xcodebuild test … -only-testing:WhispererTests/ConnectedAILiveCLITests
//
//  (xcodebuild forwards TEST_RUNNER_-prefixed variables to the test host without the prefix.)
//

#if !APP_STORE

import XCTest
@testable import whisperer

final class ConnectedAILiveCLITests: XCTestCase {

    private let english = MeetingNotesInput(
        transcript: """
        [0s] Alice: Let's decide the database for the events table today.
        [9s] Bob: Postgres handles the ad-hoc analytics queries; DynamoDB would need a second index and a nightly export.
        [24s] Alice: Cost is about the same at 40 GB. Postgres it is. We revisit if it passes 500 GB.
        [37s] Bob: I'll write the migration by Friday.
        [45s] Alice: Open question — who owns the backup policy?
        """,
        languageName: "English", wordCount: 70, isShortNote: false)

    private let hebrew = MeetingNotesInput(
        transcript: """
        [0s] דנה: בואו נחליט היום על תאריך ההשקה.
        [8s] יוסי: אני מציע ראשון בדצמבר, הבדיקות יסתיימו עד אז.
        [17s] דנה: מסכימה. יוסי, תכין את תוכנית ההשקה עד יום חמישי.
        """,
        languageName: "Hebrew", wordCount: 30, isShortNote: false)

    private func enabled() throws {
        guard ProcessInfo.processInfo.environment["WHISPERER_LIVE_CLI"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_WHISPERER_LIVE_CLI=1 to run against the real CLIs")
        }
    }

    private func check(_ provider: any MeetingIntelligenceProvider) async throws {
        let readiness = await provider.readiness()
        guard readiness.isReady else { throw XCTSkip("\(provider.id.displayName): \(readiness.statusText)") }

        for input in [english, hebrew] {
            let titles = Box<[String]>([])
            let started = Date()
            let notes = try await provider.generateNotes(input) { t in titles.mutate { $0.append(t) } }
            let seconds = Date().timeIntervalSince(started)
            print("LIVE \(provider.id.rawValue) [\(input.languageName ?? "")] \(Int(seconds))s title=\(notes.title ?? "nil") decisions=\(notes.summary.decisions.count) actions=\(notes.summary.actionItems.map { "\($0.text)/\($0.ownerName)" })")
            XCTAssertNotNil(notes.title)
            XCTAssertFalse(notes.summary.overview.isEmpty)
            XCTAssertLessThanOrEqual(titles.value.count, 1, "title callback fires at most once")
            if input.languageName == "Hebrew" {
                XCTAssertTrue(notes.summary.overview.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) },
                              "Hebrew meeting gets Hebrew notes")
                XCTAssertTrue(notes.summary.actionItems.contains { $0.ownerName.contains("יוסי") })
            } else {
                XCTAssertTrue(notes.summary.actionItems.contains { $0.ownerName.contains("Bob") })
            }
        }

        let answer = try await provider.ask(
            MeetingAskInput(question: "Which database did they choose and why?", transcript: english.transcript)) { _ in }
        print("LIVE \(provider.id.rawValue) ask: \(answer)")
        XCTAssertTrue(answer.localizedCaseInsensitiveContains("postgres"))
    }

    /// Transcript polish through the real CLI: fillers out, words fixed, ids and language kept.
    private func checkPolish(_ provider: any MeetingIntelligenceProvider) async throws {
        let readiness = await provider.readiness()
        guard readiness.isReady else { throw XCTSkip("\(provider.id.displayName): \(readiness.statusText)") }
        let segments = [
            MeetingSegment(timestamp: 0, endTimestamp: 5, text: "um so we we decided to uh go with post gress for the events table"),
            MeetingSegment(timestamp: 6, endTimestamp: 9, text: "אז אממ בוב יכתוב את המיגרציה עד יום שישי"),
        ]
        let outcome = try await MeetingTranscriptPolisher.polish(segments, with: provider, languageName: nil) { _, _ in }
        print("LIVE polish \(provider.id.rawValue): changed=\(outcome.changed) rejected=\(outcome.rejected) \(outcome.segments.map(\.text))")
        XCTAssertGreaterThanOrEqual(outcome.changed, 1)
        XCTAssertTrue(outcome.segments[0].text.lowercased().contains("postgres"))
        XCTAssertFalse(outcome.segments[0].text.lowercased().contains(" um "))
        XCTAssertTrue(outcome.segments[1].text.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) }, "Hebrew stays Hebrew")
        XCTAssertEqual(outcome.segments.map(\.id), segments.map(\.id))
    }

    func testPolishClaudeCode() async throws { try enabled(); try await checkPolish(ClaudeCodeProvider()) }
    func testPolishCodex() async throws { try enabled(); try await checkPolish(CodexProvider()) }

    func testClaudeCode() async throws { try enabled(); try await check(ClaudeCodeProvider()) }
    func testCodex() async throws { try enabled(); try await check(CodexProvider()) }
    func testAntigravity() async throws { try enabled(); try await check(AntigravityProvider()) }

    /// ChatGPT plan usage through Sign in with ChatGPT. Needs a prior "Continue with ChatGPT"
    /// in a Debug build of the app (the credentials live in the app's Keychain item).
    func testChatGPTPlan() async throws {
        try enabled()
        guard let creds = ChatGPTAuth.shared.storedCredentials(), creds.hasPlanUsage else {
            throw XCTSkip("Sign in with ChatGPT (plan usage) in the app first")
        }
        let token = try await ChatGPTAuth.shared.validAccessToken()
        let models = try await OpenAIResponsesProvider.listModels(token: token)
        print("LIVE chatGPT models: \(models.prefix(8))")
        let model = try XCTUnwrap(models.first, "the account lists at least one model")
        try await check(OpenAIResponsesProvider(id: .chatGPT, model: model,
                                                token: { try await ChatGPTAuth.shared.validAccessToken() },
                                                isPlanRoute: true))
    }
}

#endif
