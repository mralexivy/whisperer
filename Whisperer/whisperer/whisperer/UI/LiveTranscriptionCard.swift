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
    @StateObject private var typewriter = TypewriterAnimator()
    @State private var isPulsing = false
    @State private var showCursor = true
    @State private var cursorTimer: Timer?
    @Environment(\.colorScheme) var colorScheme

    // Colors
    private var cardBackground: Color {
        colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.98)
    }

    private var dividerColor: Color {
        colorScheme == .dark ? Color(white: 0.25) : Color(white: 0.88)
    }

    private let greenAccent = Color(red: 0.0, green: 0.82, blue: 0.42)  // #00D26A

    var body: some View {
        VStack(spacing: 0) {
            // Main card content
            VStack(spacing: 0) {
                // Header: Pulsing dot + "LIVE TRANSCRIPTION"
                HStack(spacing: 8) {
                    Circle()
                        .fill(greenAccent)
                        .frame(width: 8, height: 8)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                        .opacity(isPulsing ? 0.8 : 1.0)

                    Text("LIVE TRANSCRIPTION")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(greenAccent)
                        .tracking(0.8)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

                // Thin divider below header
                Rectangle()
                    .fill(dividerColor)
                    .frame(height: 0.5)

                // Text area with typewriter effect
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(highlightedDisplayText)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(.primary)
                            .lineSpacing(5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .id("textEnd")
                    }
                    .onChange(of: typewriter.displayedText) { _ in
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
                    .shadow(
                        color: .black.opacity(colorScheme == .dark ? 0.5 : 0.12),
                        radius: 16,
                        x: 0,
                        y: 6
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(dividerColor, lineWidth: 0.5)
            )

            // Speech bubble arrow pointing down to HUD
            SpeechBubbleArrow(color: cardBackground, borderColor: dividerColor)
                .frame(width: 20, height: 10)
        }
        .frame(width: 380)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live transcription")
        .accessibilityValue(typewriter.displayedText.isEmpty ? "Listening..." : typewriter.displayedText)
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

            // Initialize typewriter with current text
            typewriter.setTarget(appState.liveTranscription)
        }
        .onDisappear {
            cursorTimer?.invalidate()
            cursorTimer = nil
            typewriter.stop()
        }
        .onChange(of: appState.liveTranscription) { newText in
            typewriter.setTarget(newText)
        }
    }

    // Highlighted displayed text with blinking cursor
    private var highlightedDisplayText: AttributedString {
        let text = typewriter.displayedText
        var attributed = KeywordHighlighter.highlight(text)

        // Add blinking cursor at the end
        if showCursor {
            var cursor = AttributedString("|")
            cursor.foregroundColor = .primary
            attributed.append(cursor)
        } else {
            var space = AttributedString(" ")
            space.foregroundColor = .clear
            attributed.append(space)
        }

        return attributed
    }
}

// MARK: - Typewriter Animator

class TypewriterAnimator: ObservableObject {
    @Published var displayedText: String = ""

    private var targetText: String = ""
    private var targetWords: [String] = []
    private var displayedWordCount: Int = 0
    private var timer: Timer?

    // Speed: delay between words (in seconds)
    private let wordDelay: TimeInterval = 0.06

    func setTarget(_ text: String) {
        // If text is shorter (correction/reset), update immediately
        if text.count < targetText.count || text.isEmpty {
            targetText = text
            targetWords = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
            displayedWordCount = targetWords.count
            displayedText = text
            return
        }

        // Find new words to animate
        let newWords = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)

        // If we have more words than before, animate the new ones
        if newWords.count > targetWords.count {
            let previousCount = targetWords.count
            targetText = text
            targetWords = newWords

            // Start animating from where we left off
            if timer == nil {
                displayedWordCount = previousCount
                startAnimation()
            }
        } else {
            // Same word count but text changed (within-word change)
            targetText = text
            targetWords = newWords
            displayedWordCount = newWords.count
            displayedText = text
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: wordDelay, repeats: true) { [weak self] _ in
            self?.animateNextWord()
        }
    }

    private func animateNextWord() {
        guard displayedWordCount < targetWords.count else {
            timer?.invalidate()
            timer = nil
            return
        }

        displayedWordCount += 1
        let wordsToShow = targetWords.prefix(displayedWordCount)
        displayedText = wordsToShow.joined(separator: " ")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
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
