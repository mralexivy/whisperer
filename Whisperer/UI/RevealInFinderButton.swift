//
//  RevealInFinderButton.swift
//  Whisperer
//
//  A small round button that reveals a file in Finder.
//

import SwiftUI
import AppKit

struct RevealInFinderButton: View {
    let url: URL
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(
                    isHovered ? .cyan : WhispererColors.secondaryText(colorScheme)
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
                )
                .overlay(
                    Circle()
                        .stroke(isHovered ? WhispererColors.border(colorScheme) : Color.clear, lineWidth: 0.5)
                )
                .shadow(
                    color: isHovered ? Color.black.opacity(colorScheme == .dark ? 0.08 : 0.06) : Color.clear,
                    radius: 3, y: 1
                )
                .scaleEffect(isHovered ? 1.06 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}
