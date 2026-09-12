//
//  TranscriptionPickerView.swift
//  Whisperer
//
//  Floating overlay showing recent transcriptions for quick clipboard copy.
//

import SwiftUI

struct TranscriptionPickerView: View {
    @ObservedObject private var pickerState = TranscriptionPickerState.shared

    @State private var isCloseHovered = false

    // Design system colors
    private let cardBackground = Color(red: 0.078, green: 0.078, blue: 0.169)   // #14142B
    private let panelBackground = Color(red: 0.047, green: 0.047, blue: 0.102)  // #0C0C1A
    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)       // #5B6CF7
    private let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)     // #8B5CF6
    private let border = Color.white.opacity(0.06)

    var body: some View {
        if pickerState.isVisible {
            ZStack {
                VStack(spacing: 0) {
                    headerView
                    dividerView
                    itemListView
                    footerView
                }
                .background(cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(border, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.4), radius: 20, y: 8)
                .frame(width: 380)

                // "Copied" feedback overlay
                if pickerState.showCopiedFeedback {
                    copiedFeedback
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.15), value: pickerState.showCopiedFeedback)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 10) {
            // Icon container
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.cyan.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.cyan)
                    .font(.system(size: 12, weight: .medium))
            }

            Text("RECENT TRANSCRIPTIONS")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [accentBlue, accentPurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .tracking(1.0)

            Spacer()

            Text("⌥+V to cycle")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.35))

            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)

    }

    // MARK: - Close button

    /// The third way out, alongside Escape and releasing ⌥. Uses a tap gesture rather than a
    /// Button for the same reason the rows do: the panel is non-activating and never becomes
    /// key, so a Button would not reliably fire.
    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white.opacity(isCloseHovered ? 0.9 : 0.4))
            .frame(width: 18, height: 18)
            .background(
                Circle().fill(Color.white.opacity(isCloseHovered ? 0.12 : 0.05))
            )
            .contentShape(Circle())
            .onHover { isCloseHovered = $0 }
            .onTapGesture {
                // Clear the hover state on the way out, or the button comes back lit on the
                // next show — the pointer is long gone by then and never sends an exit.
                isCloseHovered = false
                pickerState.dismiss()
            }
            .animation(.easeOut(duration: 0.12), value: isCloseHovered)
            .accessibilityLabel("Close")
    }

    // MARK: - Divider

    private var dividerView: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [accentBlue.opacity(0.3), accentPurple.opacity(0.3), Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }

    // MARK: - Item List

    private var itemListView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(pickerState.items.enumerated()), id: \.element.id) { index, item in
                        PickerRow(
                            item: item,
                            index: index,
                            isSelected: index == pickerState.selectedIndex,
                            onHover: { pickerState.highlight(index: index) },
                            onTap:   { pickerState.choose(index: index) }
                        )
                        .id(index)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: maxListHeight)
            // Follows hotkey cycling only — see TranscriptionPickerState.scrollToken.
            .onChange(of: pickerState.scrollToken) { _ in
                withAnimation(.easeInOut(duration: 0.1)) {
                    proxy.scrollTo(pickerState.selectedIndex, anchor: .center)
                }
            }
        }
    }

    private var maxListHeight: CGFloat {
        // 52pt per row + 2pt spacing, capped at 10 items
        let itemCount = min(pickerState.items.count, 10)
        return CGFloat(itemCount) * 54 + 12
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            Text("Click, or release ⌥, to copy · esc to close")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
            Spacer()
            Text("\(pickerState.items.count) items")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.25))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)

    }

    // MARK: - Copied Feedback

    private var copiedFeedback: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text("Copied to clipboard")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [accentBlue, accentPurple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .shadow(color: accentBlue.opacity(0.3), radius: 10, y: 2)
    }
}

// MARK: - Picker Row

private struct PickerRow: View {
    let item: PickerItem
    let index: Int
    let isSelected: Bool
    var onHover: () -> Void = {}
    var onTap:   () -> Void = {}

    private let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)

    var body: some View {
        HStack(spacing: 10) {
            // Index number
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isSelected ? .white : .white.opacity(0.25))
                .frame(width: 20, alignment: .center)

            // Transcription text + metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Label(relativeTime(item.timestamp), systemImage: "clock")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))

                    Label("\(item.wordCount)w", systemImage: "text.word.spacing")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                }
                .labelStyle(CompactLabelStyle())
            }

            Spacer(minLength: 4)

            // Copy indicator on selected
            if isSelected {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(accentBlue)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accentBlue.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? accentBlue.opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.1), value: isSelected)
        // The panel is non-activating and never becomes key, so a SwiftUI Button would not
        // reliably fire. A hit-shaped tap gesture is delivered through the normal mouse-event
        // path and works without the window taking focus from whatever the user was typing in.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { if $0 { onHover() } }
        .onTapGesture { onTap() }
    }

    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval / 60)
        let hours = Int(interval / 3600)
        let days = Int(interval / 86400)

        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if hours < 24 { return "\(hours)h" }
        if days < 30 { return "\(days)d" }
        return "\(days / 30)mo"
    }
}

// MARK: - Compact Label Style

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
                .font(.system(size: 9, weight: .medium))
            configuration.title
        }
    }
}
