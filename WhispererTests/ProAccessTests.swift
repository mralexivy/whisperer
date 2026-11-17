import XCTest
@testable import whisperer

/// The $14.99 Pro purchase unlocks meetings, calendar, every AI feature and MCP; the $4.99 app keeps dictation.
@MainActor
final class ProAccessTests: XCTestCase {
    /// A @MainActor class must not be deallocated inside a synchronous test (see CLAUDE.md).
    private static let session = MeetingSession()

    override func tearDown() {
        ProAccess.testOverride = nil
        super.tearDown()
    }

    func testDirectBuildsAreUnlockedWithoutAStore() {
        #if !APP_STORE
        ProAccess.testOverride = nil
        XCTAssertTrue(ProAccess.isPro)
        #endif
    }

    func testEveryProFeatureClosesWithoutProAndOpensWithIt() {
        ProAccess.testOverride = false
        for feature in ProFeature.allCases { XCTAssertFalse(ProAccess.allows(feature), "\(feature)") }
        ProAccess.testOverride = true
        for feature in ProFeature.allCases { XCTAssertTrue(ProAccess.allows(feature), "\(feature)") }
    }

    func testLockedMessageNamesTheFeature() {
        XCTAssertTrue(ProAccess.lockedMessage(for: .meetings).contains("Meetings are part of Whisperer Pro"))
        XCTAssertTrue(ProAccess.lockedMessage(for: .mcp).contains("The MCP server is part of Whisperer Pro"))
    }

    func testMeetingsCannotStartWithoutPro() {
        ProAccess.testOverride = false
        XCTAssertEqual(RecordingStarter.meetingBlocker(session: Self.session), ProAccess.lockedMessage(for: .meetings))
        ProAccess.testOverride = true
        XCTAssertNil(RecordingStarter.meetingBlocker(session: Self.session))
    }

    func testCalendarAndAIProvidersDisappearWithoutPro() {
        ProAccess.testOverride = false
        XCTAssertTrue(CalendarAccountProvider.available.isEmpty)
        XCTAssertTrue(ConnectedAIStore.shared.availableProviders.isEmpty)
        ProAccess.testOverride = true
        XCTAssertFalse(CalendarAccountProvider.available.isEmpty)
    }

    func testAskAIRefusesWithoutPro() async {
        ProAccess.testOverride = false
        let answer = await MeetingAIService.shared.ask(question: "What was decided?", meetingID: UUID(), segments: [])
        XCTAssertEqual(answer.text, ProAccess.lockedMessage(for: .ai))
        XCTAssertFalse(answer.usedRAG)
    }

    func testAIDictationModesCannotBeSwitchedOnWithoutPro() {
        let state = AppState.shared
        let before = state.llmEnabled
        defer { state.llmEnabled = before }
        state.llmEnabled = false
        ProAccess.testOverride = false
        state.llmEnabled = true
        XCTAssertFalse(state.llmEnabled)
        XCTAssertEqual(state.errorMessage, ProAccess.lockedMessage(for: .ai))
        state.errorMessage = nil
    }
}
