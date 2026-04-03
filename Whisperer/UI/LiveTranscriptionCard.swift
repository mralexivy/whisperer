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

                // Text area — NSTextField for guaranteed RTL paragraph direction
                let cardHeight: CGFloat = isExpanded
                    ? min(max(contentHeight, minimizedHeight * scale), maxExpandedHeight * scale)
                    : minimizedHeight * scale
                let trackInset: CGFloat = 10 * scale
                let trackHeight: CGFloat = cardHeight - trackInset * 2
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        TranscriptionTextView(text: displayText, isRTL: isTextRTL, scale: scale)
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

            // Start cursor blinking (invalidate any existing timer first)
            cursorTimer?.invalidate()
            cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { _ in
                showCursor.toggle()
            }

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

    /// Plain string display
    private var displayText: String {
        let text = textUpdater.displayedText
        if text.isEmpty { return "Listening..." }
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
        let fontSize = 16 * scale
        let font: NSFont
        if let roundedDesc = NSFont.systemFont(ofSize: fontSize, weight: .regular)
            .fontDescriptor.withDesign(.rounded),
           let roundedFont = NSFont(descriptor: roundedDesc, size: fontSize) {
            font = roundedFont
        } else {
            font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        }

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5 * scale
        if isRTL {
            style.baseWritingDirection = .rightToLeft
            style.alignment = .right
        } else {
            style.baseWritingDirection = .leftToRight
            style.alignment = .left
        }

        field.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                .paragraphStyle: style
            ]
        )
    }
}

// MARK: - Smooth Text Updater

/// Word-by-word dictation animation. Whisper returns chunks of 3-7 words
/// every 1-1.5s. Instead of showing all words at once, this queues them and
/// reveals one word at a time at 60ms intervals — creating the effect of
/// words being typed as you speak.
class SmoothTextUpdater: ObservableObject {
    @Published var displayedText: String = ""

    /// True when words are being animated or text was recently updated
    @Published var isActive: Bool = false

    /// What the display will eventually show (displayed + pending words)
    private var committedText: String = ""
    private var pendingWords: [String] = []
    private var animationTimer: Timer?
    private var idleTimer: Timer?
    private let wordInterval: TimeInterval = 0.06  // 60ms per word
    private var isRTL: Bool = false

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
            committedText = ""
            isActive = false
            return
        }

        markActive()

        // Already committed this exact text
        guard newText != committedText else { return }

        // RTL: skip word-by-word animation — show immediately.
        if rtl {
            animationTimer?.invalidate()
            animationTimer = nil
            pendingWords.removeAll()
            displayedText = newText
            committedText = newText
            // plain String — no highlighting computation needed
            return
        }

        // New text extends what we've committed — queue the new words for animation
        if committedText.isEmpty || newText.hasPrefix(committedText) {
            let suffix: String
            if committedText.isEmpty {
                suffix = newText
            } else {
                suffix = String(newText.dropFirst(committedText.count))
                    .trimmingCharacters(in: .whitespaces)
            }

            let newWords = suffix.split(separator: " ").map(String.init)
            guard !newWords.isEmpty else { return }

            pendingWords.append(contentsOf: newWords)
            committedText = newText
            startAnimation()
        } else {
            // Text changed fundamentally (e.g., preview replace) — show immediately
            animationTimer?.invalidate()
            animationTimer = nil
            pendingWords.removeAll()
            displayedText = newText
            committedText = newText
            // plain String — no highlighting computation needed
        }
    }

    private func startAnimation() {
        // If timer is already running, new words are in the queue — it'll pick them up
        guard animationTimer == nil else { return }

        // Show first word immediately for responsiveness
        showNextWord()
        guard !pendingWords.isEmpty else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: wordInterval, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }

            self.showNextWord()

            if self.pendingWords.isEmpty {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
    }

    private func showNextWord() {
        guard !pendingWords.isEmpty else { return }
        let word = pendingWords.removeFirst()
        if displayedText.isEmpty {
            displayedText = word
        } else {
            displayedText += " " + word
        }
    }

    private func markActive() {
        isActive = true
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.isActive = false
        }
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        idleTimer?.invalidate()
        idleTimer = nil
        pendingWords.removeAll()
        committedText = ""
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
