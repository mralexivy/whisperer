//
//  CorrectionPopoverCard.swift
//  Whisperer
//
//  "Got a word wrong?" — the one place the user can *tell* the dictionary it misheard, rather
//  than leaving it to infer that from an edit it happens to observe.
//
//  It appears under the dictation it refers to, unasked, for a few seconds. That is deliberate:
//  a mishearing is only worth a click while it is still on screen, and a correction surface the
//  user has to remember to open is a correction surface nobody uses.
//
//  Teach only. Fixing a word here teaches the dictionary for next time; the text already pasted
//  is left alone. That is what keeps this identical in every build — it needs no Accessibility
//  permission and contains no `#if`.
//
//  The commit path goes through `CorrectionLearningService.observe`, the same funnel the History
//  and post-paste sources use, so the promotion gates cannot be bypassed by being explicit.
//

import AppKit
import SwiftUI

struct CorrectionPopoverCard: View {
    let prompt: CorrectionPrompt

    @Environment(\.overlayScale) private var scale

    private enum Phase: Equatable {
        case picking
        /// The pair was well-formed but did not clear the automatic gates. Offered as one click
        /// instead of being demoted to a review list the user may never open.
        case confirming(observed: String, corrected: String)
        case finished(String)
    }

    @State private var phase: Phase = .picking
    @State private var editingIndex: Int?
    @State private var draft = ""
    @State private var hoveredIndex: Int?
    @State private var appeared = false
    @State private var isExiting = false
    @State private var dismissHovering = false
    @State private var confirmHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            header
            content
        }
        .padding(.leading, 14 * scale)
        .padding(.trailing, 8 * scale)
        .padding(.vertical, 10 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "0C0C1A"))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .scaleEffect(isExiting ? 0.96 : (appeared ? 1.0 : 0.94))
        .offset(y: isExiting ? 8 : (appeared ? 0 : 16))
        .opacity(isExiting ? 0 : (appeared ? 1 : 0))
        .onHover { hovering in
            AppState.shared.correctionPromptHeld = hovering || editingIndex != nil
        }
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.03)) {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            Text(headerTitle)
                .font(.system(size: 11.5 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))

            Spacer(minLength: 8 * scale)

            if editingIndex != nil {
                Text("⏎ learn  ·  esc cancel")
                    .font(.system(size: 10.5 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(dismissHovering ? 0.7 : 0.3))
                    .frame(width: 22 * scale, height: 22 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { dismissHovering = $0 }
            .accessibilityLabel("Dismiss")
        }
    }

    private var headerTitle: String {
        switch phase {
        case .picking:
            return editingIndex == nil ? "Got a word wrong?" : "What should it be?"
        case .confirming:
            return "Not a mishearing — add it anyway?"
        case .finished(let message):
            return message
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .picking:
            transcript
        case .confirming(let observed, let corrected):
            confirmRow(observed: observed, corrected: corrected)
        case .finished:
            EmptyView()
        }
    }

    private var transcript: some View {
        FlowLayout(spacing: 3 * scale, lineSpacing: 4 * scale) {
            if prompt.isTruncated {
                Text("…")
                    .font(.system(size: 12.5 * scale))
                    .foregroundColor(.white.opacity(0.3))
            }
            ForEach(prompt.tokens) { token in
                if token.isWord {
                    wordView(token)
                } else if !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(token.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12.5 * scale))
                        .foregroundColor(.white.opacity(0.35))
                }
                // Whitespace-only separators are dropped: the chips carry their own spacing.
            }
        }
    }

    @ViewBuilder
    private func wordView(_ token: CorrectionPromptToken) -> some View {
        if editingIndex == token.index {
            CorrectionWordField(
                text: $draft,
                scale: scale,
                onCommit: { commit(tokenAt: token.index) },
                onCancel: cancelEditing,
                onFocusUnavailable: cancelEditing
            )
            .frame(width: fieldWidth, height: 20 * scale)
            .padding(.horizontal, 6 * scale)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "5B6CF7").opacity(0.6), lineWidth: 1)
                    )
            )
        } else {
            Button { beginEditing(token) } label: {
                Text(token.text)
                    .font(.system(size: 12.5 * scale))
                    .foregroundColor(.white.opacity(hoveredIndex == token.index ? 1.0 : 0.75))
                    .padding(.horizontal, 4 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(hoveredIndex == token.index ? 0.12 : 0))
                    )
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredIndex = hovering ? token.index : (hoveredIndex == token.index ? nil : hoveredIndex)
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .accessibilityLabel("Fix the word \(token.text)")
        }
    }

    /// Roughly the width of the draft, so the field grows with what is being typed instead of
    /// reflowing the whole transcript on every keystroke.
    private var fieldWidth: CGFloat {
        max(48 * scale, CGFloat(draft.count) * 7.2 * scale)
    }

    private func confirmRow(observed: String, corrected: String) -> some View {
        HStack(spacing: 10 * scale) {
            HStack(spacing: 5 * scale) {
                Text(observed)
                    .strikethrough(true, color: .white.opacity(0.35))
                    .foregroundColor(.white.opacity(0.4))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
                Text(corrected)
                    .foregroundColor(.white)
            }
            .font(.system(size: 12.5 * scale, weight: .medium))

            Spacer(minLength: 8 * scale)

            Button {
                Task { await alwaysFix(observed: observed, corrected: corrected) }
            } label: {
                Text("Always fix")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(Color(hex: "0C0C1A"))
                    .padding(.horizontal, 11 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.white.opacity(confirmHovering ? 1.0 : 0.92))
                    )
            }
            .buttonStyle(.plain)
            .onHover { confirmHovering = $0 }
        }
    }

    // MARK: - Actions

    private func beginEditing(_ token: CorrectionPromptToken) {
        draft = token.text
        editingIndex = token.index
        AppState.shared.correctionPromptHeld = true
    }

    private func cancelEditing() {
        editingIndex = nil
        draft = ""
        AppState.shared.correctionPromptHeld = false
    }

    private func commit(tokenAt index: Int) {
        guard let edited = CorrectionPromptTokenizer.replacing(
            tokenAt: index, with: draft, in: prompt.tokens
        ) else {
            cancelEditing()
            return
        }
        let original = prompt.text
        editingIndex = nil
        AppState.shared.correctionPromptHeld = true

        Task { @MainActor in
            let outcome = await CorrectionLearningService.observe(
                original: original, edited: edited, source: .correctionPopover)

            if !outcome.learned.isEmpty {
                // The service already raised the "Learned: …" toast, with Undo. Step aside for it.
                dismiss()
            } else if let candidate = outcome.suggested.first {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    phase = .confirming(observed: candidate.observed, corrected: candidate.corrected)
                }
            } else {
                // Tombstoned, already known, or too close to the original to mine.
                finish("Nothing to learn there")
            }
        }
    }

    /// The escape hatch for a pair the automatic gates refuse. The gates exist to tell a
    /// mishearing from the user rewriting a thought — an inference this card does not have to
    /// make, because the user is standing right here. It enters as a hand-authored entry, not an
    /// auto-learned one, because the user authored it.
    private func alwaysFix(observed: String, corrected: String) async {
        let entry = DictionaryEntry(
            incorrectForm: observed,
            correctForm: corrected,
            category: "Learned",
            notes: "Added from a correction you made"
        )
        do {
            try await DictionaryManager.shared.addEntry(entry)
            await CorrectionSuggestionStore.shared.remove(observed: observed, corrected: corrected)
            Logger.event(.dictLearn, .app, [
                "source": .string("\(CorrectionLearningSource.correctionPopover.rawValue)-confirmed"),
                "learned": .int(1),
                "suggested": .int(0)
            ])
            finish("Always fixing \(observed) → \(corrected)")
        } catch {
            Logger.error("Failed to add confirmed correction: \(error.localizedDescription)", subsystem: .app)
            finish("Couldn't add that word")
        }
    }

    private func finish(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) { phase = .finished(message) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            dismiss()
        }
    }

    private func dismiss() {
        AppState.shared.correctionPromptHeld = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { isExiting = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            AppState.shared.dismissCorrectionPrompt()
        }
    }
}

// MARK: - Inline word editor

/// An `NSTextField` rather than a SwiftUI `TextField`.
///
/// The HUD is a borderless `.nonactivatingPanel`, which is documented to take key input without
/// activating the app but is a soft spot for SwiftUI focus. Doing it in AppKit lets us make the
/// panel key and the field first responder explicitly — and, one runloop later, verify it worked.
/// If the panel never became key the editor closes rather than sitting there silently swallowing
/// keystrokes. Activating the app is never an option: stealing focus from whatever the user is
/// typing in would be a worse bug than the mishearing.
private struct CorrectionWordField: NSViewRepresentable {
    @Binding var text: String
    let scale: CGFloat
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onFocusUnavailable: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12.5 * scale, weight: .semibold)
        field.textColor = .white
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping

        DispatchQueue.main.async {
            guard let window = field.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)

            guard window.isKeyWindow else {
                Logger.warning(
                    "Correction card editor could not take key focus; closing it rather than dropping keystrokes",
                    subsystem: .ui
                )
                onFocusUnavailable()
                return
            }
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text, field.currentEditor() == nil {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>
        private let onCommit: () -> Void
        private let onCancel: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                text.wrappedValue = control.stringValue
                onCommit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
                return true
            default:
                return false
            }
        }
    }
}

#Preview {
    ZStack {
        Color.black
        CorrectionPopoverCard(prompt: CorrectionPrompt(
            tokens: CorrectionPromptTokenizer.tokenize("we can glyn a lot from these numbers"),
            isTruncated: false
        ))
        .frame(width: 400)
        .padding(40)
    }
}
