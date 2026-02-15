//
//  HighlightedText.swift
//  Whisperer
//
//  Inline highlighting for dictionary corrections with per-word popover
//

import SwiftUI

struct HighlightedText: View {
    let text: String
    let corrections: [AppliedCorrection]
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared

    // Track by segment ID, not correction ID (same correction can appear multiple times)
    // Use String ID for stability across re-renders
    @State private var hoveredSegmentId: String?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        FlowLayout(spacing: 4, lineSpacing: 6) {
            ForEach(textSegments) { segment in
                if let correction = segment.correction {
                    // Corrected word - highlighted and hoverable
                    CorrectedWordView(
                        text: segment.text,
                        correction: correction,
                        segmentId: segment.id,
                        isHovered: hoveredSegmentId == segment.id,
                        colorScheme: colorScheme,
                        onHover: { isHovering in
                            handleHover(segmentId: segment.id, isHovering: isHovering)
                        },
                        onViewRule: {
                            viewDictionaryRule(correction)
                        },
                        onDismiss: {
                            dismissPopover()
                        }
                    )
                } else {
                    // Regular text
                    Text(segment.text)
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - Text Parsing

    private var textSegments: [TextSegment] {
        guard !corrections.isEmpty else {
            return [TextSegment(id: "plain-0", text: text, correction: nil)]
        }

        // Build a list of all correction locations in the text
        var correctionRanges: [(range: Range<String.Index>, correction: AppliedCorrection)] = []

        for correction in corrections {
            let searchText = text
            var searchStart = searchText.startIndex

            // Find ALL occurrences of this correction's replacement in the text
            while let range = searchText.range(of: correction.replacement, options: [.caseInsensitive], range: searchStart..<searchText.endIndex) {
                correctionRanges.append((range: range, correction: correction))

                // Move past this match
                if range.upperBound < searchText.endIndex {
                    searchStart = range.upperBound
                } else {
                    break
                }
            }
        }

        // Sort by position in text
        correctionRanges.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Remove overlapping ranges (keep the first one)
        var filteredRanges: [(range: Range<String.Index>, correction: AppliedCorrection)] = []
        for item in correctionRanges {
            if let last = filteredRanges.last {
                // Skip if this overlaps with the previous range
                if item.range.lowerBound < last.range.upperBound {
                    continue
                }
            }
            filteredRanges.append(item)
        }

        // Build segments with stable IDs based on position
        var segments: [TextSegment] = []
        var currentIndex = text.startIndex
        var segmentIndex = 0

        for item in filteredRanges {
            // Add text before this correction
            if currentIndex < item.range.lowerBound {
                let beforeText = String(text[currentIndex..<item.range.lowerBound])
                let position = text.distance(from: text.startIndex, to: currentIndex)
                segments.append(TextSegment(id: "plain-\(position)", text: beforeText, correction: nil))
                segmentIndex += 1
            }

            // Add the correction with stable ID based on position
            let correctedText = String(text[item.range])
            let position = text.distance(from: text.startIndex, to: item.range.lowerBound)
            segments.append(TextSegment(id: "correction-\(position)", text: correctedText, correction: item.correction))
            segmentIndex += 1

            currentIndex = item.range.upperBound
        }

        // Add any remaining text after the last correction
        if currentIndex < text.endIndex {
            let remainingText = String(text[currentIndex...])
            let position = text.distance(from: text.startIndex, to: currentIndex)
            segments.append(TextSegment(id: "plain-\(position)", text: remainingText, correction: nil))
        }

        return segments
    }

    // MARK: - Hover Handling

    private func handleHover(segmentId: String, isHovering: Bool) {
        dismissTask?.cancel()

        if isHovering {
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredSegmentId = segmentId
            }
        } else {
            // Longer delay to allow moving to popover and clicking buttons
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 800_000_000) // 800ms - enough time to reach popover
                if !Task.isCancelled {
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if hoveredSegmentId == segmentId {
                                hoveredSegmentId = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func dismissPopover() {
        dismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.15)) {
            hoveredSegmentId = nil
        }
    }

    private func viewDictionaryRule(_ correction: AppliedCorrection) {
        dismissPopover()
        dictionaryManager.navigateToEntry(correction.entryId)
        NotificationCenter.default.post(name: .switchToDictionaryTab, object: correction.entryId)
    }
}

// MARK: - Text Segment

private struct TextSegment: Identifiable {
    // Use stable ID based on position and text, not random UUID
    let id: String
    let text: String
    let correction: AppliedCorrection?

    init(id: String, text: String, correction: AppliedCorrection?) {
        self.id = id
        self.text = text
        self.correction = correction
    }
}

// MARK: - Corrected Word View

private struct CorrectedWordView: View {
    let text: String
    let correction: AppliedCorrection
    let segmentId: String
    let isHovered: Bool
    let colorScheme: ColorScheme
    let onHover: (Bool) -> Void
    let onViewRule: () -> Void
    let onDismiss: () -> Void

    @State private var isPopoverHovered = false

    var body: some View {
        Text(text)
            .foregroundColor(WhispererColors.primaryText(colorScheme))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.green.opacity(colorScheme == .dark ? 0.25 : 0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.green.opacity(0.4), lineWidth: isHovered ? 1.5 : 0)
            )
            .onHover { hovering in
                onHover(hovering)
            }
            .popover(isPresented: .constant(isHovered || isPopoverHovered), arrowEdge: .top) {
                CorrectionPopoverContent(
                    correction: correction,
                    colorScheme: colorScheme,
                    onDismiss: onDismiss,
                    onViewRule: onViewRule,
                    onHover: { hovering in
                        isPopoverHovered = hovering
                        if !hovering {
                            onHover(false)
                        }
                    }
                )
            }
    }
}

// MARK: - Correction Popover Content

private struct CorrectionPopoverContent: View {
    let correction: AppliedCorrection
    let colorScheme: ColorScheme
    let onDismiss: () -> Void
    let onViewRule: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.accent)

                Text("Dictionary correction")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))

                if let category = correction.category {
                    Spacer()
                    Text(category)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(WhispererColors.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(WhispererColors.accent.opacity(0.15))
                        )
                }

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                }
                .buttonStyle(.plain)
            }

            Divider()

            // Correction display
            HStack(spacing: 10) {
                Text(correction.original)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.red.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.red.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.red.opacity(0.3), lineWidth: 1)
                            )
                    )

                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(WhispererColors.accent)

                Text(correction.replacement)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.green.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                            )
                    )
            }

            // Notes
            if let notes = correction.notes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .lineLimit(3)
            }

            // Action button
            Button(action: onViewRule) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 11))
                    Text("View rule in Dictionary")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(WhispererColors.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(WhispererColors.accent.opacity(0.1))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(minWidth: 240, maxWidth: 300)
        .background(WhispererColors.cardBackground(colorScheme))
        .onHover { hovering in
            onHover(hovering)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let idealSize = subview.sizeThatFits(.unspecified)

            // If the item is wider than the container, constrain it so Text can wrap
            let size: CGSize
            if idealSize.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            } else {
                size = idealSize
            }

            // Check if we need to wrap to next line
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

            // If still wider than remaining space, constrain to remaining width
            let availableWidth = maxWidth - currentX
            let finalSize: CGSize
            if size.width > availableWidth && availableWidth > 0 {
                finalSize = subview.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
            } else {
                finalSize = size
            }

            frames.append(CGRect(x: currentX, y: currentY, width: finalSize.width, height: finalSize.height))
            lineHeight = max(lineHeight, finalSize.height)
            currentX += finalSize.width + spacing
            totalWidth = max(totalWidth, min(currentX - spacing, maxWidth))
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), frames)
    }
}
