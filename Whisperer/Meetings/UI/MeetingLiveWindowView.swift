//
//  MeetingLiveWindowView.swift
//  Whisperer
//
//  Root view of the floating meeting window — header, tabs, live content, footer.
//

import AppKit
import SwiftUI

/// Tabs of the floating window. A parallel enum rather than a `notes` case bolted onto
/// `MeetingDetailView.DetailTab`: that enum drives the workspace's tab bar through
/// `allCases`, and the workspace is not being changed. Labels are kept identical on purpose.
enum MeetingLiveTab: String, CaseIterable, Identifiable {
    case transcript, notes, overview
    var id: String { rawValue }
    var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .notes:      return "Notes"
        case .overview:   return "Overview"
        }
    }
}

struct MeetingLiveWindowView: View {
    @ObservedObject var session: MeetingSession
    var onClose: () -> Void
    var onCollapseChanged: (Bool) -> Void

    @StateObject private var detailVM = MeetingDetailViewModel()
    @ObservedObject private var manager = MeetingManager.shared
    @ObservedObject private var refiner = MeetingTranscriptRefiner.shared

    @State private var selectedTab: MeetingLiveTab = .transcript
    @State private var editableTitle = ""
    @State private var isCollapsed = false
    @State private var showOverviewReadyToast = false
    @State private var didCopy = false
    @State private var closeHovering = false
    @State private var collapseHovering = false

    private var meeting: MeetingRecord? { detailVM.meeting }

    var body: some View {
        VStack(spacing: 0) {
            header

            if !isCollapsed {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                tabBar

                if let phase = processingPhase {
                    MeetingProcessingBanner(
                        phase: phase,
                        // Only the polish pass counts anything, and only for its own meeting.
                        progress: refiner.activeMeetingID == meeting?.id ? refiner.progress : nil,
                        notice: processingNotice
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    // The insert slides down from above its own slot, which crosses the tab bar
                    // and the first transcript card on its way in. Without an explicit z-order
                    // the siblings win that overlap and the banner is drawn cut in half for the
                    // length of the spring.
                    .zIndex(1)
                }

                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)

                footer
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: processingPhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(hex: "0C0C1A"))
        // Rounded here, not on the hosting layer — CoreAnimation clipping triggers the Tahoe
        // text compositing bug. See MeetingLiveWindow.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if showOverviewReadyToast {
                overviewReadyToast
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 60)
            }
        }
        .onAppear { loadMeeting() }
        .onChange(of: session.meetingID) { _, _ in loadMeeting() }
        // Same triggers MeetingStudioView uses: the second one catches the tail chunk that lands
        // after stopRecording() has already returned.
        .onChange(of: session.isRecording) { _, _ in Task { await detailVM.refreshDetail() } }
        .onChange(of: session.segments.count) { _, _ in Task { await detailVM.refreshDetail() } }
        .onReceive(NotificationCenter.default.publisher(for: .meetingTitleDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == session.meetingID,
                  let title = notif.userInfo?["title"] as? String else { return }
            editableTitle = title
            detailVM.updateTitleInMemory(title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingSegmentsDidRefine)) { notif in
            guard let id = notif.object as? UUID, id == session.meetingID,
                  let refined = notif.userInfo?["segments"] as? [MeetingSegment] else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                detailVM.applyRefinedSegments(refined)
                session.applyRefined(refined, meetingID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingOverviewDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == session.meetingID else { return }
            // The whole point of keeping the window open after Stop: the summary arrives here.
            if selectedTab == .overview { return }
            withAnimation(.easeInOut(duration: 0.2)) { selectedTab = .overview }
            withAnimation(.spring(response: 0.3)) { showOverviewReadyToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) { showOverviewReadyToast = false }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if session.isRecording {
                liveBadge
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "5B6CF7"))
            }

            TextField("Untitled", text: $editableTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .onSubmit(commitTitle)

            Spacer(minLength: 4)

            iconButton(systemName: isCollapsed ? "chevron.down" : "chevron.up",
                       hovering: $collapseHovering,
                       help: isCollapsed ? "Expand" : "Collapse") {
                isCollapsed.toggle()
                onCollapseChanged(isCollapsed)
            }

            iconButton(systemName: "xmark", hovering: $closeHovering, help: "Close") {
                commitTitle()
                onClose()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        .background(Color(hex: "0C0C1A"))
        // The drag surface. `isMovableByWindowBackground` covers the rest of the body, but the
        // header is where a titlebar-less window is expected to be grabbed.
        .contentShape(Rectangle())
    }

    /// Copied from `MeetingDetailView.liveBadge` so the two surfaces read identically.
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

    private func iconButton(systemName: String,
                            hovering: Binding<Bool>,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(hovering.wrappedValue ? 0.85 : 0.35))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(Color.white.opacity(hovering.wrappedValue ? 0.08 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering.wrappedValue = $0 }
    }

    // MARK: - Tab bar (identical treatment to MeetingDetailView.tabBar)

    private var tabBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(MeetingLiveTab.allCases) { tab in
                    tabButton(tab)
                }
                Spacer()
            }
            .padding(.horizontal, 14)

            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
        }
        .background(Color(hex: "0C0C1A"))
    }

    private func tabButton(_ tab: MeetingLiveTab) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 5) {
                    Text(tab.label)
                        .font(.system(size: 13, weight: selectedTab == tab ? .semibold : .medium))
                        // A tab label is a name, not prose — never wrap or hyphenate it
                        // when the rail is narrow ("Transcript" broke to "Transcrip/t").
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if let count = count(for: tab), count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
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
        .padding(.trailing, 16)
    }

    private func count(for tab: MeetingLiveTab) -> Int? {
        switch tab {
        case .transcript: return transcriptSegments.count
        case .notes:      return liveNotes.count
        case .overview:   return nil
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .transcript:
            MeetingLiveTranscriptView(session: session,
                                      meeting: meeting,
                                      segments: transcriptSegments)
        case .notes:
            LiveNotesPane(session: session, meeting: meeting)
        case .overview:
            MeetingOverviewView(meeting: meeting)
        }
    }

    /// Same handoff rule as `MeetingDetailView`: keep rendering the live array until the
    /// persisted copy has caught up, comparing against `allSegments` (the displayed window is
    /// capped at one page, so a long meeting would otherwise never hand over).
    private var transcriptSegments: [MeetingSegment] {
        guard session.meetingID == meeting?.id, !session.segments.isEmpty else {
            return detailVM.displayedSegments
        }
        if session.isRecording { return session.segments }
        return detailVM.allSegments.count >= session.segments.count
            ? detailVM.displayedSegments
            : session.segments
    }

    private var liveNotes: [MeetingNote] {
        if session.isRecording && session.meetingID == meeting?.id { return session.notes }
        return meeting?.notes ?? []
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if session.isRecording {
                stopButton
            } else {
                openInWorkspaceButton
            }

            Spacer(minLength: 8)

            if session.isRecording {
                Text(session.elapsedDisplay)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .monospacedDigit()
            }

            Button(action: copyTranscript) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(didCopy ? Color(hex: "10B981") : .white.opacity(0.45))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.white.opacity(0.05)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Copy transcript")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Color(hex: "0C0C1A"))
    }

    private var stopButton: some View {
        Button {
            AppState.shared.stopActiveRecording()
        } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
                Text("Stop")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color.red.opacity(0.85))
            )
        }
        .buttonStyle(.plain)
        .help("Stop recording")
    }

    /// Trade this window for the workspace — the mirror of `MeetingDetailView.floatWindowButton`.
    ///
    /// Hand over, don't duplicate. Leaving this window floating over the workspace put two views
    /// of the same meeting on screen, and the one still on top was the compact one. Order
    /// matters: the workspace must be up before the close, because `HistoryWindowManager`'s
    /// close observer keys the HUD hand-back off `meetingWindowIsVisible`.
    private func openInWorkspace() {
        commitTitle()
        HistoryWindowManager.shared.showWindow()
        NotificationCenter.default.post(name: .switchToMeetingStudioTab, object: nil)
        MeetingLiveWindowManager.shared.close()
    }

    private var openInWorkspaceButton: some View {
        Button(action: openInWorkspace) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open in Workspace")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }

    /// Copied from `MeetingDetailView.overviewReadyToast` — same wording, same capsule.
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
        }
    }

    // MARK: - Processing state

    private var processingPhase: MeetingProcessingPhase? {
        manager.processingPhase(for: session.meetingID)
    }

    private var processingNotice: String? {
        manager.processingNotice(for: session.meetingID)
    }

    // MARK: - Actions

    private func loadMeeting() {
        guard let id = session.meetingID else { return }
        Task {
            await detailVM.load(meetingID: id)
            // Only adopt the fetched title if the user is not mid-edit in the field.
            if editableTitle.isEmpty { editableTitle = detailVM.meeting?.title ?? "" }
        }
    }

    private func commitTitle() {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = session.meetingID, !trimmed.isEmpty, trimmed != meeting?.title else { return }
        detailVM.updateTitleInMemory(trimmed)
        Task { await MeetingManager.shared.updateTitle(meetingID: id, title: trimmed) }
    }

    private func copyTranscript() {
        // Same rendering as the workspace's Speakers-mode Copy — one implementation, so the two
        // surfaces cannot produce different text for the same meeting.
        let text = MeetingTranscriptText.labelled(from: transcriptSegments)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { didCopy = false }
        }
    }
}
