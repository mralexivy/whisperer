//
//  PromptWordsSection.swift
//  Whisperer
//
//  Prompt words tab content for the Dictionary view
//

import SwiftUI

struct PromptWordsSection: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var appState = AppState.shared
    @State private var newWord = ""
    @State private var showLimitWarning = false

    private var tokenCountColor: Color {
        let count = appState.promptWordsTokenCount
        if count >= AppState.maxPromptWordsTokens { return .red }
        if count >= Int(Double(AppState.maxPromptWordsTokens) * 0.8) { return .orange }
        return .cyan
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                infoCard

                inputField

                if !appState.promptWords.isEmpty {
                    tokenCounter

                    wordPills
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .opacity(appState.promptWordsEnabled ? 1.0 : 0.4)
        .allowsHitTesting(appState.promptWordsEnabled)
        .animation(.easeInOut(duration: 0.2), value: appState.promptWordsEnabled)
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Info Card

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.cyan)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recognition Hints")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Add words and phrases to help Whisper recognize specific names, technical terms, or jargon during transcription. These are passed as context to the model before it processes your audio.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .lineSpacing(3)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cyan.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.cyan.opacity(0.1), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Input Field

    private var inputField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.cyan)

            TextField("Add word or phrase...", text: $newWord)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .onSubmit { addWord() }

            if !newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: { addWord() }) {
                    Text("Add")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(WhispererColors.accentGradient)
                        )
                }
                .buttonStyle(.plain).pointerOnHover()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(WhispererColors.elevatedBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .overlay(alignment: .trailing) {
            if showLimitWarning {
                Text("Limit reached")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }
        }
    }

    // MARK: - Token Counter

    private var tokenCounter: some View {
        HStack(spacing: 6) {
            Image(systemName: "number")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tokenCountColor)

            Text("\(appState.promptWordsTokenCount)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(tokenCountColor)

            Text("/ \(AppState.maxPromptWordsTokens) tokens used")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))

            Spacer()

            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.promptWords.removeAll()
                }
            }) {
                Text("Clear All")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))
            }
            .buttonStyle(.plain).pointerOnHover()
        }
    }

    // MARK: - Word Pills

    private var wordPills: some View {
        FlowLayout(spacing: 8) {
            ForEach(appState.promptWords, id: \.self) { word in
                wordPill(word)
            }
        }
    }

    private func wordPill(_ word: String) -> some View {
        HStack(spacing: 6) {
            Text(word)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.removePromptWord(word)
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            }
            .buttonStyle(.plain).pointerOnHover()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 2, y: 1)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.word.spacing")
                .font(.system(size: 28))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))

            Text("No prompt words yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text("Type a word or phrase above and press Enter to add it")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions

    private func addWord() {
        let success = appState.addPromptWord(newWord)
        if success {
            withAnimation(.easeInOut(duration: 0.15)) {
                newWord = ""
                showLimitWarning = false
            }
        } else if appState.promptWordsTokenCount >= AppState.maxPromptWordsTokens {
            withAnimation {
                showLimitWarning = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation { showLimitWarning = false }
            }
        }
    }
}
