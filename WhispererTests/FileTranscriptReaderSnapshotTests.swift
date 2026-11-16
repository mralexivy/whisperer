import XCTest
import SwiftUI
@testable import whisperer

/// Opt-in: renders the reader to a PNG (`TEST_RUNNER_READER_PNG=/path.png`) for a visual check.
@MainActor
final class FileTranscriptReaderSnapshotTests: XCTestCase {
    func testRenderReader() throws {
        guard let path = ProcessInfo.processInfo.environment["READER_PNG"] else { throw XCTSkip("set TEST_RUNNER_READER_PNG") }
        let en = "Hello, thank you for joining us today for our on-call webinar. We are going to be diving into how we can operate this as a teammate in your Slack incident channel. One of the breakaway use cases for this product today is incident on-call and incident response. My name is Kevin Martin and I work on go-to-market incubations. Obviously in 2023, the way that people were engaging with large language models was primarily via chat. In 2025, we brought the coding agent to market, and that is really the first enterprise-grade agent that is still the industry leader. If you were walking the halls in 2025, we would notice something really funny. People outside of engineering organizations, marketing, finance, were using it to do their job."
        let he = "שלום לכולם, תודה שהצטרפתם אלינו היום. אנחנו הולכים לדבר על איך אפשר להפעיל את המוצר הזה כחבר צוות בערוץ האירועים שלכם. אחד ממקרי השימוש המרכזיים היום הוא תגובה לאירועים ותורנות. קוראים לי קווין ואני עובד על חדשנות בשוק. ב-2023 האנשים עבדו מול מודלי שפה בעיקר דרך צ׳אט. ב-2025 הבאנו לשוק את הסוכן הראשון ברמה ארגונית, והוא עדיין מוביל בתעשייה."
        let text = [en, en, he, en].joined(separator: " ")
        let total = FileTranscriptParagraphs.wordCount(text)
        let paragraphs = FileTranscriptParagraphs.split(text, anchors: [.init(word: 0, seconds: 0), .init(word: total, seconds: 2708)])
        let view = FileTranscriptReaderView(paragraphs: paragraphs, language: .english, colorScheme: .dark)
            .padding(24).frame(width: 980).background(Color(red: 0.078, green: 0.078, blue: 0.169)).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 1400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        print("READER paragraphs=\(paragraphs.count)")
    }
}
