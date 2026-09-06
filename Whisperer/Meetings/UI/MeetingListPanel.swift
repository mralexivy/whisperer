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
    @State private var collapsedDays: Set<Date> = []

    private var filtered: [MeetingListItem] {
        if searchText.isEmpty { return manager.meetings }
        return manager.meetings.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var dayGroups: [(day: Date, items: [MeetingListItem])] {
        Dictionary(grouping: filtered) { Calendar.current.startOfDay(for: $0.createdAt) }
            .map { (day: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    private func dayHeaderString(for date: Date) -> String {
        let calendar = Calendar.current
        let fmt = DateFormatter()
        if calendar.isDateInToday(date) {
            fmt.dateFormat = "MMM d"
            return "TODAY, \(fmt.string(from: date).uppercased())"
        } else if calendar.isDateInYesterday(date) {
            fmt.dateFormat = "MMM d"
            return "YESTERDAY, \(fmt.string(from: date).uppercased())"
        } else {
            fmt.dateFormat = "EEE, MMM d"
            return fmt.string(from: date).uppercased()
        }
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
                Task { await session.startRecording(title: defaultTitle(), surface: .workspace) }
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
                // Skeleton placeholder for initial load
                if manager.meetings.isEmpty && manager.isLoadingPage {
                    ForEach(0..<5, id: \.self) { _ in
                        MeetingListSkeletonRow()
                    }
                    .transition(.opacity)
                }

                // Day-grouped library
                ForEach(dayGroups, id: \.day) { group in
                    // Day header
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if collapsedDays.contains(group.day) {
                                collapsedDays.remove(group.day)
                            } else {
                                collapsedDays.insert(group.day)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white.opacity(0.3))
                                .rotationEffect(collapsedDays.contains(group.day) ? .degrees(-90) : .degrees(0))
                                .animation(.easeInOut(duration: 0.18), value: collapsedDays.contains(group.day))
                            Text(dayHeaderString(for: group.day))
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.8)
                                .foregroundColor(.white.opacity(0.3))
                            Spacer()
                            Text("\(group.items.count)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.white.opacity(0.2))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    // Rows for this day
                    if !collapsedDays.contains(group.day) {
                        ForEach(group.items) { meeting in
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
            // Fixed-footprint dot + optional halo ring.
            // The halo scales beyond the 7pt frame so the row layout never reflows during animation.
            // The core dot is never scaled or faded — both rows stay in a straight column.
            ZStack {
                if processing != nil {
                    Circle()
                        .strokeBorder(dotColor.opacity(0.6), lineWidth: 1)
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulse ? 2.4 : 1.0)
                        .opacity(pulse ? 0.0 : 0.8)
                        .animation(
                            processing != nil
                                ? .easeInOut(duration: 0.85).repeatForever(autoreverses: false)
                                : .easeOut(duration: 0.2),
                            value: pulse
                        )
                }
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }
            .frame(width: 7, height: 7)
            .padding(.top, 4)
            .onAppear { pulse = processing != nil }
            // The phase usually turns on while the row is already on screen, so onAppear
            // alone would never start the pulse.
            .onChange(of: processing) { _, _ in pulse = processing != nil }
            .onDisappear { pulse = false }

            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                    .lineLimit(1)

                Text(meeting.formattedTime)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))

                // Adaptive pill row: priority-ordered so higher-priority pills survive at
                // narrow widths. ViewThatFits picks the longest variant that fits.
                // One line only — never wraps so the row height is constant regardless of
                // which pills are present.
                ViewThatFits(in: .horizontal) {
                    pillHStack(processing: processing, duration: meeting.duration > 0, words: meeting.wordCount > 0)
                    pillHStack(processing: processing, duration: meeting.duration > 0, words: false)
                    pillHStack(processing: processing, duration: false, words: false)
                    pillHStack(processing: nil, duration: meeting.duration > 0, words: false)
                    EmptyView()
                }
                .frame(height: 20, alignment: .leading)
                .padding(.top, 2)
                .animation(.spring(response: 0.3, dampingFraction: 0.85), value: processing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    /// Builds a horizontal pill row with exactly the requested slots.
    /// Passing `false` for a slot omits it — `ViewThatFits` uses this to probe widths.
    @ViewBuilder
    private func pillHStack(processing: MeetingProcessingPhase?, duration: Bool, words: Bool) -> some View {
        HStack(spacing: 6) {
            if let processing {
                pill(processing.shortLabel, icon: "sparkles", color: Color(hex: "8B5CF6"))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            if duration {
                pill(meeting.displayDuration, icon: "clock", color: Color(hex: "5B6CF7"))
            }
            if words {
                pill("\(meeting.wordCount) words", icon: "text.alignleft", color: Color(hex: "F59E0B"))
            }
        }
    }

    private func pill(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
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
