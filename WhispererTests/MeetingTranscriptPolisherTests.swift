//
//  MeetingTranscriptPolisherTests.swift
//  WhispererTests
//
//  "Polish with <AI>": chunking, the acceptance guard that keeps a rewrite close to what
//  was said, apply/undo through rawText, and the full pass against a scripted provider.
//

import SwiftUI
import XCTest
@testable import whisperer

final class MeetingTranscriptPolisherTests: XCTestCase {

    private func seg(_ text: String, _ t: Double = 0) -> MeetingSegment {
        MeetingSegment(timestamp: t, endTimestamp: t + 4, text: text)
    }

    func testChunksRespectCardAndCharLimitsAndSkipEmpty() {
        let segments = (0..<10).map { seg("card \($0) with some words", Double($0)) } + [seg("   ")]
        let byCards = MeetingTranscriptPolisher.chunks(for: segments, maxCards: 4)
        XCTAssertEqual(byCards.map(\.indices.count), [4, 4, 2], "the empty card is skipped")
        let byChars = MeetingTranscriptPolisher.chunks(for: segments, maxCards: 100, maxChars: 60)
        XCTAssertTrue(byChars.count > 1)
        XCTAssertEqual(Set(byChars.flatMap(\.indices)), Set(0..<10))
    }

    func testInputCarriesIndexSpeakerAndOneLineText() {
        var s = seg("hello\nthere")
        s.speakerName = "Dana"
        let input = MeetingTranscriptPolisher.input(for: .init(indices: [0]), in: [s])
        XCTAssertEqual(input, "0 | Dana | hello there")
    }

    func testParseIsLenient() {
        let reply = #"Sure! {"segments":[{"id":0,"text":"Hello."},{"id":"2","text":"Bye."}]}"#
        XCTAssertEqual(MeetingTranscriptPolisher.parse(reply), [0: "Hello.", 2: "Bye."])
        XCTAssertEqual(MeetingTranscriptPolisher.parse("nope"), [:])
    }

    func testAcceptGuard() {
        let original = "um so we we decided to uh go with postgres for the events table"
        XCTAssertTrue(MeetingTranscriptPolisher.accept(original: original,
                                                       polished: "So we decided to go with Postgres for the events table."))
        XCTAssertFalse(MeetingTranscriptPolisher.accept(original: original, polished: ""), "empty is rejected")
        XCTAssertFalse(MeetingTranscriptPolisher.accept(original: original, polished: "Postgres."), "a summary is rejected")
        XCTAssertFalse(MeetingTranscriptPolisher.accept(original: original,
                                                        polished: original + " " + original), "padding is rejected")
        let hebrew = "אז אממ החלטנו ללכת עם פוסטגרס לטבלת האירועים"
        XCTAssertTrue(MeetingTranscriptPolisher.accept(original: hebrew, polished: "אז החלטנו ללכת עם פוסטגרס לטבלת האירועים."))
        XCTAssertFalse(MeetingTranscriptPolisher.accept(original: hebrew,
                                                        polished: "So we decided to go with Postgres for the events table."),
                       "a translation is rejected")
    }

    func testApplyKeepsOriginalAndUndoRestoresIt() {
        let segments = [seg("um we we decided on postgres"), seg("ok"), seg("this one stays exactly")]
        let outcome = MeetingTranscriptPolisher.apply([0: "We decided on Postgres.", 1: "OK.", 2: "this one stays exactly",
                                                       9: "out of range"], to: segments)
        XCTAssertEqual(outcome.changed, 2)
        XCTAssertEqual(outcome.segments[0].text, "We decided on Postgres.")
        XCTAssertEqual(outcome.segments[0].rawText, "um we we decided on postgres")
        XCTAssertTrue(outcome.segments[0].isPolished)
        XCTAssertNil(outcome.segments[2].rawText, "an unchanged card is not marked polished")
        XCTAssertEqual(outcome.segments[0].id, segments[0].id, "ids and timestamps never change")

        // A second pass keeps the recognizer's text, not the first rewrite.
        let again = MeetingTranscriptPolisher.apply([0: "We decided on Postgres!"], to: outcome.segments)
        XCTAssertEqual(again.segments[0].rawText, "um we we decided on postgres")

        let undone = MeetingTranscriptPolisher.undo(again.segments)
        XCTAssertEqual(undone.map(\.text), segments.map(\.text))
        XCTAssertTrue(undone.allSatisfy { $0.rawText == nil })
    }

    func testFullPassAgainstScriptedProvider() async throws {
        let segments = [seg("um we we picked postgres", 0), seg("uh bob will write the migration", 5)]
        let fake = FakeMeetingProvider(id: .codex)
        fake.completeReply = #"{"segments":[{"id":0,"text":"We picked Postgres."},{"id":1,"text":"Bob will write the migration."}]}"#
        let progress = Box<[Int]>([])
        let outcome = try await MeetingTranscriptPolisher.polish(segments, with: fake, languageName: "English") { done, _ in
            progress.mutate { $0.append(done) }
        }
        XCTAssertEqual(outcome.changed, 2)
        XCTAssertEqual(outcome.segments.map(\.text), ["We picked Postgres.", "Bob will write the migration."])
        XCTAssertEqual(progress.value, [0, 1])
        XCTAssertTrue(fake.completeInputs.first?.contains("1 | Speaker 1 | uh bob will write the migration") == true)
    }

    func testChunksRunInParallelAndApplyInOrder() async throws {
        // 300 cards → 3 chunks of 120/120/60; the fake answers each chunk from its own input.
        let segments = (0..<300).map { seg("um card number \($0) here", Double($0)) }
        let fake = FakeMeetingProvider(id: .chatGPT)
        fake.completeHandler = { input in
            let items = input.split(separator: "\n").compactMap { line -> String? in
                guard let id = line.split(separator: "|").first.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
                return #"{"id":\#(id),"text":"Card \#(id) here."}"#
            }
            return #"{"segments":[\#(items.joined(separator: ","))]}"#
        }
        let progress = Box<[Int]>([])
        let outcome = try await MeetingTranscriptPolisher.polish(segments, with: fake, languageName: nil) { d, _ in
            progress.mutate { $0.append(d) }
        }
        XCTAssertEqual(fake.completeInputs.count, 3)
        XCTAssertEqual(outcome.changed, 300)
        XCTAssertEqual(outcome.segments[0].text, "Card 0 here.")
        XCTAssertEqual(outcome.segments[299].text, "Card 299 here.")
        XCTAssertEqual(outcome.segments.map(\.id), segments.map(\.id), "order and ids kept")
        XCTAssertEqual(progress.value, [0, 1, 2, 3])
    }

    func testNewestPlanModelIsChosen() {
        let list = ["gpt-5.6-luna", "gpt-5.6-sol", "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna"]
        XCTAssertEqual(OpenAIResponsesProvider.newestModel(list), "gpt-6.1-sol", "highest version, server order breaks ties")
        XCTAssertNil(OpenAIResponsesProvider.newestModel([]))
        XCTAssertEqual(OpenAIResponsesProvider.newestModel(["custom-model"]), "custom-model")
    }

    func testPlanRouteSendsLowReasoningAndNoStructuredOutputField() {
        var p = OpenAIResponsesProvider(id: .chatGPT, model: "m", token: { "t" }, isPlanRoute: true)
        p.reasoningEffort = "low"
        let body = p.body(instructions: "I", user: "U", schema: nil)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["text"])
    }

    func testUnusableReplyFailsInsteadOfWipingText() async {
        let fake = FakeMeetingProvider(id: .codex)
        fake.completeReply = "I can't help with that."
        do {
            _ = try await MeetingTranscriptPolisher.polish([seg("hello there friends")], with: fake, languageName: nil) { _, _ in }
            XCTFail("expected failure")
        } catch {
            if case .schemaMismatch = error as? MeetingAIProviderError {} else { XCTFail("unexpected \(error)") }
        }
    }
}

@MainActor
final class TranscriptPolishControllerTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testRunRecordsProvenancePostsAndUndoes() async throws {
        let defaults = UserDefaults(suiteName: "PolishController-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults,
                                     keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        let controller = TranscriptPolishController(store: store, defaults: defaults)
        Self.keepAlive += [store, controller]
        var persisted: [[MeetingSegment]] = []
        controller.persist = { _, segments in persisted.append(segments) }

        let meetingID = UUID()
        let segments = [MeetingSegment(timestamp: 0, endTimestamp: 4, text: "um we we picked postgres")]
        let fake = FakeMeetingProvider(id: .claudeCode)
        fake.completeReply = #"{"segments":[{"id":0,"text":"We picked Postgres."}]}"#

        let posted = expectation(forNotification: .meetingSegmentsDidRefine, object: nil) { note in
            (note.object as? UUID) == meetingID
        }
        await controller.start(meetingID: meetingID, segments: segments, languageName: nil, provider: fake)?.value
        await fulfillment(of: [posted], timeout: 2)
        XCTAssertEqual(controller.phase(for: meetingID), .finished(changed: 1))
        XCTAssertEqual(controller.provenance(for: meetingID)?.provider, .claudeCode)
        XCTAssertEqual(persisted.last?.first?.text, "We picked Postgres.")

        await controller.undo(meetingID: meetingID, segments: persisted.last!)
        XCTAssertEqual(persisted.last?.first?.text, "um we we picked postgres")
        XCTAssertNil(controller.provenance(for: meetingID), "undo forgets who polished it")
    }

    func testStartWithoutProviderExplainsWhatToDo() {
        let defaults = UserDefaults(suiteName: "PolishController-\(UUID().uuidString)")!
        let store = ConnectedAIStore(defaults: defaults,
                                     keychain: KeychainStore(service: "com.ivy.whisperer.tests.\(UUID().uuidString)"))
        let controller = TranscriptPolishController(store: store, defaults: defaults)
        Self.keepAlive += [store, controller]
        let id = UUID()
        XCTAssertNil(controller.start(meetingID: id, segments: [], languageName: nil))
        if case .failed(let message) = controller.phase(for: id) {
            XCTAssertTrue(message.contains("LLM page"))
        } else { XCTFail("expected a failure telling the user where to choose an AI") }
    }

    func testPolishBarRendersEveryState() throws {
        let id = UUID()
        let segments = [MeetingSegment(timestamp: 0, endTimestamp: 4, text: "hello")]
        let hosting = NSHostingView(rootView: TranscriptPolishBar(meetingID: id, segments: segments))
        hosting.frame = CGRect(x: 0, y: 0, width: 500, height: 40)
        hosting.layoutSubtreeIfNeeded()
        Self.keepAlive.append(hosting)
        XCTAssertGreaterThan(hosting.fittingSize.width, 60)
    }
}
