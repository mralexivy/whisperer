//
//  CorrectionSuggestionsSection.swift
//  Whisperer
//
//  Tier 2 of the learner: pairs that were mined from a real correction but did not clear the
//  automatic gates — the observed word is valid English, or the two words do not sound alike.
//
//  These are shown rather than applied because the same miner that finds `Glyn → Glean` also
//  finds `the → our`: a user rewriting a thought, not the recognizer mishearing one. One click
//  here is still far less work than authoring the entry by hand, and a wrong guess costs the
//  user nothing.
//
//  Accepting creates an ordinary user entry — no `observedSource` — because the user has now
//  authored it. Dismissing tombstones the pair so the same suggestion never returns.
//

import SwiftUI

struct CorrectionSuggestionsSection: View {
    @Environment(\.colorScheme) var colorScheme

    @State private var suggestions: [CorrectionSuggestion] = []
    @State private var isExpanded = false

    var body: some View {
        Group {
            if !suggestions.isEmpty {
                VStack(spacing: 0) {
                    header

                    if isExpanded {
                        VStack(spacing: 6) {
                            ForEach(suggestions) { suggestion in
                                row(for: suggestion)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WhispererColors.accentPurple.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(WhispererColors.accentPurple.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .task { await reload() }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(WhispererColors.accentPurple)

                Text("^[\(suggestions.count) word](inflect: true) you corrected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Add to your dictionary?")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private func row(for suggestion: CorrectionSuggestion) -> some View {
        HStack(spacing: 8) {
            Text(suggestion.observed)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .strikethrough()

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))

            Text(suggestion.corrected)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Spacer(minLength: 8)

            Button("Add") { Task { await accept(suggestion) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerOnHover()

            Button {
                Task { await dismiss(suggestion) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerOnHover()
            .help("Never suggest this word again")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
    }

    // MARK: - Actions

    private func reload() async {
        suggestions = await CorrectionSuggestionStore.shared.all()
            .sorted { $0.lastObservedAt > $1.lastObservedAt }
    }

    private func accept(_ suggestion: CorrectionSuggestion) async {
        let entry = DictionaryEntry(
            incorrectForm: suggestion.observed,
            correctForm: suggestion.corrected,
            category: "Learned",
            notes: "Added from a correction you made"
        )
        try? await DictionaryManager.shared.addEntry(entry)
        await CorrectionSuggestionStore.shared.remove(id: suggestion.id)
        await reload()
    }

    private func dismiss(_ suggestion: CorrectionSuggestion) async {
        await CorrectionTombstoneStore.shared.add(suggestion.observed)
        await CorrectionSuggestionStore.shared.remove(id: suggestion.id)
        await reload()
    }
}
