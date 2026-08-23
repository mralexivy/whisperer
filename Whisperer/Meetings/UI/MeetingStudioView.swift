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
    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @StateObject private var detailVM = MeetingDetailViewModel()

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
        .onChange(of: selectedMeetingID) { _, newID in
            audioPlayer.stop()
            detailVM.clear()
            if let id = newID { Task { await detailVM.load(meetingID: id) } }
        }
        .onChange(of: detailVM.meeting?.id) { _, _ in
            if let url = detailVM.meeting?.resolvedAudioURL,
               FileManager.default.fileExists(atPath: url.path),
               audioPlayer.duration == 0 {
                audioPlayer.load(url: url)
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
            if session.isRecording, let id = session.meetingID {
                selectedMeetingID = id
                return
            }
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            } else if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                selectedMeetingID = meetings.first?.id
            }
            if let item = meetings.first(where: { $0.id == selectedMeetingID }),
               let url = item.resolvedAudioURL,
               FileManager.default.fileExists(atPath: url.path),
               audioPlayer.duration == 0 {
                audioPlayer.load(url: url)
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
            .onChange(of: selectedMeetingID) { _, newID in
                audioPlayer.stop()
                detailVM.clear()
                if let id = newID { Task { await detailVM.load(meetingID: id) } }
            }
            .onChange(of: detailVM.meeting?.id) { _, _ in
                if let url = detailVM.meeting?.resolvedAudioURL,
                   FileManager.default.fileExists(atPath: url.path),
                   audioPlayer.duration == 0 {
                    audioPlayer.load(url: url)
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
                if session.isRecording, let id = session.meetingID {
                    selectedMeetingID = id
                    return
                }
                if selectedMeetingID == nil {
                    selectedMeetingID = meetings.first?.id
                } else if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                    selectedMeetingID = meetings.first?.id
                }
                if let item = meetings.first(where: { $0.id == selectedMeetingID }),
                   let url = item.resolvedAudioURL,
                   FileManager.default.fileExists(atPath: url.path),
                   audioPlayer.duration == 0 {
                    audioPlayer.load(url: url)
                }
            }
        #endif
    }

    // MARK: - Main 3-column content

    private var mainContent: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left: library + live card
                MeetingListPanel(
                    session: session,
                    selectedMeetingID: $selectedMeetingID
                )
                .frame(width: listWidth(in: geo.size.width))

                divider

                // Center: transcript / overview — always show if a selection exists or is loading
                if selectedMeetingID != nil || detailVM.isLoading {
                    MeetingDetailView(detailVM: detailVM, session: session, playheadSeconds: audioPlayer.currentTime)
                        .id(selectedMeetingID)
                        .frame(minWidth: 200)
                        .layoutPriority(1)
                } else {
                    notesPlaceholder
                        .layoutPriority(1)
                }

                divider

                // Right: player + assistant
                MeetingRightPanel(meeting: detailVM.meeting, session: session, player: audioPlayer)
                    .frame(width: rightWidth(in: geo.size.width))
                    .id(selectedMeetingID)
            }
        }
    }

    private func listWidth(in total: CGFloat) -> CGFloat {
        min(260, max(200, total * 0.18))
    }

    private func rightWidth(in total: CGFloat) -> CGFloat {
        min(400, max(280, total * 0.28))
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
                Task { await session.startRecording(title: defaultNoteTitle(), surface: .workspace) }
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
