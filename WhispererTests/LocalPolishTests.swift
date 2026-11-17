import XCTest
@testable import whisperer

/// The on-device polish: line format in and out, guardrails kept, nothing sent anywhere.
final class LocalPolishTests: XCTestCase {
    private func segments() -> [MeetingSegment] {
        ["so um the the launch is on thursday", "we need to uh finish the report", "ok"].enumerated().map {
            MeetingSegment(timestamp: Double($0.offset), endTimestamp: Double($0.offset) + 1, text: $0.element,
                           speakerName: "Alex", speakerIndex: 0)
        }
    }

    func testParsesIdPipeTextLinesAndDropsACopiedSpeaker() {
        let reply = "0 | So, the launch is on Thursday.\n1 | Alex | We need to finish the report.\nnoise line\n2 |   "
        let parsed = MeetingTranscriptPolisher.parseLines(reply, speakers: [0: "Alex", 1: "Alex", 2: "Alex"])
        XCTAssertEqual(parsed[0], "So, the launch is on Thursday.")
        XCTAssertEqual(parsed[1], "We need to finish the report.")
        XCTAssertNil(parsed[2])
    }

    func testLocalPassRewritesKeepsTheOriginalAndNeedsNoProvider() async throws {
        let out = try await MeetingTranscriptPolisher.polishLocally(
            segments(), languageName: "English",
            complete: { _, _ in "0 | So, the launch is on Thursday.\n1 | We need to finish the report.\n2 | Ok." },
            onProgress: { _, _ in })
        XCTAssertEqual(out.segments[0].text, "So, the launch is on Thursday.")
        XCTAssertEqual(out.segments[0].rawText, "so um the the launch is on thursday")
        XCTAssertGreaterThanOrEqual(out.changed, 2)
        let restored = MeetingTranscriptPolisher.undo(out.segments)
        XCTAssertEqual(restored[0].text, "so um the the launch is on thursday")
    }

    func testAReplyWithNothingUsableFailsInsteadOfPretendingToPolish() async {
        do {
            _ = try await MeetingTranscriptPolisher.polishLocally(segments(), languageName: nil,
                                                                  complete: { _, _ in "I cannot help with that." }, onProgress: { _, _ in })
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error is MeetingAIProviderError)
        }
    }

    func testAnImplausibleRewriteIsRejected() async throws {
        let out = try await MeetingTranscriptPolisher.polishLocally(
            segments(), languageName: nil,
            complete: { _, _ in "0 | x\n1 | We need to finish the report." }, onProgress: { _, _ in })
        XCTAssertEqual(out.segments[0].text, "so um the the launch is on thursday", "a rewrite far shorter than the original is dropped")
    }
}
