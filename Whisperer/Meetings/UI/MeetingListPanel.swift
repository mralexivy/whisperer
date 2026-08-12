//
//  MeetingListPanel.swift
//  Whisperer
//
//  Left column: library + live recording card.
//

import SwiftUI

struct MeetingListPanel: View {
    @ObservedObject var session: MeetingSession
    @Binding var selectedMeetingID: UUID?
    @ObservedObject private var manager = MeetingManager.shared
    @State private var searchText = ""

    private var filtered: [MeetingListItem] {
        if searchText.isEmpty { return manager.meetings }
        return manager.meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            if session.isRecording {
                liveCard
            }
            libraryList
        }
        .background(Color(hex: "0A0A18"))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Notes")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button {
                Task { await session.startRecording(title: defaultTitle()) }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            TextField("Search notes", text: $searchText)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Live card

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle().stroke(Color.red.opacity(0.3), lineWidth: 4)
                            .scaleEffect(1.4)
                    )
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: session.isRecording)
                Text("Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)
                Spacer()
                Text(session.elapsedDisplay)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundColor(.white.opacity(0.6))
            }

            MiniWaveformView()
                .frame(height: 20)

            Button {
                Task { await session.stopRecording() }
            } label: {
                Text("Stop Recording")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(hex: "14142B"))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Library

    private var libraryList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                // Header label — shown when there's content or while loading
                if !filtered.isEmpty || manager.isLoadingPage {
                    HStack {
                        Text("LIBRARY")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(.white.opacity(0.3))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                // Skeleton placeholder for initial load
                if manager.meetings.isEmpty && manager.isLoadingPage {
                    ForEach(0..<5, id: \.self) { _ in
                        MeetingListSkeletonRow()
                    }
                    .transition(.opacity)
                }

                ForEach(filtered) { meeting in
                    MeetingLibraryRow(
                        meeting: meeting,
                        isSelected: selectedMeetingID == meeting.id,
                        isLive: session.isRecording && session.meetingID == meeting.id,
                        processing: manager.processingPhase(for: meeting.id)
                    )
                    .onTapGesture { selectedMeetingID = meeting.id }
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            Task {
                                await MeetingManager.shared.deleteMeeting(meetingID: meeting.id)
                                if selectedMeetingID == meeting.id {
                                    selectedMeetingID = manager.meetings.first?.id
                                }
                            }
                        }
                    }
                }

                // Pagination sentinel — triggers next page load when scrolled into view
                if manager.hasMorePages {
                    Color.clear
                        .frame(height: 1)
                        .id("meeting-sentinel-\(manager.meetings.count)")
                        .onAppear { Task { await manager.loadNextPage() } }

                    if manager.isLoadingPage {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(Color(hex: "5B6CF7"))
                            .padding(.vertical, 8)
                    }
                }

                // Empty state (not loading, no results)
                if filtered.isEmpty && !manager.isLoadingPage {
                    emptyState
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "5B6CF7").opacity(0.14), Color.clear],
                            center: .center, startRadius: 4, endRadius: 38
                        )
                    )
                    .frame(width: 76, height: 76)

                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(hex: "14142B"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(hex: "5B6CF7").opacity(0.35), Color(hex: "8B5CF6").opacity(0.15)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 44, height: 44)

                Image(systemName: "note.text")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 4) {
                Text("No notes yet")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.65))

                Text("Tap + to create your first")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func defaultTitle() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy h:mm a"
        return "Note \(fmt.string(from: Date()))"
    }
}

// MARK: - Library Row

struct MeetingLibraryRow: View {
    let meeting: MeetingListItem
    let isSelected: Bool
    let isLive: Bool
    var processing: MeetingProcessingPhase? = nil

    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .scaleEffect(processing != nil && pulse ? 1.45 : 1.0)
                .opacity(processing != nil && pulse ? 0.55 : 1.0)
                .padding(.top, 4)
                .onAppear { syncPulse() }
                // The phase usually turns on while the row is already on screen, so onAppear
                // alone would never start the pulse.
                .onChange(of: processing) { _, _ in syncPulse() }

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                    .lineLimit(1)

                Text(meeting.formattedDate)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))

                HStack(spacing: 6) {
                    if let processing {
                        pill(processing.shortLabel, icon: "sparkles", color: Color(hex: "8B5CF6"))
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                    if meeting.duration > 0 {
                        pill(meeting.displayDuration, icon: "clock", color: Color(hex: "5B6CF7"))
                    }
                    if meeting.wordCount > 0 {
                        pill("\(meeting.wordCount) words", icon: "text.alignleft", color: Color(hex: "F59E0B"))
                    }
                }
                .padding(.top, 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: processing)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color(hex: "5B6CF7").opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color(hex: "5B6CF7").opacity(0.25) : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private var dotColor: Color {
        if isLive { return .red }
        if processing != nil { return Color(hex: "8B5CF6") }
        return isSelected ? Color(hex: "5B6CF7") : Color.white.opacity(0.15)
    }

    private func syncPulse() {
        if processing != nil {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { pulse = false }
        }
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - Mini waveform

struct MiniWaveformView: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<18, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 2, height: barHeight(i))
                    .animation(
                        .easeInOut(duration: 0.4 + Double(i) * 0.03)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.05),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 4
        let max: CGFloat = 18
        let wave = sin(Double(i) * 0.7) * 0.5 + 0.5
        return animating ? base + CGFloat(wave) * (max - base) : base
    }
}
