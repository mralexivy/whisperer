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
    @State private var searchQuery = ""
    @State private var editableTitle: String = ""
    @State private var showOverviewReadyToast = false
    /// Render the pre-LLM ASR text. View-level only — nothing is written back.
    @State private var showOriginal = false
    /// Speaker cards vs continuous prose. View-level only, and deliberately not persisted:
    /// it is how you want to read *this* transcript right now, not a preference.
    @State private var transcriptMode: TranscriptMode = .speakers
    @State private var didCopy = false
    @State private var floatHovering = false

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

    /// The prose rendering, shared by the Full Text view and the clipboard so the two cannot
    /// disagree. The Polished/Original choice flows through `completeSegments`.
    private var plainProse: String {
        MeetingTranscriptText.plainProse(from: completeSegments)
    }

    /// Content decides direction; the configured language is only the fallback when there is
    /// no text yet. Same rule as `MeetingTranscriptView`.
    private var isRTL: Bool {
        let sample = completeSegments.prefix(3)
            .map { $0.text.prefix(150) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sample.isEmpty {
            return MeetingTranscriptText.isRightToLeft(sample: String(sample.prefix(150)))
        }
        if let lang = TranscriptionLanguage(rawValue: meeting?.language ?? ""), lang != .auto {
            return lang.isRTL
        }
        return false
    }

    /// The manual re-transcribe action is offered only when there is something left to correct,
    /// the recording is still on disk, and no run is already in flight for this meeting.
    private var canPolishManually: Bool {
        guard let id = meeting?.id, !session.isRecording else { return false }
        guard refiner.activeMeetingID == nil, manager.processingPhase(for: id) == nil else { return false }
        return MeetingTranscriptRefiner.shared.shouldRun(for: detailVM.allSegments,
                                                         audioURL: meeting?.resolvedAudioURL)
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
                if let phase = processingPhase {
                    MeetingProcessingBanner(
                        phase: phase,
                        // Only the polish pass counts anything, and only for its own meeting.
                        progress: refiner.activeMeetingID == meeting?.id ? refiner.progress : nil,
                        notice: processingNotice
                    )
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
            showOriginal = false
            transcriptMode = .speakers
            didCopy = false
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
                        // A tab label is a name, not prose — never wrap or hyphenate it
                        // when the centre column is narrow.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
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

    /// Search, view mode, copy, and the polish controls. The polish controls only exist once
    /// there is something to control: no toggle before a run has produced raw/polished pairs,
    /// no manual action while one is running or while there is nothing left to clean.
    ///
    /// Search is dropped in Full Text mode. `searchQuery` drives per-segment highlighting
    /// inside `SelectableTranscriptView`, which the prose path does not use — a search box
    /// that silently does nothing is worse than no search box.
    private var transcriptToolbar: some View {
        HStack(spacing: 8) {
            if transcriptMode == .speakers {
                searchField
                    .frame(maxWidth: 280)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }

            Spacer(minLength: 8)

            modeToggle
            if hasPolishedSegments {
                polishedToggle
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            copyButton
            if canPolishManually {
                cleanUpButton
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: hasPolishedSegments)
        .animation(.easeInOut(duration: 0.2), value: canPolishManually)
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

    private var cleanUpButton: some View {
        Button {
            guard let id = meeting?.id else { return }
            MeetingTranscriptRefiner.shared.start(meetingID: id, segments: detailVM.allSegments,
                                                  audioURL: meeting?.resolvedAudioURL)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                Text("Re-transcribe")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(Color(hex: "5B6CF7"))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(hex: "5B6CF7").opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Re-transcribe the recording with a more accurate model to fix misheard words and punctuation")
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

                switch transcriptMode {
                case .speakers:
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
                case .fullText:
                    fullTextContent
                }
            }
        case .overview:
            MeetingOverviewView(meeting: meeting)
        }
    }

    @ViewBuilder
    private var fullTextContent: some View {
        let prose = plainProse
        if prose.isEmpty {
            fullTextEmptyState
        } else {
            MeetingFullTranscriptView(text: prose, isRTL: isRTL)
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

    private func handleSpeakerRename(segID: UUID, newName: String) async {
        guard let meetingID = meeting?.id else { return }
        // Live segments live on the session until CoreData catches up, so the segment being
        // renamed may exist in either collection.
        let source = detailVM.allSegments.first(where: { $0.id == segID })
            ?? session.segments.first(where: { $0.id == segID })
        guard let seg = source else { return }
        let oldName = seg.speakerName
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }

        // Rename every segment this speaker owns — a per-card rename would leave the same
        // person under two names in one transcript.
        detailVM.renameSpeakerInMemory(from: oldName, to: trimmed)
        await MeetingManager.shared.renameSpeaker(meetingID: meetingID, oldName: oldName, newName: trimmed)
        if session.meetingID == meetingID {
            session.updateSpeaker(segmentID: segID, newName: trimmed)
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
            ? MeetingTranscriptText.plainProse(from: segments)
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
