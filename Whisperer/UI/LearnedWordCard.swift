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
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Learned: \(entry.correctForm)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                if let observed = entry.observedSource {
                    Text("heard as \(observed)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }

            Spacer(minLength: 12)

            undoButton
            dismissButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "0C0C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
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

    private var undoButton: some View {
        Button(action: handleUndo) {
            Text("Undo")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Color(hex: "0C0C1A"))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(undoHovering ? 1.0 : 0.92))
                )
        }
        .buttonStyle(.plain)
        .onHover { undoHovering = $0 }
    }

    private var dismissButton: some View {
        Button(action: handleDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(dismissHovering ? 0.7 : 0.3))
                .frame(width: 24, height: 24)
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
