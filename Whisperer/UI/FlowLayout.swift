//
//  FlowLayout.swift
//  Whisperer
//
//  Wrapping row layout used by chips and tag lists.
//

import SwiftUI

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

            let size: CGSize
            if idealSize.width > maxWidth {
                size = subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            } else {
                size = idealSize
            }

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }

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
