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
    @StateObject private var textUpdater = SmoothTextUpdater()
    @State private var isPulsing = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?

    // Dark navy palette — always dark, matches workspace & onboarding
    private let cardBackground = Color(red: 0.078, green: 0.078, blue: 0.169)     // #14142B
    private let dividerColor = Color.white.opacity(0.06)
    private let blueAccent = Color(red: 0.357, green: 0.424, blue: 0.969)          // #5B6CF7
    private let purpleAccent = Color(red: 0.545, green: 0.361, blue: 0.965)        // #8B5CF6

    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            VStack(spacing: 0) {
                // Header: Gradient pulsing dot + "LIVE TRANSCRIPTION"
                HStack(spacing: 8) {
                    ZStack {
                        // Glow ring
                        Circle()
                            .fill(blueAccent.opacity(isPulsing ? 0.25 : 0.0))
                            .frame(width: 16, height: 16)

                        // Gradient dot
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [blueAccent, purpleAccent],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 8, height: 8)
                            .scaleEffect(isPulsing ? 1.2 : 1.0)
                    }

                    Text("LIVE TRANSCRIPTION")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [blueAccent, purpleAccent],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .tracking(1.2)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

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

                // Text area with typewriter effect
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(highlightedDisplayText)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundColor(.white.opacity(0.9))
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .id("textEnd")
                    }
                    .onChange(of: textUpdater.displayedText) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("textEnd", anchor: .bottom)
                        }
                    }
                }
                .frame(height: 72)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(purpleAccent.opacity(0.15), lineWidth: 1)
            )

            // Speech bubble arrow pointing down to HUD
            SpeechBubbleArrow(color: cardBackground, borderColor: purpleAccent.opacity(0.15))
                .frame(width: 20, height: 10)
        }
        .frame(width: 380)
        .tahoeTextFix()
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
            textUpdater.setTarget(appState.liveTranscription)
        }
        .onDisappear {
            cursorTimer?.invalidate()
            cursorTimer = nil
            textUpdater.stop()
        }
        .onChange(of: appState.liveTranscription) { newText in
            textUpdater.setTarget(newText)
        }
    }

    // Highlighted displayed text with blinking cursor or "Listening..." placeholder
    private var highlightedDisplayText: AttributedString {
        let text = textUpdater.displayedText

        // Show placeholder while waiting for first transcription
        if text.isEmpty {
            var listening = AttributedString("Listening...")
            listening.foregroundColor = .white.opacity(0.35)
            return listening
        }

        var attributed = KeywordHighlighter.highlight(text)

        // Add blinking cursor at the end
        if showCursor {
            var cursor = AttributedString("|")
            cursor.foregroundColor = Color(red: 0.357, green: 0.424, blue: 0.969)  // blueAccent
            attributed.append(cursor)
        } else {
            var space = AttributedString(" ")
            space.foregroundColor = .clear
            attributed.append(space)
        }

        return attributed
    }
}

// MARK: - Smooth Text Updater

/// Word-by-word dictation animation. Whisper returns chunks of 3-7 words
/// every 1-1.5s. Instead of showing all words at once, this queues them and
/// reveals one word at a time at 60ms intervals — creating the effect of
/// words being typed as you speak.
class SmoothTextUpdater: ObservableObject {
    @Published var displayedText: String = ""

    /// What the display will eventually show (displayed + pending words)
    private var committedText: String = ""
    private var pendingWords: [String] = []
    private var animationTimer: Timer?
    private let wordInterval: TimeInterval = 0.06  // 60ms per word

    func setTarget(_ text: String) {
        let newText = text.trimmingCharacters(in: .whitespaces)

        // Empty text = new recording, reset
        if newText.isEmpty {
            animationTimer?.invalidate()
            animationTimer = nil
            pendingWords.removeAll()
            displayedText = ""
            committedText = ""
            return
        }

        // Already committed this exact text
        guard newText != committedText else { return }

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
            // Text changed fundamentally (e.g., reset) — show immediately
            animationTimer?.invalidate()
            animationTimer = nil
            pendingWords.removeAll()
            displayedText = newText
            committedText = newText
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

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        pendingWords.removeAll()
        committedText = ""
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
