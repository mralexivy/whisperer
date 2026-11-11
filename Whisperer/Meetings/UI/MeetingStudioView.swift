//
//  MeetingStudioView.swift
//  Whisperer
//
//  3-column Notes root view.
//

import SwiftUI

struct MeetingStudioView: View {
    @ObservedObject private var appState = AppState.shared
    @StateObject private var localSession = MeetingSession()
    @StateObject private var audioPlayer = SeekableAudioPlayer()
    /// Throttled to whole seconds so MeetingDetailView doesn't re-render 30× per second.
    @State private var playheadIntSeconds: Int = 0
    @StateObject private var detailVM = MeetingDetailViewModel()
    /// Width the user dragged the player column to. Clamped on every layout pass, so a value
    /// saved on a wide display can never squeeze the transcript on a narrow one.
    @AppStorage("meetings.rightPanelWidth") private var preferredRightWidth: Double = 340
    /// The notes list slides in over the transcript when the window is too narrow to dock it.
    @State private var isListOverlayOpen = false

    private var session: MeetingSession {
        appState.activeMeetingSession ?? localSession
    }
    @ObservedObject private var manager = MeetingManager.shared
    @Binding var selectedMeetingID: UUID?

    #if canImport(FluidAudio)
    @ObservedObject private var engines = MeetingEngines.shared
    @State private var continueAnyway = false
    #endif

    var body: some View {
        #if canImport(FluidAudio)
        Group {
            if engines.needsPreparation && !continueAnyway {
                MeetingPrepView(continueAnyway: $continueAnyway)
            } else {
                mainContent
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            if selectedMeetingID == nil, let first = manager.meetings.first {
                selectedMeetingID = first.id
            }
        }
        // `.task(id:)`, not `.onChange`: it also runs on appear. The selection lives in the
        // parent and survives switching sidebar tabs, but `detailVM` is recreated with this
        // view — with `.onChange` a meeting that was already selected was never loaded, and
        // its transcript stayed empty until the user clicked another meeting and back.
        .task(id: selectedMeetingID) {
            if detailVM.loadedMeetingID != selectedMeetingID { audioPlayer.unload() }
            await detailVM.select(selectedMeetingID)
        }
        .onChange(of: detailVM.meeting?.id) { _, _ in
            if let url = detailVM.meeting?.resolvedAudioURL,
               FileManager.default.fileExists(atPath: url.path) {
                audioPlayer.show(url: url)
            }
        }
        .onChange(of: session.meetingID) { _, id in
            if let id { selectedMeetingID = id }
        }
        .onChange(of: session.isRecording) { _, isRec in
            if isRec, let id = session.meetingID {
                selectedMeetingID = id
            } else {
                Task { await detailVM.refreshDetail() }
            }
        }
        .onChange(of: session.segments.count) { _, _ in
            guard !session.isRecording else { return }
            Task { await detailVM.refreshDetail() }
        }
        .onChange(of: manager.meetings) { _, meetings in
            // The list changes all through a recording (each card persists). It used to put the
            // selection back on the recording every time, so a past meeting could not be read
            // while a call ran. A recording selects itself once, when it starts.
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            } else if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                selectedMeetingID = meetings.first?.id
            }
            if !session.isRecording {
                let item = meetings.first(where: { $0.id == selectedMeetingID })
                Task { await detailVM.refreshIfStale(listItem: item) }
            }
            if let item = meetings.first(where: { $0.id == selectedMeetingID }),
               let url = item.resolvedAudioURL,
               FileManager.default.fileExists(atPath: url.path) {
                audioPlayer.show(url: url)
            }
        }
        #else
        mainContent
            .environment(\.colorScheme, .dark)
            .onAppear {
                if selectedMeetingID == nil, let first = manager.meetings.first {
                    selectedMeetingID = first.id
                }
            }
            .task(id: selectedMeetingID) {
                if detailVM.loadedMeetingID != selectedMeetingID { audioPlayer.unload() }
                await detailVM.select(selectedMeetingID)
            }
            .onChange(of: detailVM.meeting?.id) { _, _ in
                if let url = detailVM.meeting?.resolvedAudioURL,
                   FileManager.default.fileExists(atPath: url.path) {
                    audioPlayer.show(url: url)
                }
            }
            .onChange(of: session.meetingID) { _, id in
                if let id { selectedMeetingID = id }
            }
            .onChange(of: session.isRecording) { _, isRec in
                if isRec, let id = session.meetingID {
                    selectedMeetingID = id
                } else {
                    Task { await detailVM.refreshDetail() }
                }
            }
            .onChange(of: session.segments.count) { _, _ in
                guard !session.isRecording else { return }
                Task { await detailVM.refreshDetail() }
            }
            .onChange(of: manager.meetings) { _, meetings in
                if selectedMeetingID == nil {
                    selectedMeetingID = meetings.first?.id
                } else if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                    selectedMeetingID = meetings.first?.id
                }
                if !session.isRecording {
                    let item = meetings.first(where: { $0.id == selectedMeetingID })
                    Task { await detailVM.refreshIfStale(listItem: item) }
                }
                if let item = meetings.first(where: { $0.id == selectedMeetingID }),
                   let url = item.resolvedAudioURL,
                   FileManager.default.fileExists(atPath: url.path) {
                    audioPlayer.show(url: url)
                }
            }
        #endif
    }

    // MARK: - Main 3-column content

    private var mainContent: some View {
        GeometryReader { geo in
            let layout = columnLayout(total: geo.size.width)
            HStack(spacing: 0) {
                // Left: library + live card — docked when there is room, otherwise a rail
                // whose button slides the same list in over the transcript.
                if layout.dockList {
                    MeetingListPanel(
                        session: session,
                        selectedMeetingID: $selectedMeetingID
                    )
                    .frame(width: layout.list)

                    divider
                } else {
                    collapsedListRail
                    divider
                }

                // Center: transcript / overview — always show if a selection exists or is loading
                Group {
                    if selectedMeetingID != nil || detailVM.isLoading {
                        MeetingDetailView(detailVM: detailVM, session: session, playheadSeconds: Double(playheadIntSeconds))
                            .onChange(of: Int(audioPlayer.currentTime)) { _, newSec in
                                playheadIntSeconds = newSec
                            }
                            .id(selectedMeetingID)
                    } else {
                        notesPlaceholder
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .leading) {
                    if !layout.dockList && isListOverlayOpen {
                        listOverlay(width: layout.list)
                    }
                }

                // Right: player + assistant. Drag its left edge to widen it, as on Transcriptions.
                ResizableDivider(colorScheme: .dark) { delta in
                    var transaction = Transaction()
                    transaction.animation = nil
                    withTransaction(transaction) {
                        preferredRightWidth = Double(min(max(layout.right - delta, Self.minRightWidth),
                                                         layout.maxRight))
                    }
                }
                .background(Color(hex: "0A0A18"))

                MeetingRightPanel(meeting: detailVM.meeting,
                                  session: session,
                                  player: audioPlayer,
                                  onSpeakerRenamed: { speakerIndex, name in
                                      Task { await handleSpeakerRename(speakerIndex: speakerIndex, newName: name) }
                                  },
                                  selectedMeetingID: selectedMeetingID)
                    .frame(width: layout.right)
                    .id(selectedMeetingID)
            }
            .onChange(of: layout.dockList) { _, docked in
                if docked { isListOverlayOpen = false }
            }
            .onChange(of: selectedMeetingID) { _, _ in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { isListOverlayOpen = false }
            }
        }
    }

    // MARK: - Column layout

    /// Smallest player column that shows play, time and speed on one line.
    static let minRightWidth: CGFloat = 320
    static let maxRightWidth: CGFloat = 520
    /// Below this the header and transcript toolbar start to crowd — the list undocks first.
    static let minDetailWidth: CGFloat = 440
    private static let railWidth: CGFloat = 44
    /// 1pt hairline after the list or rail + the 12pt resize handle before the player.
    private static let chromeWidth: CGFloat = 13

    private struct ColumnLayout {
        var dockList: Bool
        var list: CGFloat
        var right: CGFloat
        var maxRight: CGFloat
    }

    /// The transcript keeps at least `minDetailWidth`; the player keeps at least
    /// `minRightWidth`. When both cannot fit beside the docked list, the list undocks to a rail
    /// rather than squeezing either — nothing is ever cut or wrapped letter by letter.
    private func columnLayout(total: CGFloat) -> ColumnLayout {
        let list = listWidth(in: total)
        let dockList = total - Self.chromeWidth - list - Self.minRightWidth >= Self.minDetailWidth
        let leading = dockList ? list : Self.railWidth
        let maxRight = max(Self.minRightWidth,
                           min(Self.maxRightWidth, total - Self.chromeWidth - leading - Self.minDetailWidth))
        let right = min(max(CGFloat(preferredRightWidth), Self.minRightWidth), maxRight)
        return ColumnLayout(dockList: dockList, list: list, right: right, maxRight: maxRight)
    }

    private var collapsedListRail: some View {
        VStack(spacing: 10) {
            railButton(icon: "sidebar.left", help: "Show notes") {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { isListOverlayOpen.toggle() }
            }
            railButton(icon: "plus", help: "New note") {
                Task { await session.startRecording(title: defaultNoteTitle(), surface: .workspace) }
            }
            .disabled(session.isRecording)
            .opacity(session.isRecording ? 0.35 : 1)
            Spacer()
        }
        .padding(.top, 14)
        .frame(width: Self.railWidth)
        .frame(maxHeight: .infinity)
        .background(Color(hex: "0A0A18"))
    }

    private func railButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func listOverlay(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Click anywhere off the list to put it away.
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { isListOverlayOpen = false }
                }
            MeetingListPanel(session: session, selectedMeetingID: $selectedMeetingID)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .trailing) { divider }
                .shadow(color: .black.opacity(0.45), radius: 18, x: 6)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    // MARK: - Speaker rename (from Speakers panel)

    /// Roster for conflict checks in the Speakers panel — mirrors the same computed
    /// property in MeetingDetailView so both surfaces agree on who exists.
    private var speakerRoster: [(index: Int, name: String)] {
        var seen: Set<Int> = []
        var result: [(Int, String)] = []
        let source = (session.isRecording && session.meetingID == detailVM.meeting?.id)
            ? session.segments
            : detailVM.allSegments
        for seg in source where !seen.contains(seg.speakerIndex) {
            seen.insert(seg.speakerIndex)
            result.append((seg.speakerIndex, seg.speakerName))
        }
        return result.sorted { $0.0 < $1.0 }
    }

    private func handleSpeakerRename(speakerIndex: Int, newName: String) async {
        guard let meetingID = detailVM.meeting?.id else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Defensive: UI validated already; re-check here as a safety net.
        guard SpeakerNaming.conflictingName(for: trimmed,
                                            in: speakerRoster,
                                            excluding: speakerIndex) == nil else { return }
        detailVM.renameSpeakerInMemory(index: speakerIndex, to: trimmed)
        await MeetingManager.shared.renameSpeaker(meetingID: meetingID,
                                                   speakerIndex: speakerIndex,
                                                   newName: trimmed)
        if session.meetingID == meetingID {
            session.updateSpeaker(speakerIndex: speakerIndex, newName: trimmed)
        }
    }

    private func listWidth(in total: CGFloat) -> CGFloat {
        // Floor raised to 216 so all three pills fit without dropping at the minimum window size.
        min(280, max(216, total * 0.20))
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(width: 1)
    }

    // MARK: - Empty state placeholder

    private var notesPlaceholder: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "5B6CF7").opacity(0.18), Color.clear],
                            center: .center, startRadius: 10, endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)

                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "14142B"))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(hex: "5B6CF7").opacity(0.5), Color(hex: "8B5CF6").opacity(0.2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .frame(width: 76, height: 76)

                Image(systemName: "note.text")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 10) {
                Text("Your notes live here")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))

                Text("Transcribe your voice into organized,\nsearchable notes — all offline.")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.38))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button {
                Task {
                    await session.startRecording(title: defaultNoteTitle(), surface: .workspace)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text("New Note")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: Color(hex: "5B6CF7").opacity(0.35), radius: 14, y: 5)
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                featurePill("mic.fill", "Voice transcription", Color(hex: "5B6CF7"))
                featurePill("magnifyingglass", "Searchable", Color(hex: "F59E0B"))
                featurePill("square.and.arrow.up", "Exportable", Color(hex: "22C55E"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: "0C0C1A"))
    }

    private func featurePill(_ icon: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(color.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.1)))
        .overlay(Capsule().stroke(color.opacity(0.18), lineWidth: 0.5))
    }

    private func defaultNoteTitle() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy h:mm a"
        return "Note \(fmt.string(from: Date()))"
    }
}
