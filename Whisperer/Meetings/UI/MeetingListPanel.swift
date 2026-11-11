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
    /// The meeting waiting for the user to confirm its deletion. Nothing is deleted before they do.
    @State private var pendingDelete: MeetingListItem?
    /// "All" (by day) or "Series" (recurring meetings grouped, see `MeetingSeries`).
    @AppStorage("meetingListGroupsSeries") private var groupsSeries = false
    @State private var expandedSeries: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            modePicker
            if session.isRecording {
                liveCard
            } else {
                MeetingListCalendarStrip()
            }
            if groupsSeries { seriesList } else { libraryList }
        }
        .background(Color(hex: "0A0A18"))
        .task(id: groupsSeries) {
            // Series span the whole history, not the pages loaded so far. List items carry no
            // transcript, so loading all of them is cheap.
            guard groupsSeries else { return }
            while manager.hasMorePages { await manager.loadNextPage() }
            expandSelectedSeries()
        }
        .confirmationDialog(
            pendingDelete.map { "Delete “\($0.title)”?" } ?? "Delete meeting?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { meeting in
            Button("Delete Meeting", role: .destructive) { delete(meeting) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { _ in
            Text("Its transcript, recording, notes and questions are deleted from this Mac. This can't be undone.")
        }
    }

    private func delete(_ meeting: MeetingListItem) {
        pendingDelete = nil
        Task {
            await MeetingManager.shared.deleteMeeting(meetingID: meeting.id)
            if selectedMeetingID == meeting.id {
                selectedMeetingID = manager.meetings.first?.id
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Notes")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button {
                Task {
                    await session.startRecording(title: defaultTitle(), surface: .workspace)
                }
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

    // MARK: - Mode

    private var modePicker: some View {
        HStack(spacing: 6) {
            modeTab("All", icon: "list.bullet", selected: !groupsSeries, id: "notes.mode.all") { groupsSeries = false }
            modeTab("Series", icon: "square.stack.3d.up", selected: groupsSeries, id: "notes.mode.series") { groupsSeries = true }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func modeTab(_ title: String, icon: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) { action() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: selected ? .semibold : .medium))
            }
            .foregroundColor(selected ? .white : .white.opacity(0.55))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color(hex: "5B6CF7") : Color.clear))
            .overlay(Capsule().stroke(selected ? Color.clear : Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: selected ? Color(hex: "5B6CF7").opacity(0.25) : .clear, radius: 4, y: 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .uiTestFrame(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Series

    private var seriesGroups: (series: [MeetingSeries.Series], oneOffs: [MeetingListItem]) {
        MeetingSeries.group(filtered)
    }

    private func expandSelectedSeries() {
        guard let id = selectedMeetingID,
              let series = seriesGroups.series.first(where: { $0.meetings.contains { $0.id == id } }) else { return }
        expandedSeries.insert(series.id)
    }

    private var seriesList: some View {
        let groups = seriesGroups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if groups.series.isEmpty && !manager.isLoadingPage {
                    Text(searchText.isEmpty ? "No recurring meetings yet. Meetings with the same name — a weekly 1:1, a daily stand-up — are grouped here."
                                            : "No recurring meetings match.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                }
                ForEach(groups.series) { series in
                    seriesRow(series)
                    if expandedSeries.contains(series.id) {
                        ForEach(series.meetings) { meeting in
                            occurrenceRow(meeting)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                if !groups.oneOffs.isEmpty {
                    HStack {
                        Text("OTHER MEETINGS")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.8)
                            .foregroundColor(.white.opacity(0.3))
                        Spacer()
                        Text("\(groups.oneOffs.count)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.2))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    ForEach(groups.oneOffs) { meeting in
                        MeetingLibraryRow(meeting: meeting,
                                          isSelected: selectedMeetingID == meeting.id,
                                          isLive: session.isRecording && session.meetingID == meeting.id,
                                          processing: manager.processingPhase(for: meeting.id))
                            .onTapGesture { selectedMeetingID = meeting.id }
                            .contextMenu { deleteMenu(meeting) }
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func seriesRow(_ series: MeetingSeries.Series) -> some View {
        let expanded = expandedSeries.contains(series.id)
        let containsSelection = series.meetings.contains { $0.id == selectedMeetingID }
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                if expanded { expandedSeries.remove(series.id) } else { expandedSeries.insert(series.id) }
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color(hex: "8B5CF6").opacity(0.16))
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "A78BFA"))
                }
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(series.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(containsSelection ? 1 : 0.88))
                        .lineLimit(1)
                    Text("\(series.cadence.label()) · \(series.meetings.count) meetings")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(Self.shortDate(series.latest))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.3))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(expanded ? 0.04 : 0)))
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .uiTestFrame("notes.series.\(series.id)")
        .accessibilityLabel("\(series.title), \(series.cadence.label()), \(series.meetings.count) meetings")
    }

    private func occurrenceRow(_ meeting: MeetingListItem) -> some View {
        let selected = selectedMeetingID == meeting.id
        return HStack(spacing: 8) {
            Circle()
                .fill(selected ? Color(hex: "5B6CF7") : Color.white.opacity(0.18))
                .frame(width: 5, height: 5)
            Text(Self.occurrenceDate(meeting.createdAt))
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundColor(.white.opacity(selected ? 1 : 0.75))
            if meeting.duration > 0 {
                Text(meeting.displayDuration)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.38))
            }
            Spacer(minLength: 4)
            if session.isRecording && session.meetingID == meeting.id {
                Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundColor(.red)
            }
        }
        .padding(.leading, 46)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color(hex: "5B6CF7").opacity(0.12) : Color.clear))
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onTapGesture { selectedMeetingID = meeting.id }
        .contextMenu { deleteMenu(meeting) }
        .uiTestFrame("notes.occurrence.\(meeting.id.uuidString)")
    }

    @ViewBuilder
    private func deleteMenu(_ meeting: MeetingListItem) -> some View {
        Button("Delete…", role: .destructive) { pendingDelete = meeting }
            .disabled(session.isRecording && session.meetingID == meeting.id)
    }

    private static func shortDate(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "today"
            : Calendar.current.isDateInYesterday(date) ? "yesterday"
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func occurrenceDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · "
            + date.formatted(date: .omitted, time: .shortened)
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
                MeetingSourceIcon(bundleID: session.sourceBundleID,
                                  appName: session.sourceAppName,
                                  size: 13)
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

            HStack(spacing: 8) {
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

                MeetingCaptureControls(size: 26)
            }
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
                            .contextMenu { deleteMenu(meeting) }
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
                HStack(spacing: 5) {
                    MeetingSourceIcon(bundleID: meeting.sourceBundleID,
                                      appName: meeting.sourceAppName,
                                      size: 13)
                    Text(meeting.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isSelected ? .white : .white.opacity(0.85))
                        .lineLimit(1)
                    // Which AI wrote this meeting's notes, when it wasn't this Mac.
                    if let by = MeetingAIProvenance.lookup(meeting.id), let provider = by.provider {
                        Spacer(minLength: 4)
                        ProviderMark(provider: provider, size: 13)
                            .help("Notes by \(provider.displayName)")
                    }
                }

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
            // Unconditional and first: this is the one fact about the row that must never be
            // dropped by `ViewThatFits` probing narrower variants. A 58-minute meeting with
            // zero words is otherwise indistinguishable from one nobody has opened.
            if meeting.captureFailed {
                pill("Recording failed — no audio", icon: "exclamationmark.triangle.fill",
                     color: Color(hex: "EF4444"))
            }
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

/// A still waveform glyph for the recording card. It used to bounce forever, which keeps
/// WindowServer re-compositing the window for the whole meeting (see `KineticCaret`).
struct MiniWaveformView: View {
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<18, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.red.opacity(0.7))
                    .frame(width: 2, height: barHeight(i))
            }
        }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        let base: CGFloat = 4
        let max: CGFloat = 18
        let wave = sin(Double(i) * 0.7) * 0.5 + 0.5
        return base + CGFloat(wave) * (max - base)
    }
}
