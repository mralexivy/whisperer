//
//  DictationStreamView.swift
//  Whisperer
//
//  Word-by-word "pour" renderer for live dictation — settling tail + kinetic caret.
//

import SwiftUI

/// Renders live dictation as one view per word so each can arrive on its own.
///
/// The LTR path only. RTL keeps going through `TranscriptionTextView` (`NSTextField`), because
/// SwiftUI cannot set paragraph base writing direction and because the word-reveal animation is
/// deliberately skipped for RTL — revealing logical word order moves the insertion edge
/// unpredictably. See ARCHITECTURE.md.
///
/// A single `Text` cannot do any of this: per-word opacity is possible in an attributed string,
/// but a per-word transform is not, and a caret that glides to wherever the last glyph landed
/// needs that glyph to be a view with a frame.
struct DictationStreamView: View {
    let words: [String]
    /// True while words are still arriving. Drives both the settling tail and the caret's mode.
    let isStreaming: Bool
    let scale: CGFloat
    /// Typography is a parameter because the two surfaces that use this renderer are different
    /// sizes: the dictation HUD is a 16pt rounded display face, the meeting bubble is 14pt at the
    /// body weight the committed cards beside it already use. Everything else — spacing, caret
    /// height, rise distance — derives from this, so a caller sets one number.
    var fontSize: CGFloat = 16
    var fontDesign: Font.Design = .rounded
    /// Shown in place of the words when there are none. `nil` renders a bare caret, which is what
    /// the meeting bubble wants — its own empty state is a sonar dot one level up.
    var placeholder: String? = "Listening…"

    // MARK: Tail

    /// How many trailing words are still settling.
    ///
    /// **This is a recency cue, not a volatility claim.** The spec this is built from calls the
    /// dim tail "ghost text" meaning "the model may still revise these words", and for whisper.cpp
    /// that is literally true — the tiny preview model's tail is replaced by the main model at
    /// chunk handoff. For Nemotron it is false: RNNT decoding is monotonic, every partial is a
    /// strict prefix-extension of the last, and no word is ever retracted
    /// (`StreamingNemotronMultilingualAsrManager+Pipeline.swift`). A hard grey/black cliff would
    /// therefore be asserting something untrue on the backend most users are on, and
    /// `MeetingLiveTranscriptView` already records what that looks like: a dimmed tail reads as a
    /// rendering fault, not as "this may change".
    ///
    /// So the tail is graded rather than binary — a trail behind the caret that resolves over four
    /// words — and it resolves fully to ink whenever `isStreaming` goes false. It says "these just
    /// landed", which is true of every backend.
    private static let tailWindow = 4
    /// Opacity of the word under the caret. Above `TranscriptionTextView`'s floor deliberately:
    /// the tail must stay comfortably readable, since it is the part the user is checking.
    private static let tailFloor: Double = 0.5
    /// Settled text. Matches `TranscriptionTextView`'s `white.withAlphaComponent(0.9)` so the two
    /// renderers (LTR here, RTL there) are the same weight on screen.
    private static let inkOpacity: Double = 0.9

    // MARK: Render window

    /// Cap on how many words are rendered as individual views.
    ///
    /// `DictationFlowLayout` measures every subview on every pass, and a pass runs on each word
    /// append — so unbounded views make append O(n) and the whole recording O(n²). A 5-minute
    /// dictation is ~700 words, which would stutter the HUD; the card shows ~12 lines at its
    /// 340pt maximum, so 200 words is several screens of scrollback and still a fixed cost.
    /// `displayedText` keeps the full transcript for accessibility, and the finished text comes
    /// from the transcriber rather than from anything on screen.
    private static let renderWindow = 200

    /// Absolute indices, so a word keeps its identity when the window slides off the front.
    /// With positional identity the survivors would all re-appear — and re-run their entrance —
    /// every time the oldest word was dropped.
    private var visibleWords: [(index: Int, word: String)] {
        let start = max(0, words.count - Self.renderWindow)
        return (start..<words.count).map { (index: $0, word: words[$0]) }
    }

    private func opacity(forIndex index: Int) -> Double {
        guard isStreaming else { return Self.inkOpacity }
        let distance = words.count - 1 - index
        guard distance < Self.tailWindow else { return Self.inkOpacity }
        let progress = Double(distance) / Double(Self.tailWindow)
        return Self.tailFloor + (Self.inkOpacity - Self.tailFloor) * progress
    }

    var body: some View {
        DictationFlowLayout(spacing: 4.5 * scale, lineSpacing: 5 * scale) {
            if words.isEmpty {
                if let placeholder {
                    // Placeholder shares the flow layout so the caret sits after it exactly as it
                    // would after a real word — no separate empty-state branch to keep in sync.
                    Text(placeholder)
                        .font(.system(size: fontSize * scale, weight: .regular, design: fontDesign))
                        .foregroundColor(.white.opacity(0.32))
                }
            } else {
                ForEach(visibleWords, id: \.index) { item in
                    StreamWord(
                        text: item.word,
                        opacity: opacity(forIndex: item.index),
                        scale: scale,
                        fontSize: fontSize,
                        fontDesign: fontDesign
                    )
                }
            }

            KineticCaret(isStreaming: isStreaming, scale: scale, fontSize: fontSize)
        }
        // Animating the layout — not the words — is what makes the caret glide to its new x
        // instead of teleporting, so a word appears to pour out from behind it.
        .animation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.14), value: words.count)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - One word

private struct StreamWord: View {
    let text: String
    let opacity: Double
    let scale: CGFloat
    let fontSize: CGFloat
    let fontDesign: Font.Design

    @State private var poured = false

    var body: some View {
        Text(text)
            .font(.system(size: fontSize * scale, weight: .regular, design: fontDesign))
            // Settle is a colour change, never a font change. Italicising or re-weighting the
            // tail would alter its metrics, so every word would re-measure on settling — the
            // layout shift this whole design exists to avoid.
            .foregroundColor(.white.opacity(opacity))
            .animation(.easeOut(duration: 0.32), value: opacity)
            // Entrance. Separate from the settle above so a word that arrives already-settled
            // (a long burst can push one past the tail window within a frame) still pours.
            //
            // Opacity + translate + scale, and deliberately no blur: a blur is an offscreen
            // filter pass that stays attached at radius 0 once the animation finishes, so a
            // few hundred settled words would each keep one. `scaleEffect` is a transform,
            // costs nothing at identity, and gives the same "focusing in" read.
            .opacity(poured ? 1 : 0)
            .scaleEffect(poured ? 1 : 0.94, anchor: .bottomLeading)
            .offset(y: poured ? 0 : 4 * scale)
            .onAppear {
                withAnimation(.timingCurve(0.25, 1, 0.5, 1, duration: 0.12)) { poured = true }
            }
    }
}

// MARK: - Caret

/// Solid and leading the text while words arrive; a slow breathing pulse once they stop, which
/// is the only thing on screen still saying "listening" during a pause.
private struct KineticCaret: View {
    let isStreaming: Bool
    let scale: CGFloat
    let fontSize: CGFloat

    @State private var pulse = false

    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)   // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965) // #8B5CF6

    var body: some View {
        RoundedRectangle(cornerRadius: 1 * scale, style: .continuous)
            .fill(
                LinearGradient(colors: [blueAccent, purpleAccent],
                               startPoint: .top,
                               endPoint: .bottom)
            )
            .frame(width: 2 * scale, height: fontSize * 1.06 * scale)
            // A single view, so the bloom is one filter for the whole card — the one place a
            // glow is affordable, and the thing that makes the caret read as a light source
            // the words pour out from rather than as a rectangle.
            .shadow(color: blueAccent.opacity(isStreaming ? 0.55 : 0.18), radius: 4 * scale)
            .opacity(isStreaming ? 1.0 : (pulse ? 0.9 : 0.2))
            .scaleEffect(y: isStreaming ? 1.0 : (pulse ? 1.0 : 0.86), anchor: .bottom)
            .onAppear { startPulse() }
            .onChange(of: isStreaming) { streaming in
                if streaming {
                    // Ends the repeating animation — a repeatForever keeps running otherwise,
                    // and would re-assert itself the moment the opacity ternary flips back.
                    withAnimation(.easeOut(duration: 0.12)) { pulse = false }
                } else {
                    startPulse()
                }
            }
    }

    private func startPulse() {
        guard !isStreaming else { return }
        pulse = false
        withAnimation(.easeInOut(duration: 1.05).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }
}

// MARK: - Self-contained live text

/// Live text that pours word by word, for callers that have a growing `String` and no updater.
///
/// The dictation HUD drives `DictationStreamView` from the `SmoothTextUpdater` it already owns
/// (it needs `displayedText` for other things). Anywhere else — the meeting live bubble — only has
/// the string, so the pacing engine is bundled in here rather than re-derived at each call site.
///
/// **Re-create it with `.id(...)` to start a fresh pour.** The projection inside the updater is
/// append-only by design: a target with fewer words than are already displayed is ignored, which
/// is correct for an ASR revision and wrong for a genuine reset. Identity is how a caller says
/// "this is a different piece of text now", and it is the only reset this view has.
struct LivePourText: View {
    let text: String
    var fontSize: CGFloat = 16
    var fontDesign: Font.Design = .rounded
    var placeholder: String?

    @StateObject private var updater = SmoothTextUpdater()

    var body: some View {
        DictationStreamView(
            words: updater.words,
            isStreaming: updater.isActive,
            scale: 1,
            fontSize: fontSize,
            fontDesign: fontDesign,
            placeholder: placeholder
        )
        .onAppear { updater.setTarget(text) }
        .onChange(of: text) { _, newValue in updater.setTarget(newValue) }
        .onDisappear { updater.stop() }
    }
}

// MARK: - Flow layout

/// Left-to-right wrapping run of subviews, bottom-aligned within each line so the caret sits on
/// the text baseline. `HStack` cannot wrap and `Text` concatenation gives no per-word frames.
struct DictationFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        let lines = self.lines(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? (lines.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let lines = self.lines(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + line.height - item.size.height),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var result: [Line] = []
        var current = Line()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width

            if !current.items.isEmpty && projected > maxWidth {
                result.append(current)
                current = Line()
                current.items = [(index, size)]
                current.width = size.width
                current.height = size.height
            } else {
                current.items.append((index, size))
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty { result.append(current) }
        return result
    }
}
