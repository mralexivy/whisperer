//
//  WindowServerCostTests.swift
//  WhispererTests
//
//  What our windows cost WindowServer while nothing changes on screen: its CPU time (from `ps`)
//  over a few seconds with a view up. A view that animates forever makes WindowServer composite
//  every frame for as long as it is visible. Opt-in: TEST_RUNNER_WINDOWSERVER_COST=1
//

import AppKit
import SwiftUI
import XCTest
@testable import whisperer

@MainActor
final class WindowServerCostTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func windowServerCPU() -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Ao", "time=,comm="]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let line = String(data: data, encoding: .utf8)?.split(separator: "\n")
            .first { $0.hasSuffix("/WindowServer") || $0.hasSuffix(" WindowServer") } ?? ""
        let t = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? "0"
        let parts = t.split(separator: ":").map { Double($0) ?? 0 }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : 0
    }

    private func measure(_ label: String, _ view: AnyView?, seconds: TimeInterval = 8) -> Double {
        var window: NSWindow?
        if let view {
            let hosting = NSHostingView(rootView: view.frame(width: 380, height: 520).background(Color(hex: "14142B")))
            let w = NSWindow(contentRect: CGRect(x: 60, y: 60, width: 380, height: 520),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = hosting
            w.makeKeyAndOrderFront(nil)
            window = w
            Self.keepAlive += [hosting, w]
        }
        func pump(_ s: TimeInterval) {
            let until = Date().addingTimeInterval(s)
            while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        pump(2)   // let entrances finish
        let a = windowServerCPU()
        pump(seconds)
        let ms = (windowServerCPU() - a) / seconds * 1000
        print(String(format: "[WindowServerCost] %@: WindowServer CPU %.0f ms/s", label, ms))
        window?.orderOut(nil)
        return ms
    }

    func testIdleViewsCost() throws {
        guard ProcessInfo.processInfo.environment["WINDOWSERVER_COST"] == "1" else { throw XCTSkip("set TEST_RUNNER_WINDOWSERVER_COST=1") }
        _ = measure("nothing", nil)
        _ = measure("static text", AnyView(Text("we will talk about the budget").foregroundColor(.white).padding(16)))
        _ = measure("live bubble, idle", AnyView(MeetingLiveTailText(text: "we will talk about the budget", isRTL: false).padding(16)))
        let session = MeetingSession()
        session.isRecording = true
        session.segments = [MeetingSegment(timestamp: 0, endTimestamp: 8, text: "we will talk about the budget for next quarter",
                                           speakerName: "Alex", speakerIndex: 0)]
        Self.keepAlive.append(session)
        _ = measure("meeting live window, idle", AnyView(MeetingLiveWindowView(session: session, onClose: {}, onCollapseChanged: { _ in })),
                    seconds: 8)
    }
}
