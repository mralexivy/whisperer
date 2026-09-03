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
    @State private var iconBounce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * scale) {
            header
            content
        }
        .padding(.leading, 14 * scale)
        .padding(.trailing, 10 * scale)
        .padding(.vertical, 11 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(hex: "14142B"))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.35), radius: 12, x: 0, y: 4)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8 * scale) {
            headerIcon

            Text(headerTitle)
                .font(.system(size: 11.5 * scale, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))
                .animation(.easeInOut(duration: 0.18), value: headerTitle)

            Spacer(minLength: 8 * scale)

            if editingIndex != nil {
                keyboardHints
            }

            dismissButton
        }
    }

    private var headerIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6 * scale)
                .fill(headerIconColor.opacity(0.15))
                .frame(width: 24 * scale, height: 24 * scale)
            Image(systemName: headerIconName)
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(headerIconColor)
        }
        .scaleEffect(iconBounce ? 1.2 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: iconBounce)
    }

    private var headerIconName: String {
        switch phase {
        case .picking: return "character.cursor.ibeam"
        case .confirming: return "questionmark.circle"
        case .finished(let msg): return msg.hasPrefix("Nothing") ? "slash.circle" : "checkmark.circle.fill"
        }
    }

    private var headerIconColor: Color {
        switch phase {
        case .picking: return .orange
        case .confirming: return Color(hex: "5B6CF7")
        case .finished(let msg): return msg.hasPrefix("Nothing") ? .white.opacity(0.4) : .green
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

    private var keyboardHints: some View {
        HStack(spacing: 4 * scale) {
            keyCap("⏎")
            Text("learn")
                .foregroundColor(.white.opacity(0.3))
            Text("·")
                .foregroundColor(.white.opacity(0.15))
            keyCap("esc")
            Text("cancel")
                .foregroundColor(.white.opacity(0.3))
        }
        .font(.system(size: 10 * scale, weight: .medium))
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.45))
            .padding(.horizontal, 4 * scale)
            .padding(.vertical, 2 * scale)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            )
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            ZStack {
                RoundedRectangle(cornerRadius: 5 * scale)
                    .fill(Color.white.opacity(dismissHovering ? 0.09 : 0))
                    .frame(width: 20 * scale, height: 20 * scale)
                Image(systemName: "xmark")
                    .font(.system(size: 9 * scale, weight: .bold))
                    .foregroundColor(.white.opacity(dismissHovering ? 0.75 : 0.3))
            }
            .frame(width: 26 * scale, height: 26 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { dismissHovering = $0 }
        .accessibilityLabel("Dismiss")
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
                    .foregroundColor(.white.opacity(0.25))
            }
            ForEach(prompt.tokens) { token in
                if token.isWord {
                    wordView(token)
                } else if !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(token.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 12.5 * scale))
                        .foregroundColor(.white.opacity(0.3))
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
                    .fill(Color.white.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "5B6CF7").opacity(0.7), lineWidth: 1)
                    )
            )
            .shadow(color: Color(hex: "5B6CF7").opacity(0.28), radius: 8, x: 0, y: 0)
        } else {
            Button { beginEditing(token) } label: {
                Text(token.text)
                    .font(.system(size: 12.5 * scale, weight: hoveredIndex == token.index ? .medium : .regular))
                    .foregroundColor(.white.opacity(hoveredIndex == token.index ? 1.0 : 0.8))
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 3 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(hoveredIndex == token.index ? 0.1 : 0))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(hoveredIndex == token.index ? 0.14 : 0), lineWidth: 0.5)
                            )
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
                    .strikethrough(true, color: .white.opacity(0.3))
                    .foregroundColor(.white.opacity(0.38))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8.5 * scale, weight: .bold))
                    .foregroundColor(.white.opacity(0.22))
                Text(corrected)
                    .foregroundColor(.white)
            }
            .font(.system(size: 12.5 * scale, weight: .medium))
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
            )

            Spacer(minLength: 8 * scale)

            Button {
                Task { await alwaysFix(observed: observed, corrected: corrected) }
            } label: {
                Text("Always fix")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12 * scale)
                    .padding(.vertical, 5 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(confirmHovering ? 1.0 : 0.88)
                    )
                    .shadow(color: Color(hex: "5B6CF7").opacity(confirmHovering ? 0.45 : 0.25), radius: 8, x: 0, y: 0)
            }
            .buttonStyle(.plain)
            .onHover { confirmHovering = $0 }
            .scaleEffect(confirmHovering ? 1.03 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: confirmHovering)
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
                bounceIcon()
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
        bounceIcon()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            dismiss()
        }
    }

    private func bounceIcon() {
        iconBounce = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            iconBounce = false
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
