//
//  OnboardingSnapshotTests.swift
//  WhispererTests
//
//  Opt-in look at every onboarding page: TEST_RUNNER_ONBOARDING_SNAPSHOT=<dir>. App Review
//  (Guideline 4, 2026-11-23) rejected build 12 for "windows that cut off text" on a 14" MacBook Pro,
//  and the onboarding window is the first window a reviewer sees. Skipped unless the variable is set.
//

import XCTest
import SwiftUI
@testable import whisperer

@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    private static var keepAlive: [AnyObject] = []

    func testOnboardingPagesSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["ONBOARDING_SNAPSHOT"] else {
            throw XCTSkip("set TEST_RUNNER_ONBOARDING_SNAPSHOT=<dir>")
        }
        for page in 0..<7 {
            let view = OnboardingView(initialPage: page, onComplete: nil)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 860, height: 540),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            window.makeKeyAndOrderFront(nil)
            Self.keepAlive += [hosting, window]
            let until = Date().addingTimeInterval(1.2)
            while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(page).png"))
            }
        }
    }

    /// The download page before the user pressed Download: names the model and its size, starts nothing.
    func testDownloadPageBeforeConsentSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["ONBOARDING_SNAPSHOT"] else {
            throw XCTSkip("set TEST_RUNNER_ONBOARDING_SNAPSHOT=<dir>")
        }
        let appState = AppState.shared
        let saved = appState.selectedBackendType
        defer { appState.selectedBackendType = saved }
        // An engine whose files are not on this machine, so the page shows its not-downloaded state.
        for backend in [BackendType.qwen3asr, .nemotronHebrew, .whisperKit] {
            appState.selectedBackendType = backend
            if !appState.isSelectedEngineDownloaded { break }
        }
        try XCTSkipIf(appState.isSelectedEngineDownloaded, "every candidate engine is on disk here")
        XCTAssertFalse(appState.isSelectedEngineDownloading, "opening the page must not start a download")
        let view = OnboardingView(initialPage: 6, onComplete: nil)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 860, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        Self.keepAlive += [hosting, window]
        let until = Date().addingTimeInterval(1.2)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        XCTAssertFalse(appState.isSelectedEngineDownloading, "the page must wait for the Download button")
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-download-consent.png"))
        }
    }
}
