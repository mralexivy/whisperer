//
//  MeetingLiveTranscriptView.swift
//  Whisperer
//
//  Narrow-column live transcript for the floating meeting window.
//

import SwiftUI
import Combine

/// A live-only transcript renderer for the 400pt floating window.
///
/// Deliberately not `MeetingTranscriptView`: that view lays committed segments into a single
/// `NSTextView` with SwiftUI card / gutter / hover overlays positioned from published
/// `segmentMetrics`, plus a timestamp column, rename popovers, tag menus, playhead sync and the
/// polish sweep — geometry tuned for a wide column and review interactions that have no place
/// over a live call. This is the same visual language (speaker colour, `#14142B` card, one-colour
/// live tail) in a plain `LazyVStack`.
///
/// **Energy.** This view does not observe the session. A session publishes on every live update (about three a
/// second) and on every other change, and observing it re-evaluated the body — every committed card — each time. The
/// committed cards depend only on `segments` and on `MeetingLiveEdge`, which publishes just when recording starts or
/// stops or the live tail appears or empties. The live text is drawn by `MeetingLiveBubble`, the only view that
/// observes the session (2026-11-15).
struct MeetingLiveTranscriptView: View {
    let session: MeetingSession
    let meeting: MeetingRecord?
    let segments: [MeetingSegment]
    @StateObject private var edge: MeetingLiveEdge
    @State private var direction = TranscriptDirectionCache()

    init(session: MeetingSession, meeting: MeetingRecord?, segments: [MeetingSegment]) {
        self.session = session
        self.meeting = meeting
        self.segments = segments
        _edge = StateObject(wrappedValue: MeetingLiveEdge(session: session))
    }

    private let cardRadius: CGFloat = 10
    private let outerMargin: CGFloat = 14
    /// How close to the bottom still counts as "watching the live edge".
    private static let pinThreshold: CGFloat = 24
    /// Height of the fade under the tab bar. Fixed points, not a fraction — the window is now a
    /// full-height rail, and a proportional fade would swallow a whole card on a tall display.
    private static let fadeHeight: CGFloat = 16

    /// False once the user scrolls up to read back. Auto-scroll is suspended until they return
    /// to the bottom — on a full-height column there is real history to read, and yanking it
    /// away on every preview token made that impossible.
    @State private var isPinnedToLive = true

    private var isLive: Bool {
        edge.isRecording && edge.sessionMeetingID == meeting?.id
    }

    private var hasLiveTail: Bool { edge.hasLiveTail }

    /// Content decides direction; the language setting is only the fallback when there is no
    /// text yet. Same rule as `MeetingTranscriptView`.
    private var isRTL: Bool {
        direction.isRightToLeft(
            segments: segments,
            liveTail: "", // the cards come from `segments`; the live bubble judges its own direction
            fallback: TranscriptionLanguage(rawValue: meeting?.language ?? ""))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if isLive {
                        LivePreviewNoticeBanner()
                            .frame(maxWidth: .infinity)
                    }
                    if segments.isEmpty && !hasLiveTail {
                        emptyState
                    } else {
                        ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                            segmentCard(segment, previous: index > 0 ? segments[index - 1] : nil)
                                .id(segment.id)
                        }
                    }

                    if isLive && hasLiveTail {
                        MeetingLiveBubble(session: session, segments: segments, language: meeting?.language,
                                          cardRadius: cardRadius, onGrow: { scrollToLive(proxy) })
                            .id("livePreview")
                    }
                }
                .padding(.horizontal, outerMargin)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            // Content dissolves under the tab bar instead of being sliced by a hard edge. A gradient laid over the
            // top edge in the window's own colour, not a mask: a mask forces the whole scrolling column through an
            // offscreen pass every time it changes, which a live transcript does several times a second.
            .overlay(alignment: .top) {
                LinearGradient(colors: [Color(hex: "0C0C1A"), Color(hex: "0C0C1A").opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Self.fadeHeight)
                    .allowsHitTesting(false)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.pinThreshold
            } action: { _, atBottom in
                guard atBottom != isPinnedToLive else { return }
                isPinnedToLive = atBottom
            }
            .overlay(alignment: .bottom) {
                if isLive && !isPinnedToLive {
                    jumpToLiveButton { scrollToLive(proxy, force: true) }
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isPinnedToLive)
            .onChange(of: segments.count)             { _, _ in scrollToLive(proxy) }
            .onAppear { scrollToLive(proxy, force: true) }
        }
    }

    /// Returns the user to the live edge after they have scrolled back. Deliberately labelled
    /// "Live" rather than "Jump to bottom" — the bottom of this column is a moving target.
    private func jumpToLiveButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text("Live")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(hex: "5B6CF7")))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: Color(hex: "5B6CF7").opacity(0.35), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Committed segments

    /// A speaker header only when the speaker actually changes — a name above every card turns a
    /// monologue into a wall of labels.
    private func startsNewTurn(_ segment: MeetingSegment, previous: MeetingSegment?) -> Bool {
        guard let previous else { return true }
        return previous.speakerIndex != segment.speakerIndex
            || previous.speakerName != segment.speakerName
    }

    @ViewBuilder
    private func segmentCard(_ segment: MeetingSegment, previous: MeetingSegment?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if startsNewTurn(segment, previous: previous) {
                speakerHeader(name: segment.speakerName,
                              index: segment.speakerIndex,
                              seconds: segment.timestamp)
            }
            transcriptText(segment.text)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .fill(Color(hex: "14142B"))
        )
        .overlay(alignment: isRTL ? .trailing : .leading) {
            Rectangle()
                .fill(speakerColor(for: segment.speakerIndex).opacity(0.32))
                .frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
    }

    private func speakerHeader(name: String, index: Int, seconds: Double) -> some View {
        MeetingLiveSpeakerHeader(name: name, index: index, seconds: seconds, isRTL: isRTL)
    }

    /// SwiftUI `Text` cannot set paragraph base writing direction — RTL goes through the
    /// `NSTextField` wrapper. See ARCHITECTURE.md.
    @ViewBuilder
    private func transcriptText(_ text: String) -> some View {
        if isRTL {
            MeetingSegmentTextView(text: text, highlightQuery: "", isRTL: true)
        } else {
            Text(text)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.88))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            SonarDot()
            Text(edge.isRecording ? "Listening…" : "No transcript yet")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.3))
            if edge.isRecording {
                Text("Words appear here as they are spoken")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Helpers

    /// `force` is the "Live" pill and first appearance — everything else defers to where the
    /// user has put the scroll view.
    private func scrollToLive(_ proxy: ScrollViewProxy, force: Bool = false) {
        guard isLive, force || isPinnedToLive else { return }
        let anchorID: AnyHashable? = hasLiveTail ? "livePreview" : segments.last?.id
        guard let anchorID else { return }
        if force {
            isPinnedToLive = true
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(anchorID, anchor: .bottom) }
        } else {
            // Following the live edge is not animated: it used to run a 200 ms animated scroll on every live update,
            // so the whole column kept drifting under the reader's eye and the window kept redrawing.
            proxy.scrollTo(anchorID, anchor: .bottom)
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

}

// MARK: - Sonar dot

/// Quiet "we are hearing you" pulse for the pre-first-chunk window. A few pulses, then still:
/// a pulse that never ends keeps WindowServer compositing the window (see `KineticCaret`).
struct SonarDot: View {
    @State private var animating = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(hex: "5B6CF7").opacity(0.35), lineWidth: 1)
                .frame(width: 28, height: 28)
                .scaleEffect(animating ? 1.35 : 0.75)
                .opacity(animating ? 0 : 0.9)
            Circle()
                .fill(Color(hex: "5B6CF7"))
                .frame(width: 8, height: 8)
        }
        .frame(width: 40, height: 40)
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatCount(4, autoreverses: false)) {
                animating = true
            }
        }
    }
}

// MARK: - Live edge

/// What the committed cards need to know about the session, and nothing that changes while someone is talking:
/// whether a recording is running, which meeting it is, and whether there is any live text at all. Each publishes only
/// when it actually flips.
@MainActor
final class MeetingLiveEdge: ObservableObject {
    @Published private(set) var isRecording: Bool
    @Published private(set) var sessionMeetingID: UUID?
    @Published private(set) var hasLiveTail: Bool
    private var bag = Set<AnyCancellable>()

    init(session: MeetingSession) {
        isRecording = session.isRecording
        sessionMeetingID = session.meetingID
        hasLiveTail = session.hasLiveTail
        session.$isRecording.removeDuplicates().sink { [weak self] in self?.isRecording = $0 }.store(in: &bag)
        session.$meetingID.removeDuplicates().sink { [weak self] in self?.sessionMeetingID = $0 }.store(in: &bag)
        session.liveTailPresence.removeDuplicates().sink { [weak self] in self?.hasLiveTail = $0 }.store(in: &bag)
    }
}

// MARK: - Live bubble

/// The open paragraph and what is being heard now. The only view in the live window that observes the session, so
/// a live update re-evaluates this one card and nothing above it.
private struct MeetingLiveBubble: View {
    @ObservedObject var session: MeetingSession
    let segments: [MeetingSegment]
    let language: String?
    let cardRadius: CGFloat
    let onGrow: () -> Void

    @State private var direction = TranscriptDirectionCache()

    private var combinedText: String {
        var parts: [String] = []
        if !session.currentSegmentText.isEmpty { parts.append(session.currentSegmentText) }
        if !session.livePreviewText.isEmpty { parts.append(session.livePreviewText) }
        return parts.joined(separator: " ")
    }

    var body: some View {
        let text = combinedText
        let rtl = direction.isRightToLeft(segments: segments, liveTail: text, fallback: TranscriptionLanguage(rawValue: language ?? ""))
        let continuesPreviousTurn = session.hasSpeakerSignal && segments.last.map {
            $0.speakerIndex == session.liveSpeakerIndex && $0.speakerName == session.liveSpeakerName
        } == true

        VStack(alignment: .leading, spacing: 5) {
            if !continuesPreviousTurn {
                MeetingLiveSpeakerHeader(name: session.hasSpeakerSignal ? session.liveSpeakerName : "Detecting…",
                                         index: session.liveSpeakerIndex,
                                         seconds: session.currentSegmentStartTimestamp,
                                         isRTL: rtl)
            }
            // Drawn like a committed card — see `MeetingLiveTailText`.
            MeetingLiveTailText(text: text, isRTL: rtl)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).fill(Color(hex: "14142B")))
        .overlay(alignment: rtl ? .trailing : .leading) {
            Rectangle().fill(speakerColor(for: session.liveSpeakerIndex).opacity(0.32)).frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: cardRadius, style: .continuous).strokeBorder(Color(hex: "5B6CF7").opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        // Follow the live edge when the bubble gets taller (a new line), not on every word.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, _ in onGrow() }
    }
}

struct MeetingLiveSpeakerHeader: View {
    let name: String
    let index: Int
    let seconds: Double
    let isRTL: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(speakerColor(for: index)).frame(width: 6, height: 6)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(speakerColor(for: index))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.format(seconds))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.28))
                .monospacedDigit()
        }
        .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
