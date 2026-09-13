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
    @ObservedObject private var refiner = MeetingTranscriptRefiner.shared
    let playheadSeconds: Double

    @State private var selectedTab: DetailTab = .transcript
    /// Held as @State (not @StateObject) so typing never invalidates this view's body.
    /// Only leaf views that need updates observe it directly as @ObservedObject.
    @State private var search = TranscriptSearchModel()
    @State private var editableTitle: String = ""
    @State private var showOverviewReadyToast = false
    /// The Overview tab has a summary the user has not looked at yet — drives the glowing dot.
    @State private var overviewIsUnread = false
    /// Render the pre-LLM ASR text. View-level only — nothing is written back.
    @State private var showOriginal = false
    /// Speaker cards vs continuous prose. View-level only, and deliberately not persisted:
    /// it is how you want to read *this* transcript right now, not a preference.
    @State private var transcriptMode: TranscriptMode = .speakers
    @State private var didCopy = false
    @State private var floatHovering = false
    /// Active speaker filter. Empty = show all. Multi-select: each index is a toggle.
    @State private var speakerFilter: Set<Int> = []
    /// Whether the inline re-transcribe panel is expanded.
    @State private var showRetranscribePanel = false
    /// Language selected in the re-transcribe panel — defaults to whatever was detected.
    @State private var retranscribeLanguage: TranscriptionLanguage = .auto

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
        applyOriginalToggle(liveOrPersistedSegments)
    }

    private var liveOrPersistedSegments: [MeetingSegment] {
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

    /// Substitute the stored raw ASR text at render time. Cheaper and safer than keeping two
    /// arrays around: the polished text stays the persisted truth, this is only a view.
    private func applyOriginalToggle(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        guard showOriginal else { return segments }
        return segments.map { seg in
            guard let raw = seg.rawText else { return seg }
            var copy = seg
            copy.text = raw
            return copy
        }
    }

    private var hasPolishedSegments: Bool {
        liveOrPersistedSegments.contains { $0.isPolished }
    }

    /// Every segment, not the page.
    ///
    /// `transcriptSegments` resolves to `detailVM.displayedSegments`, which is capped at 20 and
    /// grown by `MeetingTranscriptView`'s scroll. Neither consumer here scrolls that view: a
    /// "Full Text" that stops at segment 20 is not the full text, and a Copy that silently
    /// takes a fifth of the meeting is worse than no Copy at all.
    private var completeSegments: [MeetingSegment] {
        applyOriginalToggle(
            session.meetingID == meeting?.id && !session.segments.isEmpty
                && (session.isRecording || detailVM.allSegments.count < session.segments.count)
                ? session.segments
                : detailVM.allSegments
        )
    }

    /// What the transcript card list renders.
    ///
    /// When a speaker filter is active, pull from `completeSegments` (all pages) so every
    /// card for that speaker is visible immediately — a paged filter would show a fragment.
    /// When the filter is clear, fall back to the normal paginated `transcriptSegments` so
    /// the existing load-more behaviour is unchanged.
    private var filteredSegments: [MeetingSegment] {
        guard !speakerFilter.isEmpty else { return transcriptSegments }
        return completeSegments.filter { speakerFilter.contains($0.speakerIndex) }
    }

    /// Prose for the clipboard — still computed directly so it always reflects the current
    /// segments rather than a cached snapshot. Clipboard actions are rare; the cost is fine.
    private var plainProseForClipboard: String {
        MeetingTranscriptText.plainProse(from: completeSegments)
    }

    /// Prose for Full Text display — from the prose cache, avoiding recomputation on
    /// playhead ticks and other frequent re-renders.
    private var cachedProse: String {
        detailVM.updateProseCache(
            segments: completeSegments,
            showOriginal: showOriginal,
            languageCode: meeting?.language)
        return detailVM.cachedProse
    }

    /// RTL for Full Text — from the prose cache (computed alongside `cachedProse`).
    private var cachedIsRTL: Bool { detailVM.cachedIsRTL }

    /// The re-transcribe button is offered whenever the audio is still on disk and the meeting
    /// is not actively recording. The panel itself shows "Re-transcribing…" while a run is in
    /// flight; it does not suppress the button.
    private var canOpenRetranscribePanel: Bool {
        guard !session.isRecording else { return false }
        return MeetingTranscriptRefiner.shared.canForceRun(audioURL: meeting?.resolvedAudioURL)
    }

    /// A re-transcribe run is in flight for this specific meeting.
    private var isRetranscribing: Bool {
        refiner.activeMeetingID == meeting?.id || manager.processingPhase(for: meeting?.id) != nil
    }

    private var processingPhase: MeetingProcessingPhase? {
        manager.processingPhase(for: meeting?.id)
    }

    private var processingNotice: String? {
        manager.processingNotice(for: meeting?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            if detailVM.isLoading && meeting == nil {
                loadingState
            } else {
                meetingHeader
                tabBar
                tabContent
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: processingPhase)
        .background(Color(hex: "0C0C1A"))
        .onAppear { editableTitle = meeting?.title ?? "" }
        .onChange(of: detailVM.meeting?.id) { _, _ in
            editableTitle = meeting?.title ?? ""
            selectedTab = .transcript
            search.clear()
            showOriginal = false
            transcriptMode = .speakers
            didCopy = false
            overviewIsUnread = false
            speakerFilter = []
        }
        // Opening the tab *is* reading it — clear here rather than in the button so the
        // indicator cannot survive a programmatic switch (the toast) either.
        .onChange(of: selectedTab) { _, tab in
            guard tab == .overview, overviewIsUnread else { return }
            withAnimation(.easeInOut(duration: 0.25)) { overviewIsUnread = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingTitleDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == meeting?.id,
                  let title = notif.userInfo?["title"] as? String else { return }
            editableTitle = title
            detailVM.updateTitleInMemory(title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingSegmentsDidRefine)) { notif in
            guard let id = notif.object as? UUID, id == meeting?.id,
                  let refined = notif.userInfo?["segments"] as? [MeetingSegment] else { return }
            // The polish pass fires this exactly once, at the end of a run. Both sides of the
            // live→persisted handoff have to be updated or `transcriptSegments` keeps serving
            // whichever one was missed.
            withAnimation(.easeInOut(duration: 0.3)) {
                detailVM.applyRefinedSegments(refined)
                session.applyRefined(refined, meetingID: id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingOverviewDidGenerate)) { notif in
            guard let id = notif.object as? UUID, id == meeting?.id,
                  selectedTab != .overview else { return }
            // The toast is the two-second announcement; the dot is what remains after it,
            // so a summary that lands while the user is elsewhere is never lost.
            withAnimation(.easeInOut(duration: 0.25)) { overviewIsUnread = true }
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
            Text("View")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "5B6CF7"))
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
                MeetingSourceIcon(bundleID: meeting?.sourceBundleID,
                                  appName: meeting?.sourceAppName,
                                  size: 20)
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
                if canFloat { floatWindowButton }
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

                // Processing chip lives here so nothing below ever shifts when a phase
                // starts/ends. The chip fills the existing Spacer gap at no extra height cost.
                if let phase = processingPhase {
                    MeetingProcessingChip(
                        phase: phase,
                        progress: refiner.activeMeetingID == meeting?.id ? refiner.progress : nil
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
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

    /// Only offered when this meeting is the one the live window would show. The floating window
    /// binds a `MeetingSession` at construction, so there is nothing to float for a meeting the
    /// user merely selected in the library — and `show(session:)` would either warn and do nothing
    /// or put an empty session on screen. `meetingID` survives Stop deliberately, so the control
    /// stays available through naming and summarizing, which is exactly when the compact window is
    /// still worth having.
    private var canFloat: Bool {
        session.meetingID != nil && session.meetingID == meeting?.id
    }

    /// The mirror of the live window's "Open in Workspace": float the meeting and get the
    /// workspace out of the way. Same hand-over rule in the same order — the floating surface is
    /// up (which sets `meetingWindowIsVisible`) before the workspace goes away, so the HUD never
    /// flashes in the gap.
    ///
    /// `hideWindow()` orders out rather than closing, so `HistoryWindowManager`'s
    /// `willCloseNotification` observer does not run and the window comes back with its state
    /// intact.
    private var floatWindowButton: some View {
        Button {
            MeetingLiveWindowManager.shared.show(session: session)
            HistoryWindowManager.shared.hideWindow()
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "5B6CF7").opacity(floatHovering ? 0.28 : 0.15),
                                         Color(hex: "8B5CF6").opacity(floatHovering ? 0.28 : 0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .scaleEffect(floatHovering ? 1.08 : 1)
                .shadow(color: Color(hex: "5B6CF7").opacity(floatHovering ? 0.35 : 0),
                        radius: 6, y: 1)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Float over your call and hide the workspace")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) { floatHovering = hovering }
        }
    }

    private var speakerPills: some View {
        // Use speakerRoster (live-aware) instead of meeting?.uniqueSpeakers.
        // When a filter is active, sort selected speakers first so they are never
        // hidden behind the +N overflow.
        let speakers: [(index: Int, name: String)] = {
            let roster = speakerRoster
            guard !speakerFilter.isEmpty else { return roster }
            let selected = roster.filter { speakerFilter.contains($0.index) }
            let rest = roster.filter { !speakerFilter.contains($0.index) }
            return selected + rest
        }()
        let maxVisible = 4
        let visible = speakers.prefix(maxVisible)
        let overflow = speakers.dropFirst(maxVisible)
        let hasFilter = !speakerFilter.isEmpty

        return HStack(spacing: 4) {
            HStack(spacing: -6) {
                ForEach(Array(visible), id: \.index) { sp in
                    let color = speakerColor(for: sp.index)
                    let isSelected = speakerFilter.contains(sp.index)
                    let dimmed = hasFilter && !isSelected
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedTab = .transcript
                            if isSelected {
                                speakerFilter.remove(sp.index)
                            } else {
                                speakerFilter.insert(sp.index)
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(isSelected ? color.opacity(0.35) : color.opacity(0.25))
                                .overlay(
                                    Circle().stroke(
                                        isSelected ? color : Color(hex: "0C0C1A"),
                                        lineWidth: isSelected ? 1.5 : 2
                                    )
                                )
                                .frame(width: 26, height: 26)
                            Text(String(sp.name.prefix(1)))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(color)
                        }
                        .opacity(dimmed ? 0.35 : 1)
                        .zIndex(isSelected ? 1 : 0)
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "Stop filtering by \(sp.name)" : "Show only \(sp.name)")
                }

                if !overflow.isEmpty {
                    Menu {
                        ForEach(Array(overflow), id: \.index) { sp in
                            let isSelected = speakerFilter.contains(sp.index)
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedTab = .transcript
                                    if isSelected {
                                        speakerFilter.remove(sp.index)
                                    } else {
                                        speakerFilter.insert(sp.index)
                                    }
                                }
                            } label: {
                                Label(sp.name, systemImage: isSelected ? "checkmark" : "person")
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Circle().stroke(Color(hex: "0C0C1A"), lineWidth: 2))
                                .frame(width: 26, height: 26)
                            Text("+\(overflow.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
                }
            }

            // Clear-filter button — appears only when a filter is active.
            if hasFilter {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { speakerFilter = [] }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Clear speaker filter")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
                        // A tab label is a name, not prose — never wrap or hyphenate it
                        // when the centre column is narrow.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    if tab == .overview && overviewIsUnread {
                        OverviewReadyDot()
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                    if tab == .transcript && !detailVM.allSegments.isEmpty {
                        Text("\(detailVM.allSegments.count)")
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
                .foregroundColor(labelColor(for: tab))
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

    /// An unread tab sits between selected and dormant: bright enough to be an invitation,
    /// dim enough that the selected tab is still obviously the selected one.
    private func labelColor(for tab: DetailTab) -> Color {
        if selectedTab == tab { return .white }
        if tab == .overview && overviewIsUnread { return .white.opacity(0.8) }
        return .white.opacity(0.4)
    }

    /// Search, view mode, copy, and the polish controls. The polish controls only exist once
    /// there is something to control: no toggle before a run has produced raw/polished pairs,
    /// no manual action while one is running or while there is nothing left to clean.
    ///
    /// The search row is visible in both Speakers and Full Text mode: both views now support
    /// full search, highlight, navigation, and the tick gutter.
    private var transcriptToolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: search — always visible across both transcript modes
            TranscriptSearchRow(search: search)
                .frame(maxWidth: .infinity)

            // Row 2: view-mode toggles (max ~325px each row — safe at any allowed window size)
            HStack(spacing: 8) {
                modeToggle
                if hasPolishedSegments {
                    polishedToggle
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                Spacer(minLength: 0)
            }

            // Row 3: language badge + copy + re-transcribe button
            HStack(spacing: 8) {
                languageChip
                Spacer(minLength: 0)
                copyButton
                if canOpenRetranscribePanel {
                    retranscribeButton
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }

            // Inline re-transcribe panel (slides in below row 3)
            retranscribePanel
        }
        .animation(.easeInOut(duration: 0.2), value: hasPolishedSegments)
        .animation(.easeInOut(duration: 0.2), value: canOpenRetranscribePanel)
        .animation(.easeInOut(duration: 0.2), value: showRetranscribePanel)
        .animation(.easeInOut(duration: 0.2), value: transcriptMode)
    }

    /// Always visible, unlike the polish toggle — reading the transcript straight through is
    /// available whether or not a cleanup pass has ever run.
    private var modeToggle: some View {
        HStack(spacing: 2) {
            segmentedOption("Speakers", selected: transcriptMode == .speakers) {
                transcriptMode = .speakers
            }
            segmentedOption("Full Text", selected: transcriptMode == .fullText) {
                transcriptMode = .fullText
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .help("Switch between speaker-by-speaker cards and the transcript as plain text")
    }

    private var polishedToggle: some View {
        HStack(spacing: 2) {
            segmentedOption("Polished", selected: !showOriginal) { showOriginal = false }
            segmentedOption("Original", selected: showOriginal) { showOriginal = true }
        }
        .padding(2)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
        .help("Switch between the AI-cleaned transcript and the raw transcription")
    }

    private func segmentedOption(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.18)) { action() }
        }) {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundColor(selected ? .white : .white.opacity(0.45))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? Color(hex: "5B6CF7") : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    /// Copies whatever is on screen — labelled lines in Speakers mode, prose in Full Text.
    /// One control rather than two, so what you copy is always what you are looking at.
    private var copyButton: some View {
        Button(action: copyTranscript) {
            HStack(spacing: 5) {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                Text(didCopy ? "Copied" : "Copy")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(didCopy ? Color(hex: "10B981") : .white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(didCopy ? Color(hex: "10B981").opacity(0.12) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
        .disabled(completeSegments.isEmpty)
        .opacity(completeSegments.isEmpty ? 0.35 : 1)
        .help(transcriptMode == .fullText
              ? "Copy the whole transcript as plain text"
              : "Copy the transcript with speaker names and timestamps")
    }

    // MARK: - Language

    /// The language the transcript was actually decoded in.
    ///
    /// Read from the cards first and the meeting record second: the cards are rewritten in place
    /// by the refine pass and by a forced re-run, so they reflect the newest answer without
    /// waiting for the record to be re-fetched. `MeetingEntity.language` held the literal
    /// `"auto"` on every meeting until the timeline started writing it back, so it is the weaker
    /// of the two sources on older recordings.
    private var resolvedLanguage: TranscriptionLanguage {
        let fromSegments = MeetingAIService.dominantLanguage(of: detailVM.allSegments)
        if fromSegments != .auto { return fromSegments }
        if let raw = meeting?.language, let language = TranscriptionLanguage(rawValue: raw), language != .auto {
            return language
        }
        return .auto
    }

    /// Every language a card in this meeting was decoded in, dominant first. More than one entry
    /// means the timeline found a genuine code-switch.
    private var segmentLanguages: [TranscriptionLanguage] {
        var seen: [TranscriptionLanguage] = []
        for segment in detailVM.allSegments {
            guard let raw = segment.language, let language = TranscriptionLanguage(rawValue: raw),
                  language != .auto, !seen.contains(language) else { continue }
            seen.append(language)
        }
        return seen.sorted { $0 == resolvedLanguage && $1 != resolvedLanguage }
    }

    /// What the picker offers: the shortlist when language routing is on, otherwise everything
    /// this meeting already contains plus the full list, so a wrong detection is always fixable.
    private var languageOptions: [TranscriptionLanguage] {
        let routing = LanguageRoutingConfig.load()
        let base = routing.isRoutingEnabled
            ? routing.allowedLanguages
            : TranscriptionLanguage.allCases.filter { $0 != .auto }
        var options = segmentLanguages
        for language in base where !options.contains(language) { options.append(language) }
        return options
    }

    /// Shows the language the transcript was actually decoded in — read-only; the re-transcribe
    /// button and its panel are the action point. Named so the chip never looks interactive when
    /// the language was wrong; it is information, the panel is the fix.
    @ViewBuilder
    private var languageChip: some View {
        if resolvedLanguage != .auto || !detailVM.allSegments.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .semibold))
                Text(resolvedLanguage == .auto ? "Language" : resolvedLanguage.displayName)
                    .font(.system(size: 11, weight: .medium))
                if segmentLanguages.count > 1 {
                    Text("+\(segmentLanguages.count - 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .foregroundColor(.white.opacity(0.6))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .help(segmentLanguages.count > 1
                  ? "Spoken in \(segmentLanguages.map(\.displayName).joined(separator: ", ")). Use Re-transcribe to decode in a different language."
                  : "The language this transcript was decoded in. Use Re-transcribe to change it.")
        }
    }

    /// Opens the inline re-transcribe panel, pre-selecting the current detected language.
    private var retranscribeButton: some View {
        Button {
            retranscribeLanguage = resolvedLanguage
            withAnimation(.easeInOut(duration: 0.2)) { showRetranscribePanel = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                Text("Re-transcribe")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(Color(hex: "5B6CF7"))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(hex: "5B6CF7").opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(showRetranscribePanel)
        .help("Re-transcribe the whole recording — pick the language below to fix a wrong detection")
    }

    /// Inline panel that lets the user pick a language and kick off a full re-decode.
    @ViewBuilder
    private var retranscribePanel: some View {
        if showRetranscribePanel {
            VStack(alignment: .leading, spacing: 10) {
                // Language row
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hex: "5B6CF7").opacity(0.15))
                            .frame(width: 24, height: 24)
                        Image(systemName: "globe")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "5B6CF7"))
                    }

                    Text("Language")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Picker("", selection: $retranscribeLanguage) {
                        Text(TranscriptionLanguage.auto.displayName).tag(TranscriptionLanguage.auto)
                        Divider()
                        ForEach(languageOptions, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color(hex: "5B6CF7"))
                    .disabled(isRetranscribing)
                }

                // Action row
                HStack {
                    Button(action: startRetranscribe) {
                        HStack(spacing: 6) {
                            if isRetranscribing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.7)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(isRetranscribing ? "Re-transcribing…" : "Re-transcribe")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color(hex: "5B6CF7"), Color(hex: "7B5BF7")],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                        )
                        .shadow(color: Color(hex: "5B6CF7").opacity(0.25), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(isRetranscribing)

                    Spacer()

                    if !isRetranscribing {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showRetranscribePanel = false }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Start a re-transcribe run from the panel selection.
    ///
    /// No `language != resolvedLanguage` guard — `resolvedLanguage` is only as honest as the
    /// stamps on the cards; a wrongly decoded pass may stamp the wrong language, so re-picking
    /// the same language must still trigger a new run.
    private func startRetranscribe() {
        guard let id = meeting?.id else { return }
        let segments = detailVM.allSegments
        let audioURL = meeting?.resolvedAudioURL
        let language = retranscribeLanguage
        Task {
            if language == .auto {
                MeetingTranscriptRefiner.shared.start(meetingID: id, segments: segments,
                                                      audioURL: audioURL, redoAll: true)
            } else {
                await MeetingManager.shared.updateLanguage(meetingID: id, language: language.rawValue)
                MeetingTranscriptRefiner.shared.start(meetingID: id, segments: segments,
                                                      audioURL: audioURL, forcedLanguage: language)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .transcript:
            VStack(spacing: 0) {
                transcriptToolbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "0C0C1A"))

                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 1)

                Group {
                    switch transcriptMode {
                    case .speakers:
                        MeetingTranscriptView(
                            meeting: meeting,
                            session: session,
                            segments: filteredSegments,
                            speakerRoster: speakerRoster,
                            isLoadingSegments: detailVM.isLoading,
                            hasMoreSegments: speakerFilter.isEmpty && detailVM.hasMoreSegments,
                            onLoadMoreSegments: detailVM.loadMoreSegments,
                            search: search,
                            playheadSeconds: playheadSeconds,
                            visibleSpeakerIndices: speakerFilter,
                            onSpeakerRenamed: { speakerIndex, name in
                                Task { await handleSpeakerRename(speakerIndex: speakerIndex, newName: name) }
                            },
                            onTagToggled: { segID, tag in
                                Task { await handleTagToggle(segID: segID, tag: tag) }
                            }
                        )
                    case .fullText:
                        fullTextContent
                    }
                }
                .overlay(alignment: cachedIsRTL ? .leading : .trailing) {
                    // Tick gutter — 10 pt canvas showing every match's vertical position.
                    // Tapping a tick jumps to that match. RTL mirrors to the leading edge.
                    TranscriptMatchTicks(search: search, isRTL: cachedIsRTL)
                        .padding(.vertical, 8)
                }
            }
        case .overview:
            MeetingOverviewView(meeting: meeting)
        }
    }

    @ViewBuilder
    private var fullTextContent: some View {
        let prose = cachedProse
        if prose.isEmpty {
            fullTextEmptyState
        } else {
            MeetingFullTranscriptView(text: prose, isRTL: cachedIsRTL, search: search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: "0C0C1A"))
        }
    }

    private var fullTextEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.white.opacity(0.15))
            Text("No transcript yet")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0C0C1A"))
    }

    // MARK: - Actions

    /// Full speaker roster built from all segments (not just the paged window) so conflict
    /// checks are always complete even in long meetings.
    private var speakerRoster: [(index: Int, name: String)] {
        var seen: Set<Int> = []
        var result: [(Int, String)] = []
        // Prefer live session segments while recording; fall back to all persisted segments.
        let source = (session.isRecording && session.meetingID == meeting?.id)
            ? session.segments
            : detailVM.allSegments
        for seg in source where !seen.contains(seg.speakerIndex) {
            seen.insert(seg.speakerIndex)
            result.append((seg.speakerIndex, seg.speakerName))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private func handleSpeakerRename(speakerIndex: Int, newName: String) async {
        guard let meetingID = meeting?.id else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Defensive guard — UI should have blocked this already.
        guard SpeakerNaming.conflictingName(for: trimmed,
                                            in: speakerRoster,
                                            excluding: speakerIndex) == nil else { return }

        // Rename every segment this speaker owns — keyed by index so two speakers that share
        // a name are always updated independently.
        detailVM.renameSpeakerInMemory(index: speakerIndex, to: trimmed)
        await MeetingManager.shared.renameSpeaker(meetingID: meetingID,
                                                   speakerIndex: speakerIndex,
                                                   newName: trimmed)
        if session.meetingID == meetingID {
            session.updateSpeaker(speakerIndex: speakerIndex, newName: trimmed)
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

    /// Copies exactly what the current mode renders. Splitting this into two controls would let
    /// the button and the screen drift; both shapes come from `MeetingTranscriptText`.
    private func copyTranscript() {
        let segments = completeSegments
        guard !segments.isEmpty else { return }
        let text = transcriptMode == .fullText
            ? plainProseForClipboard
            : MeetingTranscriptText.labelled(from: segments)
        guard !text.isEmpty else { return }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(.easeInOut(duration: 0.15)) { didCopy = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeInOut(duration: 0.15)) { didCopy = false }
        }
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

/// How the Transcript tab renders. A view mode rather than a third `DetailTab`: it is the same
/// content, and putting it beside Overview would imply otherwise.
enum TranscriptMode {
    /// Speaker-grouped cards with timestamps, tags and rename — the review surface.
    case speakers
    /// Continuous prose. No names, no timestamps: for reading it through or taking the lot.
    case fullText
}
