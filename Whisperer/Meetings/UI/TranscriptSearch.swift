//
//  TranscriptSearch.swift
//  Whisperer
//
//  Search model, match finder, temporary-attribute highlighter, and tick gutter
//  for the meeting transcript.
//
//  Performance contract — each rule maps to a concrete mechanism:
//
//  1. Keystrokes never invalidate MeetingDetailView's body.
//     TranscriptSearchModel is held with @State (not @StateObject) in the parent;
//     only leaf views that need updates take it as @ObservedObject.
//
//  2. Highlights use NSLayoutManager.addTemporaryAttributes — display-only, no storage
//     mutation, no relayout, selection is unaffected.
//
//  3. Scanning runs in a Task.detached with a 120 ms debounce and cancellation every
//     256 matches, over a cached text snapshot so the text view is never read per keystroke.
//
//  4. Y geometry is computed once per match set, not per frame.
//
//  5. SwiftUI diffing uses a matchesVersion: Int token, not an array of Equatable structs.
//     The tick gutter is a single Canvas, not a ForEach.
//

import SwiftUI
import AppKit
import Combine

// MARK: - TranscriptMatch

/// One non-overlapping search hit inside the transcript.
///
/// `id` is the ordinal (0-based) and doubles as the navigation index.
/// `minY` / `maxY` are in the text view's flipped coordinate space, filled in after layout
/// via `TranscriptSearch.locateMatches` and returned through `TranscriptSearchModel.report`.
struct TranscriptMatch: Equatable, Identifiable {
    let id: Int
    let range: NSRange
    var minY: CGFloat = 0
    var maxY: CGFloat = 0
}

// MARK: - TranscriptSearch

/// Stateless, nonisolated helpers — safe to call from any actor or detached task.
enum TranscriptSearch {

    /// Minimum query length before a scan is attempted.
    static let minQueryLength = 2

    /// Maximum number of matches to pre-paint and locate geometrically.
    /// `totalMatches` is always exact; only decoration is capped.
    static let maxDecorated = 2_000

    static let scanOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    // MARK: Colors

    /// Dim amber — all non-current matches.
    static let dimBackground = NSColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 0.22)
    /// Bright amber — the current match.
    static let hotBackground  = NSColor(red: 0.961, green: 0.620, blue: 0.043, alpha: 0.85)
    /// Dark navy foreground on the bright match so it stays legible.
    static let hotForeground  = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)

    /// Tick tint in the SwiftUI gutter.
    static let tickColor    = Color(red: 0.961, green: 0.620, blue: 0.043).opacity(0.45)
    static let tickColorHot = Color(red: 0.961, green: 0.620, blue: 0.043)

    // MARK: - Scan

    /// Returns all non-overlapping matches in document order.
    ///
    /// Checks `Task.isCancelled` every 256 iterations so an in-flight scan can be
    /// abandoned when the query changes. Returns an empty array when cancelled or when
    /// `query` is shorter than `minQueryLength`.
    static func findMatches(in text: String, query: String) -> [TranscriptMatch] {
        guard query.count >= minQueryLength else { return [] }
        var results: [TranscriptMatch] = []
        var cursor = text.startIndex
        var since = 0
        while cursor < text.endIndex {
            since += 1
            if since == 256 {
                since = 0
                if Task.isCancelled { return [] }
            }
            guard let range = text.range(of: query, options: scanOptions, range: cursor..<text.endIndex) else { break }
            results.append(TranscriptMatch(id: results.count, range: NSRange(range, in: text)))
            // Advance past the match end; guard against zero-length matches
            cursor = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.upperBound)
        }
        return results
    }

    // MARK: - Highlight

    /// Clears all search temporary attributes on `layoutManager` and repaints:
    ///   - dim amber background on every match in `matches.prefix(maxDecorated)`
    ///   - bright amber background + dark foreground on the match at `currentIndex`
    ///
    /// Temporary attributes are display-only: they do not mutate text storage, do not
    /// invalidate layout, and do not affect the user's selection.
    static func applyHighlights(
        layoutManager: NSLayoutManager,
        storageLength: Int,
        matches: [TranscriptMatch],
        currentIndex: Int?
    ) {
        guard storageLength > 0 else { return }
        let full = NSRange(location: 0, length: storageLength)

        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)

        for match in matches.prefix(maxDecorated) {
            guard match.range.upperBound <= storageLength else { continue }
            layoutManager.addTemporaryAttributes([.backgroundColor: dimBackground],
                                                  forCharacterRange: match.range)
        }

        if let idx = currentIndex, idx < matches.count {
            let m = matches[idx]
            guard m.range.upperBound <= storageLength else { return }
            layoutManager.addTemporaryAttributes(
                [.backgroundColor: hotBackground, .foregroundColor: hotForeground],
                forCharacterRange: m.range)
        }
    }

    /// Clears all temporary search attributes without repainting.
    static func clearHighlights(layoutManager: NSLayoutManager, storageLength: Int) {
        guard storageLength > 0 else { return }
        let full = NSRange(location: 0, length: storageLength)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
    }

    // MARK: - Geometry

    /// Fills in `minY` and `maxY` for each match using `enumerateLineFragments`.
    ///
    /// `textContainerInset.height` is added so the coordinates are in the text view's
    /// flipped space (matching how `SegmentMetrics` is computed).
    static func locateMatches(
        _ matches: [TranscriptMatch],
        layoutManager: NSLayoutManager,
        textContainerInset: NSSize
    ) -> [TranscriptMatch] {
        let insetY = textContainerInset.height
        return matches.map { match in
            var m = match
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: match.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return m }
            var minY = CGFloat.greatestFiniteMagnitude
            var maxY: CGFloat = 0
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, used, _, _, _ in
                minY = min(minY, used.minY)
                maxY = max(maxY, used.maxY)
            }
            if maxY > minY {
                m.minY = insetY + minY
                m.maxY = insetY + maxY
            }
            return m
        }
    }
}

// MARK: - TranscriptSearchModel

/// Owned by `MeetingDetailView` as `@State` — reference held, not observed — so typing
/// never invalidates the parent's body. Leaf views that need updates take it as `@ObservedObject`.
@MainActor final class TranscriptSearchModel: ObservableObject {

    // MARK: Published (bound to UI)

    /// Bound to the search field via `TranscriptSearchRow`.
    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleDebounce()
        }
    }

    /// Bumped each time a new located match set lands. SwiftUI compares `Int` instead of
    /// deep-comparing `[TranscriptMatch]`, keeping diffing cost negligible.
    @Published private(set) var matchesVersion: Int = 0

    /// Total match count — always exact, even when decoration is capped.
    @Published private(set) var totalMatches: Int = 0

    /// Navigation cursor into `matches`. `nil` when there are no matches.
    @Published var currentIndex: Int? = nil {
        didSet {
            guard currentIndex != oldValue else { return }
            pulseToken &+= 1
        }
    }

    /// Bumped on each navigation jump — drives the pulse animation in `MatchOverlay`.
    @Published private(set) var pulseToken: Int = 0

    // MARK: Non-published (read via matchesVersion gate)

    /// Located matches with Y geometry — read by overlay views after `matchesVersion` bumps.
    private(set) var matches: [TranscriptMatch] = []

    /// Total content height of the transcript, reported by the text view after layout.
    /// Used by the tick gutter to map Y positions to tick positions.
    var contentHeight: CGFloat = 1

    // MARK: Private

    private var textSnapshot: String = ""
    private var debounceTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    // MARK: - Navigation

    func next() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    func previous() {
        guard !matches.isEmpty else { return }
        currentIndex = ((currentIndex ?? matches.count) - 1 + matches.count) % matches.count
    }

    func clear() {
        debounceTask?.cancel()
        scanTask?.cancel()
        query = ""
        applyResult([], from: "")
    }

    // MARK: - Content change

    /// Called by the text view coordinator when text storage is rebuilt, so the scanner
    /// always works from a fresh snapshot without touching the view per keystroke.
    func ingest(text: String) {
        guard text != textSnapshot else { return }
        textSnapshot = text
        triggerScan(query: query)
    }

    // MARK: - Geometry write-back

    /// Called by the text view coordinator once Y positions have been computed.
    func report(located: [TranscriptMatch], contentHeight: CGFloat) {
        matches = located
        self.contentHeight = contentHeight
        // Keep the cursor clamped to the new bounds; initialise to 0 when geometry first
        // arrives for a match set that was previously unknown (currentIndex was nil).
        if matches.isEmpty {
            currentIndex = nil
        } else if let idx = currentIndex {
            currentIndex = min(idx, matches.count - 1)
        } else {
            currentIndex = 0
        }
        matchesVersion &+= 1
    }

    // MARK: - Internal

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let q = query
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000) // 120 ms
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.triggerScan(query: q) }
        }
    }

    private func triggerScan(query: String) {
        scanTask?.cancel()
        let snapshot = textSnapshot
        let q = query
        scanTask = Task.detached { [weak self] in
            let found = TranscriptSearch.findMatches(in: snapshot, query: q)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.applyResult(found, from: q) }
        }
    }

    /// Applies a raw match array (no geometry yet). Geometry is provided later by the
    /// text view coordinator via `report(located:contentHeight:)`.
    private func applyResult(_ found: [TranscriptMatch], from _: String) {
        matches = found
        totalMatches = found.count
        if found.isEmpty {
            currentIndex = nil
        } else if let idx = currentIndex, idx < found.count {
            // Keep position
        } else {
            currentIndex = 0
        }
        matchesVersion &+= 1
    }
}

// MARK: - TranscriptMatchTicks

/// Single-Canvas tick gutter showing every match's vertical position.
///
/// Overlaid on the trailing (or leading when RTL) edge of the transcript container.
/// Clicking a tick sets `search.currentIndex` directly.
struct TranscriptMatchTicks: View {
    @ObservedObject var search: TranscriptSearchModel
    let isRTL: Bool

    var body: some View {
        Group {
            if search.totalMatches > 0 {
                GeometryReader { geo in
                    Canvas { ctx, size in
                        drawTicks(ctx: ctx, size: size)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        jumpToNearestTick(at: location, in: geo.size)
                    }
                }
                .frame(width: 10)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: search.totalMatches > 0)
    }

    private func drawTicks(ctx: GraphicsContext, size: CGSize) {
        guard search.contentHeight > 0, size.height > 0 else { return }
        let fraction = size.height / search.contentHeight
        for match in search.matches.prefix(TranscriptSearch.maxDecorated) {
            let isCurrent = match.id == search.currentIndex
            let tickW: CGFloat = isCurrent ? 4 : 2
            let tickH: CGFloat = 6
            let x: CGFloat = isRTL ? 0 : (size.width - tickW)
            let y = match.minY * fraction - tickH / 2
            let rect = CGRect(x: x, y: y, width: tickW, height: tickH)
            let color = isCurrent ? TranscriptSearch.tickColorHot : TranscriptSearch.tickColor
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
        }
    }

    private func jumpToNearestTick(at location: CGPoint, in size: CGSize) {
        guard search.contentHeight > 0, size.height > 0 else { return }
        let fraction = size.height / search.contentHeight
        let clickedContent = location.y / fraction
        if let nearest = search.matches
            .prefix(TranscriptSearch.maxDecorated)
            .min(by: { abs($0.minY - clickedContent) < abs($1.minY - clickedContent) }) {
            search.currentIndex = nearest.id
        }
    }
}

// MARK: - TranscriptSearchRow

/// The extended search toolbar row — the only UI element that binds to `search.query`,
/// so it is the only view that re-renders on every keystroke.
struct TranscriptSearchRow: View {
    @ObservedObject var search: TranscriptSearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))

            TextField("Search transcript…", text: $search.query)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { search.next() }

            // Hidden button so Shift+Return navigates backwards
            Button("") { search.previous() }
                .opacity(0)
                .frame(width: 0, height: 0)
                .keyboardShortcut(.return, modifiers: .shift)
                .allowsHitTesting(false)

            if !search.query.isEmpty {
                countLabel
                    .transition(.opacity)

                HStack(spacing: 2) {
                    navButton(icon: "chevron.up",  action: search.previous)
                    navButton(icon: "chevron.down", action: search.next)
                }
                .transition(.opacity)

                clearButton
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .animation(.easeInOut(duration: 0.15), value: search.query.isEmpty)
    }

    // MARK: Sub-views

    @ViewBuilder
    private var countLabel: some View {
        let count = search.totalMatches
        if count == 0 && search.query.count >= TranscriptSearch.minQueryLength {
            Text("No results")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color(red: 0.937, green: 0.267, blue: 0.267).opacity(0.7))
                .fixedSize()
        } else if count > 0, let idx = search.currentIndex {
            Text("\(idx + 1)/\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundColor(.white.opacity(0.45))
                .fixedSize()
        }
    }

    private func navButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 20, height: 18)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .disabled(search.totalMatches == 0)
    }

    private var clearButton: some View {
        Button {
            search.clear()
            fieldFocused = false
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MatchOverlay

/// A thin leaf view that observes the search model and draws:
///   - Zero-height anchor frames for scroll-to-match (`id("sm-\(id)")`)
///   - The current-match pulse: amber glow fading out over 0.6 s
///
/// Kept separate from `MeetingTranscriptView`'s card/gutter views so a match change
/// never re-renders the heavy card layer. The actual scroll is triggered by an
/// `.onChange(of: search.currentIndex)` in the parent's `ScrollViewReader`.
struct MatchOverlay: View {
    @ObservedObject var search: TranscriptSearchModel

    var body: some View {
        // Anchor frames — zero height, absolutely positioned so proxy.scrollTo works
        ForEach(search.matches, id: \.id) { match in
            Color.clear
                .frame(height: 0)
                .id("sm-\(match.id)")
                .offset(y: match.minY)
        }

        // Current-match pulse
        if let idx = search.currentIndex, idx < search.matches.count {
            let m = search.matches[idx]
            let h = max(m.maxY - m.minY, 20)
            PulseRect(token: search.pulseToken, height: h)
                .offset(y: m.minY)
                .allowsHitTesting(false)
        }
    }
}

/// One amber glow rectangle that fades in and out, re-keyed by `token`.
private struct PulseRect: View {
    let token: Int
    let height: CGFloat
    @State private var opacity: Double = 0

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(red: 0.961, green: 0.620, blue: 0.043).opacity(opacity))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .padding(.horizontal, TranscriptLayout.outerMargin)
            .onAppear { pulse() }
            .onChange(of: token) { _, _ in pulse() }
    }

    private func pulse() {
        opacity = 0.5
        withAnimation(.easeOut(duration: 0.6)) { opacity = 0 }
    }
}
