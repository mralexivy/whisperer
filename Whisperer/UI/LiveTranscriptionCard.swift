//
//  LiveTranscriptionCard.swift
//  Whisperer
//
//  Live transcription card displayed above the HUD:
//  - Header with pulsing dot + "LIVE TRANSCRIPTION"
//  - Text area with typewriter word-by-word animation
//  - Speech bubble arrow pointing to HUD below
//

import SwiftUI
import Combine

struct LiveTranscriptionCard: View {
    @ObservedObject var appState: AppState
    @Environment(\.overlayScale) private var scale
    @StateObject private var textUpdater = SmoothTextUpdater()
    @State private var isPulsing = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?

    @State private var isTextRTL: Bool = false
    @State private var isExpanded: Bool = false
    @State private var isExpandHovered: Bool = false
    @State private var scrollIndicatorOpacity: Double = 0
    @State private var scrollIndicatorTimer: Timer?
    @State private var contentHeight: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    private let minimizedHeight: CGFloat = 72
    private let maxExpandedHeight: CGFloat = 340

    // Dark navy palette — always dark, matches workspace & onboarding
    private let cardBackground = Color(red: 0.078, green: 0.078, blue: 0.169)     // #14142B
    private let dividerColor = Color.white.opacity(0.06)
    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)          // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)        // #8B5CF6

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Tooltip layer (outside card clipping)
            if isExpandHovered {
                VStack(spacing: 0) {
                    Text(isExpanded ? "Collapse transcript" : "Expand transcript")
                        .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12 * scale)
                        .padding(.vertical, 6 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: 8 * scale)
                                .fill(Color(red: 0.08, green: 0.08, blue: 0.16))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8 * scale)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                        )

                    // Arrow pointing down
                    TooltipArrow(direction: .down, color: Color(red: 0.08, green: 0.08, blue: 0.16), borderColor: Color.white.opacity(0.12))
                        .frame(width: 12 * scale, height: 6 * scale)
                }
                .offset(x: -8 * scale, y: -38 * scale)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isExpandHovered)
                .zIndex(100)
            }

            VStack(spacing: 0) {
                // Main card content
                VStack(spacing: 0) {
                    // Header: Gradient pulsing dot + "LIVE TRANSCRIPTION"
                HStack(spacing: 8 * scale) {
                    ZStack {
                        Circle()
                            .fill(blueAccent.opacity(isPulsing ? 0.25 : 0.0))
                            .frame(width: 16 * scale, height: 16 * scale)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [blueAccent, purpleAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 8 * scale, height: 8 * scale)
                            .scaleEffect(isPulsing ? 1.2 : 1.0)
                    }

                    Text("LIVE TRANSCRIPTION")
                        .font(.system(size: 11 * scale, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [blueAccent, purpleAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .tracking(1.2)

                    Spacer()

                    // Hands-free badge in header (persistent while hands-free is active)
                    if appState.isHandsFreeRecording {
                        HStack(spacing: 4 * scale) {
                            Circle()
                                .fill(blueAccent)
                                .frame(width: 5 * scale, height: 5 * scale)

                            Text("HANDS-FREE")
                                .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundColor(blueAccent)
                        }
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 3 * scale)
                        .background(
                            Capsule()
                                .fill(blueAccent.opacity(0.12))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }

                    #if !APP_STORE
                    // AI mode badge (persistent while rewrite mode is active)
                    if appState.activeMode == .rewrite, let modeName = appState.activeAIModeName {
                        HStack(spacing: 4 * scale) {
                            Circle()
                                .fill(purpleAccent)
                                .frame(width: 5 * scale, height: 5 * scale)

                            Text(modeName.uppercased())
                                .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                                .tracking(0.8)
                                .foregroundColor(purpleAccent)
                        }
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 3 * scale)
                        .background(
                            Capsule()
                                .fill(purpleAccent.opacity(0.12))
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                    #endif

                    // Expand/collapse toggle (rightmost element in header)
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isExpanded.toggle()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                            NotificationCenter.default.post(name: .overlayContentHeightChanged, object: nil)
                        }
                    }) {
                        Image(systemName: isExpanded ? "chevron.down.2" : "chevron.up.2")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundColor(blueAccent.opacity(expandButtonOpacity))
                            .frame(width: 22 * scale, height: 22 * scale)
                            .background(
                                Circle()
                                    .fill(blueAccent.opacity(isExpandHovered ? 0.15 : 0.0))
                            )
                            .scaleEffect(isExpandHovered ? 1.08 : 1.0)
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isExpandHovered)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.15)) {
                            isExpandHovered = hovering
                        }
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
                .padding(.horizontal, 20 * scale)
                .padding(.top, 14 * scale)
                .padding(.bottom, 10 * scale)

                // Gradient divider below header
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [blueAccent.opacity(0.3), purpleAccent.opacity(0.3), Color.clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 0.5)

                // Text area. Two renderers, one for each writing direction:
                //   LTR — DictationStreamView, one view per word so each can pour in behind a
                //         caret that glides to meet it.
                //   RTL — TranscriptionTextView (NSTextField), the only thing that can set
                //         paragraph base writing direction, and the direction whose reveal
                //         animation is deliberately skipped anyway (see ARCHITECTURE.md).
                let cardHeight: CGFloat = isExpanded
                    ? min(max(contentHeight, minimizedHeight * scale), maxExpandedHeight * scale)
                    : minimizedHeight * scale
                let trackInset: CGFloat = 10 * scale
                let trackHeight: CGFloat = cardHeight - trackInset * 2
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Group {
                            if isTextRTL {
                                TranscriptionTextView(text: rtlDisplayText, isRTL: true, scale: scale)
                            } else {
                                DictationStreamView(
                                    words: textUpdater.words,
                                    isStreaming: textUpdater.isActive,
                                    scale: scale
                                )
                            }
                        }
                            .padding(.horizontal, 20 * scale)
                            .padding(.vertical, 14 * scale)
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(key: ContentHeightKey.self, value: geo.size.height)
                                        .preference(key: ScrollOffsetKey.self, value: -geo.frame(in: .named("transcriptScroll")).origin.y)
                                }
                            )
                            .id("textEnd")
                    }
                    .coordinateSpace(name: "transcriptScroll")
                    .onPreferenceChange(ContentHeightKey.self) { height in
                        contentHeight = height
                        if height > cardHeight { flashScrollIndicator() }
                    }
                    .onPreferenceChange(ScrollOffsetKey.self) { offset in
                        scrollOffset = offset
                    }
                    .onChange(of: textUpdater.displayedText) { _ in
                        proxy.scrollTo("textEnd", anchor: .bottom)
                        if contentHeight > cardHeight { flashScrollIndicator() }
                    }
                }
                .frame(height: cardHeight)
                .animation(.easeInOut(duration: 0.25), value: isExpanded)
                .overlay(alignment: isTextRTL ? .leading : .trailing) {
                    minimalScrollbar(cardHeight: cardHeight, trackHeight: trackHeight, rtl: isTextRTL)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14 * scale)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14 * scale)
                    .stroke(purpleAccent.opacity(0.15), lineWidth: 1)
            )

            // Speech bubble arrow pointing down to HUD
            SpeechBubbleArrow(color: cardBackground, borderColor: purpleAccent.opacity(0.15))
                .frame(width: 20 * scale, height: 10 * scale)
        }
        .frame(width: 380 * scale)
        .id(appState.recordingSessionID)  // Force full state reset between recordings
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcription")
        .accessibilityValue(textUpdater.displayedText.isEmpty ? "Listening..." : textUpdater.displayedText)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            // Start pulsing animation
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isPulsing = true
            }

            syncCursorTimer()

            // Initialize with current text
            textUpdater.setTarget(appState.liveTranscription, rtl: isTextRTL)
        }
        .onDisappear {
            cursorTimer?.invalidate()
            cursorTimer = nil
            textUpdater.stop()
        }
        .onChange(of: appState.liveTranscription) { newText in
            if newText.isEmpty {
                isTextRTL = false  // Reset for new recording
            } else {
                isTextRTL = Self.detectRTL(in: newText)
            }
            textUpdater.setTarget(newText, rtl: isTextRTL)
            syncCursorTimer()
        }
        .onChange(of: contentHeight) { _ in
            if isExpanded {
                NotificationCenter.default.post(name: .overlayContentHeightChanged, object: nil)
            }
        }
        }  // Close ZStack
    }

    /// Detect RTL from text content — checks first 50 chars for Hebrew/Arabic script
    private static func detectRTL(in text: String) -> Bool {
        let sample = text.prefix(50)
        var rtlCount = 0
        var letterCount = 0
        for scalar in sample.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isAlphabetic { letterCount += 1 }
            if (v >= 0x0590 && v <= 0x05FF) ||  // Hebrew
               (v >= 0x0600 && v <= 0x06FF) ||  // Arabic
               (v >= 0x0700 && v <= 0x074F) ||  // Syriac
               (v >= 0xFB50 && v <= 0xFDFF) ||  // Arabic Presentation Forms-A
               (v >= 0xFE70 && v <= 0xFEFF) {   // Arabic Presentation Forms-B
                rtlCount += 1
            }
        }
        guard letterCount > 0 else { return false }
        return Double(rtlCount) / Double(letterCount) > 0.3
    }

    private var expandButtonOpacity: Double {
        if isExpandHovered { return 1.0 }
        return contentHeight > minimizedHeight * scale ? 0.7 : 0.3
    }

    @ViewBuilder
    private func minimalScrollbar(cardHeight: CGFloat, trackHeight: CGFloat, rtl: Bool = false) -> some View {
        if contentHeight > cardHeight {
            let thumbRatio = min(1.0, cardHeight / contentHeight)
            let thumbH = max(14 * scale, trackHeight * thumbRatio)
            let scrollable = contentHeight - cardHeight
            let travel = trackHeight - thumbH
            let progress: CGFloat = (scrollable > 0 && scrollOffset > 1)
                ? min(1.0, max(0, scrollOffset / scrollable))
                : 1.0
            let thumbY = progress * travel

            ZStack(alignment: .top) {
                // Track
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(Color.white.opacity(scrollIndicatorOpacity * 0.06))
                    .frame(width: 2.5 * scale, height: trackHeight)

                // Thumb
                RoundedRectangle(cornerRadius: 1.5 * scale)
                    .fill(blueAccent.opacity(scrollIndicatorOpacity * 0.5))
                    .frame(width: 2.5 * scale, height: thumbH)
                    .offset(y: thumbY)
            }
            .padding(rtl ? .leading : .trailing, 6 * scale)
            .padding(.vertical, 10 * scale)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
        }
    }

    /// The blinking caret belongs to the RTL renderer only. Running its timer in LTR would
    /// re-evaluate the card body — and re-measure every word in `DictationFlowLayout` — twice a
    /// second to flip a flag nothing on that path reads.
    private func syncCursorTimer() {
        if isTextRTL {
            guard cursorTimer == nil else { return }
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
                showCursor.toggle()
            }
        } else {
            cursorTimer?.invalidate()
            cursorTimer = nil
        }
    }

    private func flashScrollIndicator() {
        withAnimation(.easeIn(duration: 0.15)) {
            scrollIndicatorOpacity = 1.0
        }
        scrollIndicatorTimer?.invalidate()
        scrollIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            withAnimation(.easeOut(duration: 0.4)) {
                scrollIndicatorOpacity = 0
            }
        }
    }

    /// RTL path only. The blinking `" |"` is an ASCII stand-in for a caret: it re-renders the
    /// whole `NSTextField` twice a second and can wrap onto its own line. The LTR path has a real
    /// one (`KineticCaret`) that costs no relayout, so this stays confined to the direction that
    /// cannot have it.
    private var rtlDisplayText: String {
        let text = textUpdater.displayedText
        if text.isEmpty { return "Listening…" }
        let cursor = showCursor && !textUpdater.isActive ? " |" : ""
        return text + cursor
    }
}

// MARK: - NSTextField-backed Transcription Text (guaranteed RTL paragraph direction)

/// Uses AppKit NSTextField with NSParagraphStyle.baseWritingDirection for reliable RTL.
/// SwiftUI Text does not expose paragraph base direction control — 6 attempts confirmed this.
/// NSTextField renders via Core Text directly. Updating attributedStringValue is O(1).
struct TranscriptionTextView: NSViewRepresentable {
    let text: String
    let isRTL: Bool
    let scale: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.truncatesLastVisibleLine = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let c = context.coordinator
        // Bail early when nothing changed — this runs 20+/sec during animation
        guard text != c.lastText || isRTL != c.lastIsRTL || scale != c.lastScale else { return }
        c.lastText = text
        c.lastIsRTL = isRTL
        c.lastScale = scale

        // Rebuild font + paragraph style only when layout inputs change (rare)
        if c.cachedFont == nil || isRTL != c.cachedIsRTL || scale != c.cachedScale {
            let fontSize = 16 * scale
            let resolvedFont: NSFont
            if let desc = NSFont.systemFont(ofSize: fontSize, weight: .regular).fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: desc, size: fontSize) {
                resolvedFont = rounded
            } else {
                resolvedFont = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5 * scale
            style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
            style.alignment = isRTL ? .right : .left
            c.cachedFont = resolvedFont
            c.cachedStyle = style
            c.cachedIsRTL = isRTL
            c.cachedScale = scale
        }

        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: c.cachedFont!,
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .paragraphStyle: c.cachedStyle!
            ]
        )
    }

    // Caches expensive objects across updateNSView calls
    final class Coordinator {
        var lastText: String = ""
        var lastIsRTL: Bool = false
        var lastScale: CGFloat = -1  // -1 forces first rebuild
        var cachedFont: NSFont?
        var cachedStyle: NSMutableParagraphStyle?
        var cachedIsRTL: Bool = false
        var cachedScale: CGFloat = -1
    }
}

// MARK: - Smooth Text Updater

/// Re-times batched ASR output into a word-at-a-time stream.
///
/// **The batch is an artefact of the encoder, not of the speech.** Nemotron emits a partial every
/// `NemotronBridge.chunkMs` (1120ms) and whisper.cpp finalizes a VAD chunk every 1–2s, so text
/// arrives as 3–7 words at once — but those words were *spoken* spread across that same period.
/// Printing them together and then going quiet is the block-delivery artefact: the UI alternates
/// between a dump and dead air, and neither moment resembles dictation.
///
/// So the queue is drained at the rate the words were produced: the backlog is spread across the
/// measured interval between arrivals, so a word surfaces roughly when it was said. The result is
/// continuous — something is always moving, and the next batch lands just as the last one finishes.
class SmoothTextUpdater: ObservableObject {
    @Published var displayedText: String = ""

    /// The same content as `displayedText`, already split — `DictationStreamView` renders one view
    /// per element so each word can arrive with its own fade+slide. Kept in lockstep rather than
    /// derived in the view: splitting a growing string on every published change is O(n) per word.
    @Published private(set) var words: [String] = []

    /// True when words are being animated or text was recently updated
    @Published var isActive: Bool = false

    /// What the display will eventually show (displayed + pending words)
    private var committedText: String = ""
    private var pendingWords: [String] = []
    private var animationTimer: Timer?
    private var idleTimer: Timer?
    private var isRTL: Bool = false

    // MARK: Pacing

    /// Seeded to Nemotron's partial cadence and re-estimated from real arrivals, so the same code
    /// paces whisper.cpp's VAD chunks (irregular, typically 1–2s) and the 500ms preview pass.
    private var arrivalPeriod: TimeInterval = 1.12
    private var lastArrivalAt: Date?
    /// Interval for the batch currently draining. Held for the whole batch rather than recomputed
    /// per word: recomputing makes the interval grow as the queue shrinks, so a phrase would
    /// visibly decelerate into its own tail and overrun the next arrival.
    private var currentWordInterval: TimeInterval = 0.18

    /// Fraction of the arrival period a batch is given to pour. Under 1.0 so jitter can never
    /// accumulate backlog — each batch finishes a little before the next is due.
    private let pourDutyCycle: Double = 0.8
    /// Floor. Below this the reveal stops reading as words arriving and starts reading as a flush.
    private let minWordInterval: TimeInterval = 0.035
    /// Ceiling, ≈175 wpm. A lone word must not hang around for most of a second waiting out a
    /// period it does not need.
    private let maxWordInterval: TimeInterval = 0.34

    func setTarget(_ text: String, rtl: Bool = false) {
        let newText = text.trimmingCharacters(in: .whitespaces)
        isRTL = rtl

        // Empty text = new recording, reset
        if newText.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
            idleTimer?.invalidate()
            idleTimer = nil
            pendingWords.removeAll()
            displayedText = ""
            words = []
            committedText = ""
            isActive = false
            arrivalPeriod = 1.12
            lastArrivalAt = nil
            return
        }

        // Already committed this exact text
        guard newText != committedText else { return }

        // ASR hypotheses revise punctuation and occasionally an earlier word. Replacing
        // the target makes the whole NSTextField blink. The live UI is intentionally a
        // monotonic projection: preserve every visible/planned word and enqueue only
        // candidate words beyond the current word count. The accurate final result is
        // still used for insertion after recording stops.
        let committedWordCount = committedText.split(whereSeparator: { $0.isWhitespace }).count
        let candidateWords = newText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard candidateWords.count > committedWordCount else { return }

        let appendedWords = Array(candidateWords.dropFirst(committedWordCount))
        guard !appendedWords.isEmpty else { return }
        markActive()
        let suffix = appendedWords.joined(separator: " ")
        committedText = committedText.isEmpty ? suffix : committedText + " " + suffix

        // RTL should remain immediate because animating logical word order can move the
        // insertion edge unpredictably, but it follows the same append-only contract.
        if rtl {
            animationTimer?.invalidate()
            animationTimer = nil
            pendingWords.removeAll()
            displayedText = committedText
            words = committedText.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return
        }

        noteArrival()
        pendingWords.append(contentsOf: appendedWords)
        repaceCurrentBatch()
        startAnimation()
    }

    // MARK: - Pacing

    /// Exponential moving average of the gap between arrivals. Bounded because the first partial
    /// of a recording follows model warm-up rather than a chunk boundary, and a long silence is a
    /// pause in speech, not evidence that the encoder slowed down.
    private func noteArrival() {
        let now = Date()
        defer { lastArrivalAt = now }
        guard let last = lastArrivalAt else { return }
        let delta = now.timeIntervalSince(last)
        guard delta > 0.2, delta < 2.5 else { return }
        arrivalPeriod = arrivalPeriod * 0.6 + delta * 0.4
    }

    private func repaceCurrentBatch() {
        let count = max(1, pendingWords.count)
        let spread = (arrivalPeriod * pourDutyCycle) / Double(count)
        currentWordInterval = min(maxWordInterval, max(minWordInterval, spread))
    }

    private func startAnimation() {
        // Already draining — the running timer picks up whatever was just appended, at the
        // interval `repaceCurrentBatch()` just recomputed for the combined queue.
        guard animationTimer == nil else { return }

        // First word of a batch lands immediately. Everything after it is paced; this one is
        // the app answering, and the answer should not wait on a schedule.
        showNextWord()
        scheduleNextWord()
    }

    /// One-shot and self-rescheduling rather than a repeating timer, so a mid-batch arrival can
    /// change the cadence at the next word instead of at the next batch.
    private func scheduleNextWord() {
        guard !pendingWords.isEmpty else {
            animationTimer = nil
            return
        }
        let timer = Timer(timeInterval: currentWordInterval, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.showNextWord()
            self.scheduleNextWord()
        }
        // `.common`, so the pour keeps its rhythm while the overlay panel animates its frame —
        // in `.default` the run loop switches modes and the stream visibly stalls mid-phrase.
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func showNextWord() {
        guard !pendingWords.isEmpty else { return }
        let word = pendingWords.removeFirst()
        words.append(word)
        if displayedText.isEmpty {
            displayedText = word
        } else {
            displayedText += " " + word
        }
        // Re-armed per word, not per arrival: the pour trails the batch that produced it, and
        // the tail should settle to ink relative to the last word the user actually saw.
        markActive()
    }

    private func markActive() {
        // Guarded: this runs on every poured word, and an unconditional write would publish a
        // change — re-evaluating the card body — for a value that is already true.
        if !isActive { isActive = true }
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        pendingWords.removeAll()
        committedText = ""
        lastArrivalAt = nil
    }
}

// MARK: - Content Height Preference Key

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Speech Bubble Arrow

struct SpeechBubbleArrow: View {
    let color: Color
    let borderColor: Color

    var body: some View {
        ZStack {
            // Fill (covers the card bottom border)
            Triangle()
                .fill(color)
                .offset(y: -0.5)

            // Border on left and right edges only
            TriangleBorder()
                .stroke(borderColor, lineWidth: 0.5)
                .offset(y: -0.5)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct TriangleBorder: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Only the two diagonal edges, not the top
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

#Preview {
    VStack(spacing: 8) {
        LiveTranscriptionCard(appState: {
            let state = AppState.shared
            state.liveTranscription = "The quarterly report shows significant growth in our enterprise segment, with a 47% increase in recurring revenue"
            return state
        }())

        // Simulated HUD below
        RoundedRectangle(cornerRadius: 25)
            .fill(Color(white: 0.15))
            .frame(width: 340, height: 54)
    }
    .padding(40)
    .background(Color.black)
}
