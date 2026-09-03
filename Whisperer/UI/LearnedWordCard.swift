//
//  LearnedWordCard.swift
//  Whisperer
//
//  "Learned: Glean" — the moment the dictionary teaches itself, made visible.
//
//  This card is the whole feature as far as the user is concerned. Everything behind it is
//  machinery to make sure the word on this card is one worth learning; the card is what turns
//  it from a silent behaviour change into something the user chose to keep.
//
//  Undo is a peer of the dismiss button, not buried: rejecting a word is only cheap while the
//  user still remembers correcting it, and Undo also tombstones the pair so it is never
//  relearned.
//

import SwiftUI

struct LearnedWordCard: View {
    let entry: DictionaryEntry

    @State private var appeared = false
    @State private var isExiting = false
    @State private var undoHovering = false
    @State private var dismissHovering = false

    var body: some View {
        HStack(spacing: 12) {
            iconContainer

            VStack(alignment: .leading, spacing: 2) {
                Text("Learned: \(entry.correctForm)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                if let observed = entry.observedSource {
                    Text("heard as \(observed)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            Spacer(minLength: 12)

            undoButton
            dismissButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 10)
        .background(cardBackground)
        .fixedSize(horizontal: true, vertical: false)
        .scaleEffect(isExiting ? 0.96 : (appeared ? 1.0 : 0.94))
        .offset(y: isExiting ? 8 : (appeared ? 0 : 16))
        .opacity(isExiting ? 0 : (appeared ? 1 : 0))
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) {
                appeared = true
            }
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(hex: "14142B"))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    private var iconContainer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "5B6CF7").opacity(0.15))
                .frame(width: 34, height: 34)
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(hex: "5B6CF7"))
        }
    }

    private var undoButton: some View {
        Button(action: handleUndo) {
            Text("Undo")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(undoHovering ? 1.0 : 0.65))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(undoHovering ? 0.12 : 0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Color.white.opacity(undoHovering ? 0.18 : 0.08), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { undoHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: undoHovering)
    }

    private var dismissButton: some View {
        Button(action: handleDismiss) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(dismissHovering ? 0.09 : 0))
                    .frame(width: 20, height: 20)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(dismissHovering ? 0.75 : 0.28))
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { dismissHovering = $0 }
    }

    /// Runs the exit animation, then fires `action` once opacity has reached zero.
    private func animateOut(then action: @escaping @MainActor () -> Void) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            isExiting = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            action()
        }
    }

    private func handleUndo() {
        let captured = entry
        animateOut {
            AppState.shared.dismissLearnedEntryToast()
            Task { await CorrectionLearningService.undo(captured) }
        }
    }

    private func handleDismiss() {
        animateOut {
            AppState.shared.dismissLearnedEntryToast()
        }
    }
}

#Preview {
    ZStack {
        Color.black
        LearnedWordCard(entry: DictionaryEntry(
            incorrectForm: "glyn",
            correctForm: "Glean",
            category: "Learned",
            observedSource: "Glyn"
        ))
        .padding(40)
    }
}
