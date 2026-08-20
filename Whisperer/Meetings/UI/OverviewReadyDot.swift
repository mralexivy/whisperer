//
//  OverviewReadyDot.swift
//  Whisperer
//
//  The "your overview is ready" marker on the Overview tab.
//
//  Deliberately a notification, not a navigation: the summary landing must never yank the
//  user off whatever they were reading. The tab glows, the user decides when to look, and
//  the glow clears the moment the tab is opened.
//
//  Shared by the workspace tab bar (MeetingDetailView) and the floating window
//  (MeetingLiveWindowView) so the two surfaces cannot drift apart.
//

import SwiftUI

struct OverviewReadyDot: View {
    /// Outward ping — a single expanding ring, restarted forever.
    @State private var ping = false
    /// Slow breath on the core glow, so the dot still reads as alive between pings.
    @State private var breathe = false

    private let accent = Color(hex: "5B6CF7")

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                .frame(width: 7, height: 7)
                .scaleEffect(ping ? 2.6 : 1)
                .opacity(ping ? 0 : 0.8)

            Circle()
                .fill(
                    LinearGradient(colors: [accent, Color(hex: "8B5CF6")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(breathe ? 0.95 : 0.45),
                        radius: breathe ? 5 : 2)
        }
        // Fixed footprint: the ring scales past the frame, so the tab label must not reflow
        // every time it pings.
        .frame(width: 7, height: 7)
        .allowsHitTesting(false)
        .accessibilityLabel("Overview ready")
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                ping = true
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        // A repeatForever animation outlives its view unless it is explicitly wound down.
        .onDisappear {
            ping = false
            breathe = false
        }
    }
}
