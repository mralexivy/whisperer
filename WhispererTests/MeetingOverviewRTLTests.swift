//
//  MeetingOverviewRTLTests.swift
//  WhispererTests
//
//  A Hebrew meeting's overview reads right to left: bullets, icons and checkboxes on the right,
//  timestamps on the left, paragraphs right-aligned. Rendered in a real window; set
//  TEST_RUNNER_OVERVIEW_SNAPSHOT to a directory to also write PNGs for a look.
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class MeetingOverviewRTLTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func summary(hebrew: Bool) -> MeetingAISummary {
        func t(_ he: String, _ en: String) -> String { hebrew ? he : en }
        return MeetingAISummary(
            overview: t("הפגישה עסקה בהעברת ה-\"task force playbook\" ובתיאום מול DevOps לפני הפריסה.",
                        "The meeting covered moving the task force playbook and DevOps coordination."),
            keyTopics: [TopicItem(id: UUID(), text: t("חזון המחלקה ל-2027 ואילך ופיתוח מודל בסיס.", "Department vision for 2027."), timestampSeconds: 997),
                        TopicItem(id: UUID(), text: t("סכום הפרס שקיבל \"רפאל\", רילוקיישן ואישור \"Nielsen\".", "Rafael's award and Nielsen approval."), timestampSeconds: 1086)],
            decisions: [DecisionItem(id: UUID(), label: t("דחיית הפלייבוק", "Playbook delay"),
                                     text: t("העברת ה-\"task force playbook\" הוזזה ליום רביעי.", "The playbook moved to Wednesday."), timestampSeconds: 149)],
            openQuestions: [QuestionItem(id: UUID(), text: t("מדוע כל צוות ה-\"MLE Offline\" משתתף בפגישה עם \"Realm\" לפני בחירת הספק?", "Why is all of MLE Offline in the Realm meeting?"), timestampSeconds: 300)],
            nextMeeting: t("ביום רביעי: העברת ה-\"task force playbook\". מקום לא צוין.", "Wednesday: the playbook. No place given."),
            actionItems: [MeetingActionItem(id: UUID(), text: t("ליצור בידוד לתשתית ה-\"self-host\" לפני המשך הרצת המודל.", "Isolate the self-host infra."),
                                            ownerName: "DevOps", dueLabel: nil, isDone: false)],
            generatedAt: Date())
    }

    private func render(hebrew: Bool) -> NSHostingView<AnyView> {
        var record = MeetingRecord(id: UUID(), title: "Alex <> Paz Weekly", language: hebrew ? "he" : "en", modelUsed: "v3")
        record.aiSummary = summary(hebrew: hebrew)
        let hosting = NSHostingView(rootView: AnyView(
            ScrollView { MeetingOverviewView(meeting: record).padding(20) }
                .frame(width: 900, height: 900)
                .background(Color(hex: "0E0E1F"))))
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 900, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window]
        let until = Date().addingTimeInterval(1)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        if let dir = ProcessInfo.processInfo.environment["OVERVIEW_SNAPSHOT"],
           let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent(hebrew ? "overview-he.png" : "overview-en.png"))
        }
        return hosting
    }

    private func fields(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let f = view as? NSTextField { out.append(f) }
        for sub in view.subviews { out += fields(in: sub) }
        return out
    }

    func testHebrewOverviewParagraphsAreRightToLeft() {
        let hosting = render(hebrew: true)
        let paragraphs = fields(in: hosting).filter { $0.stringValue.unicodeScalars.contains { (0x0590...0x05FF).contains($0.value) } }
        XCTAssertGreaterThanOrEqual(paragraphs.count, 6, "overview, topics, decision, question, next meeting, action")
        for field in paragraphs {
            let style = field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            XCTAssertEqual(style?.baseWritingDirection, .rightToLeft, field.stringValue)
            // Right-aligned paragraphs that fill the card, not shrink-wrapped against the left.
            let frame = field.convert(field.bounds, to: hosting)
            XCTAssertGreaterThan(frame.maxX, hosting.bounds.width * 0.6, field.stringValue)
        }
    }

    func testEnglishOverviewStaysLeftToRight() {
        let hosting = render(hebrew: false)
        XCTAssertTrue(fields(in: hosting).filter { $0.stringValue.contains("playbook") }.isEmpty,
                      "English paragraphs stay SwiftUI Text")
    }

    func testStarterQuestionsSpeakTheTopicsLanguage() {
        XCTAssertEqual(AskAIPane.tellMeAbout("תיאום זמן ופוליטיקה"), "ספר לי על תיאום זמן ופוליטיקה")
        XCTAssertEqual(AskAIPane.tellMeAbout("бюджет на GPU"), "Расскажи о бюджет на GPU")
        XCTAssertEqual(AskAIPane.tellMeAbout("GPU budget"), "Tell me about GPU budget")
        XCTAssertEqual(AskAIPane.tellMeAbout("\"self-host\" ותיאום מול DevOps"), "ספר לי על \"self-host\" ותיאום מול DevOps")
    }
}
