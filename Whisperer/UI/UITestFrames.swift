//
//  UITestFrames.swift
//  Whisperer
//
//  Lets unit tests click real controls with real mouse events. A view tagged with
//  `.uiTestFrame("id")` records its on-screen frame (debug builds only); a test converts that
//  to window coordinates and sends mouse-down / mouse-up through `NSWindow.sendEvent`, so
//  SwiftUI's own hit-testing and control handling run exactly as for a user. Pages set
//  `.environment(\.uiTestScope, …)` so pages left alive by earlier tests can't overwrite
//  the current one's frames. In release builds the modifier does nothing.
//

import SwiftUI

// MARK: - Click-test frames

/// Where each tagged control sits in its window, so tests can click it with real mouse
/// events (`NSWindow.sendEvent`) instead of calling the action directly. Debug builds only;
/// in release the modifier is a no-op. Frames are keyed by the page's scope so pages left
/// alive by earlier tests can't overwrite the current one's.
@MainActor
enum UITestFrames {
    #if DEBUG
    /// SwiftUI global frames (top-left origin, in the hosting window's content coordinates).
    static var frames: [String: CGRect] = [:]
    static func key(scope: String, id: String) -> String { "\(scope)|\(id)" }
    #endif
}

private struct UITestScopeKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var uiTestScope: String {
        get { self[UITestScopeKey.self] }
        set { self[UITestScopeKey.self] = newValue }
    }
}

private struct UITestFrameModifier: ViewModifier {
    let id: String
    @Environment(\.uiTestScope) private var scope

    func body(content: Content) -> some View {
        #if DEBUG
        content.background(GeometryReader { geometry in
            let key = UITestFrames.key(scope: scope, id: id)
            Color.clear
                .onAppear { UITestFrames.frames[key] = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { _, frame in UITestFrames.frames[key] = frame }
                // A reused control whose label changes keeps its view identity, so onAppear
                // does not fire again; record under the new key too.
                .onChange(of: key) { _, newKey in UITestFrames.frames[newKey] = geometry.frame(in: .global) }
        })
        #else
        content
        #endif
    }
}

extension View {
    func uiTestFrame(_ id: String) -> some View {
        modifier(UITestFrameModifier(id: id))
    }
}
