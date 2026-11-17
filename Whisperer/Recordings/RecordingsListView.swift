//
//  RecordingsListView.swift
//  Whisperer
//
//  The mixed list: dictations, meetings and imported files together, newest first, grouped by day.
//

import SwiftUI

struct RecordingsListView: View {
    @ObservedObject var model: RecordingsWorkspaceModel
    @ObservedObject var session: MeetingSession
    @State private var pendingDelete: RecordingListItem?
    @FocusState private var searchFocused: Bool

    private var groups: [(title: String, items: [RecordingListItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.items) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (Self.dayTitle(day), grouped[day]!)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField.padding(.horizontal, 16)
            kindTabs.padding(.horizontal, 16).padding(.top, 12)
            marksRow.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            list
        }
        .background(Color(hex: "0C0C1A"))
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { item in
            Button("Delete “\(item.title)”", role: .destructive) { Task { await model.delete(item.id) } }
        } message: { _ in
            Text("The transcript, its audio and any AI chat are removed from this Mac. This can't be undone.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Recordings").font(.system(size: 24, weight: .semibold)).foregroundColor(.white)
            Text("\(model.totalCount)")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Color.white.opacity(0.6))
                .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(WhispererColors.cardBackground(.dark)))
            Spacer()
            NewRecordingButton(model: model, session: session)
        }
        .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
            TextField("Search recordings", text: $model.searchText)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(.white)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Color.white.opacity(0.35))
                }.buttonStyle(.plain)
            } else {
                Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundColor(Color.white.opacity(0.35))
                    .padding(.horizontal, 5).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).fill(WhispererColors.cardBackground(.dark)))
            }
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhispererColors.cardBackground(.dark)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(searchFocused ? WhispererColors.accent.opacity(0.6) : Color.white.opacity(0.07), lineWidth: 1))
        .background(Button("") { searchFocused = true }.keyboardShortcut("k", modifiers: .command).opacity(0))
        .uiTestFrame("recordings.search")
    }

    private var kindTabs: some View {
        HStack(spacing: 2) {
            ForEach(RecordingsWorkspaceModel.KindFilter.allCases) { filter in
                Button { model.kindFilter = filter } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: model.kindFilter == filter ? .semibold : .medium))
                        .foregroundColor(model.kindFilter == filter ? .white : Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.kindFilter == filter ? Color.white.opacity(0.10) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.kindFilter == filter ? .isSelected : [])
                .uiTestFrame("recordings.filter.\(filter.rawValue.lowercased())")
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WhispererColors.cardBackground(.dark)))
    }

    private var marksRow: some View {
        HStack(spacing: 6) {
            Text("Newest first").font(.system(size: 12, weight: .medium)).foregroundColor(Color.white.opacity(0.5))
            Spacer()
            markToggle(.pinned, "pin")
            markToggle(.flagged, "flag")
        }
    }

    private func markToggle(_ mark: RecordingsWorkspaceModel.MarkFilter, _ symbol: String) -> some View {
        let on = model.markFilter == mark
        return Button { model.markFilter = on ? .none : mark } label: {
            Image(systemName: on ? "\(symbol).fill" : symbol).font(.system(size: 12))
                .foregroundColor(on ? WhispererColors.accent : Color.white.opacity(0.45))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(on ? 0.10 : 0)))
        }
        .buttonStyle(.plain).help(mark == .pinned ? "Show pinned only" : "Show flagged only")
        .accessibilityLabel(mark == .pinned ? "Pinned only" : "Flagged only")
    }

    // MARK: List

    private var list: some View {
        Group {
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.system(size: 26, weight: .light)).foregroundColor(Color.white.opacity(0.25))
                    Text(model.searchText.isEmpty ? "No recordings yet" : "Nothing matches “\(model.searchText)”")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(Color.white.opacity(0.45))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                        ForEach(groups, id: \.title) { group in
                            HStack(spacing: 6) {
                                Text(group.title.uppercased()).font(.system(size: 10, weight: .bold)).tracking(1.0)
                                    .foregroundColor(Color.white.opacity(0.35))
                                Text("\(group.items.count)").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.25))
                            }.padding(.horizontal, 22).padding(.top, 12).padding(.bottom, 2)
                            ForEach(group.items) { item in
                                RecordingRow(item: item, isSelected: model.selectedID == item.id && !model.isImporting,
                                             query: model.searchText.trimmingCharacters(in: .whitespaces))
                                    .onTapGesture { model.open(item.id) }
                                    .contextMenu { menu(for: item) }
                                    .onAppear { model.loadMoreIfNeeded(after: item) }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder private func menu(for item: RecordingListItem) -> some View {
        Button(item.isPinned ? "Unpin" : "Pin") { model.togglePin(item) }
        Button(item.isFlagged ? "Remove flag" : "Flag") { model.toggleFlag(item) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = item }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return f.string(from: day)
    }
}

private struct RecordingRow: View {
    let item: RecordingListItem
    let isSelected: Bool
    var query: String? = nil
    @State private var hovering = false
    @ObservedObject private var meetings = MeetingManager.shared

    @AppStorage("timeFormat") private var timeFormat = "12h"

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            RecordingKindBadge(kind: item.kind, size: 36, selected: isSelected)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(RecordingSnippet.highlighted(item.title, query: query)).font(.system(size: 14, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(WhispererColors.accent) }
                    if item.isFlagged { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundColor(.orange) }
                    if item.isInProgress { LivePill() }
                }
                if !item.preview.isEmpty {
                    Text(RecordingSnippet.highlighted(item.preview, query: query)).font(.system(size: 13)).foregroundColor(Color.white.opacity(0.5)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(item.kind.plural).foregroundColor(item.kind.tint.opacity(0.9))
                    if item.captureFailed {
                        Label("No audio", systemImage: "exclamationmark.triangle.fill").labelStyle(.titleAndIcon)
                            .foregroundColor(Color(hex: "EF4444"))
                    } else if item.kind == .meeting, let phase = meetings.processingPhases[item.id.uuid] {
                        Label(phase.shortLabel, systemImage: "sparkles").foregroundColor(WhispererColors.accentPurple)
                    }
                    Text("·")
                    Text(RecordingTimeFormat.string(item.date, setting: timeFormat))
                    Spacer()
                    if item.duration > 0 { Text(FileTranscriptClock.format(item.duration)).monospacedDigit() }
                }
                .font(.system(size: 10.5, weight: .medium)).foregroundColor(Color.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(isSelected ? WhispererColors.cardBackground(.dark) : WhispererColors.cardBackground(.dark).opacity(hovering ? 0.6 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(isSelected ? Color.white.opacity(0.12) : .clear, lineWidth: 1))
        .overlay(alignment: .leading) {
            if isSelected { Capsule().fill(WhispererColors.accent).frame(width: 2.5).padding(.vertical, 10).offset(x: 1) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .uiTestFrame("recordings.row.\(item.id.uuid.uuidString)")
    }
}


/// A recording in progress: a pulsing red dot and the word, so a live meeting is unmistakable in the list.
struct LivePill: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
                .opacity(pulse && !reduceMotion ? 0.35 : 1)
            Text("LIVE").font(.system(size: 9, weight: .bold)).tracking(0.6)
        }
        .foregroundColor(Color.red.opacity(0.95))
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(Color.red.opacity(0.12)))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Recording now")
    }
}
