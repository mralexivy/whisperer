//
//  MeetingDetailView.swift
//  Whisperer
//
//  Center column: editable title, tab bar (Transcript / Overview), content.
//

import SwiftUI

struct MeetingDetailView: View {
    @ObservedObject var detailVM: MeetingDetailViewModel
    @ObservedObject var session: MeetingSession
    @ObservedObject private var manager = MeetingManager.shared
    let playheadSeconds: Double

    @State private var selectedTab: DetailTab = .transcript
    @State private var searchQuery = ""
    @State private var editableTitle: String = ""
    @State private var showOverviewReadyToast = false

    // Convenience shorthand — nil while loading
    private var meeting: MeetingRecord? { detailVM.meeting }

    // Segments routed to transcript: live from session, historical from paginated detailVM.
    //
    // The handoff has to overlap. `isRecording` flips to false the instant the user hits
    // stop, but detailVM's copy is still whatever was fetched when the (then empty) meeting
    // was selected — switching sources on that flag alone blanks the transcript until the
    // CoreData round-trip lands. The session deliberately keeps meetingID and segments after
    // stop, so keep rendering them until detailVM has caught up.
    private var transcriptSegments: [MeetingSegment] {
        guard session.meetingID == meeting?.id, !session.segments.isEmpty else {
            return detailVM.displayedSegments
        }
        if session.isRecording { return session.segments }
        // Compare against allSegments, not displayedSegments — the latter is capped at one
        // page, so a long meeting would otherwise never hand over.
        return detailVM.allSegments.count >= session.segments.count
            ? detailVM.displayedSegments
            : session.segments
    }

    private var processingPhase: MeetingProcessingPhase? {
        manager.processingPhase(for: meeting?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if detailVM.isLoading && meeting == nil {
                loadingState
            } else {
                meetingHeader
                tabBar
                if let phase = processingPhase {
                    MeetingProcessingBanner(phase: phase)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                tabContent
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: processingPhase)
        .background(Color(hex: "0C0C1A"))
        .onAppear { editableTitle = meeting?.title ?? "" }
        .onChange(of: detailVM.meeting?.id) { _, _ in
            editableTitle = meeting?.title ?? ""
            selectedTab = .transcript
            searchQuery = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingTitleDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == meeting?.id,
                  let title = notif.userInfo?["title"] as? String else { return }
            editableTitle = title
            detailVM.updateTitleInMemory(title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingOverviewDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == meeting?.id,
                  selectedTab != .overview else { return }
            withAnimation(.spring(response: 0.3)) { showOverviewReadyToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) { showOverviewReadyToast = false }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showOverviewReadyToast {
                overviewReadyToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 20)
            }
        }
    }

    // MARK: - Loading state (skeleton)

    private var loadingState: some View {
        VStack(spacing: 0) {
            // Header skeleton
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SkeletonRect()
                        .frame(width: 200, height: 22)
                    Spacer()
                    SkeletonRect()
                        .frame(width: 64, height: 22)
                }
                HStack(spacing: 10) {
                    SkeletonRect()
                        .frame(width: 120, height: 14)
                    SkeletonRect()
                        .frame(width: 60, height: 14)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)

            // Segment skeletons
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { i in
                        MeetingSegmentSkeleton(seed: i)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var overviewReadyToast: some View {
        HStack(spacing: 8) {
            Text("✦")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "5B6CF7"))
            Text("Overview ready")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(hex: "14142B"))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(hex: "5B6CF7").opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        .onTapGesture {
            withAnimation(.spring(response: 0.3)) { showOverviewReadyToast = false }
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = .overview }
        }
    }

    // MARK: - Header

    private var meetingHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Meeting title", text: $editableTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if let id = meeting?.id {
                            Task {
                                await MeetingManager.shared.updateTitle(meetingID: id, title: editableTitle)
                                detailVM.updateTitleInMemory(editableTitle)
                            }
                        }
                    }

                if session.isRecording && session.meetingID == meeting?.id {
                    liveBadge
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                Spacer()
                exportButton
            }

            HStack(spacing: 12) {
                Text(meeting?.formattedDate ?? "")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white.opacity(0.4))

                if let duration = meeting?.duration, duration > 0 {
                    Text("·")
                        .foregroundColor(.white.opacity(0.2))
                    Text(meeting?.displayDuration ?? "")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()
                speakerPills
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(hex: "0C0C1A"))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: processingPhase)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: session.isRecording)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
        }
        .foregroundColor(Color.red)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.red.opacity(0.12))
        .clipShape(Capsule())
    }

    private var exportButton: some View {
        Button {
            exportTranscript()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var speakerPills: some View {
        let speakers = meeting?.uniqueSpeakers ?? []
        return HStack(spacing: -6) {
            ForEach(speakers.prefix(4), id: \.index) { sp in
                ZStack {
                    Circle()
                        .fill(speakerColor(for: sp.index).opacity(0.25))
                        .overlay(Circle().stroke(Color(hex: "0C0C1A"), lineWidth: 2))
                        .frame(width: 26, height: 26)
                    Text(String(sp.name.prefix(1)))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(speakerColor(for: sp.index))
                }
            }
            if speakers.count > 4 {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Circle().stroke(Color(hex: "0C0C1A"), lineWidth: 2))
                        .frame(width: 26, height: 26)
                    Text("+\(speakers.count - 4)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(DetailTab.allCases) { tab in
                    tabButton(tab)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 0)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
        .background(Color(hex: "0C0C1A"))
    }

    private func tabButton(_ tab: DetailTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(tab.label)
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .medium))
                    if tab == .transcript && !detailVM.allSegments.isEmpty {
                        Text("\(detailVM.allSegments.count)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(selectedTab == tab ? Color(hex: "5B6CF7") : .white.opacity(0.3))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(
                                    selectedTab == tab ? Color(hex: "5B6CF7").opacity(0.15) : Color.white.opacity(0.06)
                                )
                            )
                    }
                }
                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.4))
                .padding(.horizontal, 4)
                .padding(.vertical, 10)

                Rectangle()
                    .fill(selectedTab == tab ? Color(hex: "5B6CF7") : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 20)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
            TextField("Search transcript…", text: $searchQuery)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .transcript:
            VStack(spacing: 0) {
                searchField
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "0C0C1A"))

                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 1)

                MeetingTranscriptView(
                    meeting: meeting,
                    session: session,
                    segments: transcriptSegments,
                    isLoadingSegments: detailVM.isLoading,
                    hasMoreSegments: detailVM.hasMoreSegments,
                    onLoadMoreSegments: detailVM.loadMoreSegments,
                    searchQuery: searchQuery,
                    playheadSeconds: playheadSeconds,
                    onSpeakerRenamed: { segID, name in
                        Task { await handleSpeakerRename(segID: segID, newName: name) }
                    },
                    onTagToggled: { segID, tag in
                        Task { await handleTagToggle(segID: segID, tag: tag) }
                    }
                )
            }
        case .overview:
            MeetingOverviewView(meeting: meeting)
        }
    }

    // MARK: - Actions

    private func handleSpeakerRename(segID: UUID, newName: String) async {
        guard let meetingID = meeting?.id,
              let seg = detailVM.allSegments.first(where: { $0.id == segID }) else { return }
        var updated = seg
        updated.speakerName = newName
        detailVM.updateSegmentInMemory(updated)
        await MeetingManager.shared.updateSegment(meetingID: meetingID, segment: updated)
        if session.isRecording && session.meetingID == meeting?.id {
            session.updateSpeaker(segmentID: segID, newName: newName)
        }
    }

    private func handleTagToggle(segID: UUID, tag: SegmentTag) async {
        guard let meetingID = meeting?.id,
              var seg = detailVM.allSegments.first(where: { $0.id == segID }) else { return }
        if seg.tags.contains(tag) {
            seg.tags.removeAll { $0 == tag }
        } else {
            seg.tags.append(tag)
        }
        detailVM.updateSegmentInMemory(seg)
        await MeetingManager.shared.updateSegment(meetingID: meetingID, segment: seg)
    }

    private func exportTranscript() {
        let segs = meeting?.segments ?? detailVM.allSegments
        let text = segs.map { "[\(formatTS($0.timestamp))] \($0.speakerName): \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func formatTS(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Tabs

enum DetailTab: String, CaseIterable, Identifiable {
    case transcript, overview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .overview:   return "Overview"
        }
    }
}
