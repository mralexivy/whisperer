//
//  SkeletonView.swift
//  Whisperer
//
//  Shimmer skeleton components for loading states.
//  Design: dark navy base (white.opacity(0.06)) + bright sweep band (white.opacity(0.10)).
//

import SwiftUI

// MARK: - Base shimmer rect

struct SkeletonRect: View {
    var cornerRadius: CGFloat = 6
    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(0.06))
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: Color.white.opacity(0.10), location: 0.5),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: UnitPoint(x: phase - 0.5, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.5, y: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
            .onAppear {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

// MARK: - Meeting list skeleton row

struct MeetingListSkeletonRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SkeletonRect(cornerRadius: 3)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 7) {
                SkeletonRect()
                    .frame(width: 150, height: 13)
                SkeletonRect()
                    .frame(width: 100, height: 11)
                HStack(spacing: 6) {
                    SkeletonRect(cornerRadius: 10)
                        .frame(width: 64, height: 20)
                    SkeletonRect(cornerRadius: 10)
                        .frame(width: 72, height: 20)
                }
                .padding(.top, 1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Meeting segment skeleton row

struct MeetingSegmentSkeleton: View {
    // Varied widths give a realistic "text" look
    private let lineWidths: [CGFloat]

    init(seed: Int = 0) {
        // Deterministic widths per row using a simple seed (no randomness at render time)
        let base: [CGFloat] = [240, 180, 220, 160, 200]
        let i = seed % base.count
        lineWidths = [base[i], base[(i + 2) % base.count]]
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Timestamp column
            SkeletonRect()
                .frame(width: 36, height: 11)
                .padding(.top, 2)
                .frame(width: 58, alignment: .trailing)

            // Text lines
            VStack(alignment: .leading, spacing: 8) {
                SkeletonRect()
                    .frame(maxWidth: .infinity, minHeight: 13, maxHeight: 13)
                SkeletonRect()
                    .frame(width: lineWidths[1], height: 13)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}
