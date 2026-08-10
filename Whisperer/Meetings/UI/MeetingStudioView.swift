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

    var body: some View {
        HStack(spacing: 0) {
            // Left: library + live card
            MeetingListPanel(
                session: session,
                selectedMeetingID: $selectedMeetingID
            )
            .frame(width: 260)

            divider

            // Center: transcript / overview — always show if a selection exists or is loading
            if selectedMeetingID != nil || detailVM.isLoading {
                MeetingDetailView(detailVM: detailVM, session: session, playheadSeconds: audioPlayer.currentTime)
                    .id(selectedMeetingID)
            } else {
                notesPlaceholder
            }

            divider

            // Right: player + assistant
            MeetingRightPanel(meeting: detailVM.meeting, session: session, player: audioPlayer)
                .frame(width: 420)
                .id(selectedMeetingID)
        }
        .environment(\.colorScheme, .dark)
        .onAppear {
            if selectedMeetingID == nil, let first = manager.meetings.first {
                selectedMeetingID = first.id
            }
            // Audio load happens via onChange(of: detailVM.meeting?.id)
        }
        // When selection changes: clear detail immediately (shows skeleton), then load new record
        .onChange(of: selectedMeetingID) { _, newID in
            audioPlayer.stop()
            detailVM.clear()
            if let id = newID { Task { await detailVM.load(meetingID: id) } }
        }
        // When the loaded detail record appears, load its audio
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
        // Belt-and-suspenders: when recording starts, ensure the live meeting is selected
        .onChange(of: session.isRecording) { _, isRec in
            if isRec, let id = session.meetingID {
                selectedMeetingID = id
            } else {
                // refreshDetail(), not load(): load() clears the record to a skeleton before
                // fetching (and early-returns here anyway since loadedMeetingID is unchanged),
                // which is what made the whole transcript blink out at stop.
                Task { await detailVM.refreshDetail() }
            }
        }
        // The tail chunk appends one more segment after stopRecording() has returned.
        // Pick it up without blanking what is already on screen.
        .onChange(of: session.segments.count) { _, _ in
            guard !session.isRecording else { return }
            Task { await detailVM.refreshDetail() }
        }
        .onChange(of: manager.meetings) { _, meetings in
            // While recording, always track the live meeting
            if session.isRecording, let id = session.meetingID {
                selectedMeetingID = id
                return
            }
            if selectedMeetingID == nil {
                selectedMeetingID = meetings.first?.id
            } else if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                selectedMeetingID = meetings.first?.id
            }
            // Audio becomes available after finalize — check list item for the URL
            if let item = meetings.first(where: { $0.id == selectedMeetingID }),
               let url = item.resolvedAudioURL,
               FileManager.default.fileExists(atPath: url.path),
               audioPlayer.duration == 0 {
                audioPlayer.load(url: url)
            }
        }
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
                Task { await session.startRecording(title: defaultNoteTitle()) }
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
