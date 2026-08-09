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

    private var session: MeetingSession {
        appState.activeMeetingSession ?? localSession
    }
    @ObservedObject private var manager = MeetingManager.shared
    @State private var selectedMeetingID: UUID?
    @State private var showNewNoteSheet = false
    @State private var newNoteTitle = ""

    var selectedMeeting: MeetingRecord? {
        guard let id = selectedMeetingID else { return nil }
        return manager.meetings.first { $0.id == id }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left: library + live card
            MeetingListPanel(
                session: session,
                selectedMeetingID: $selectedMeetingID,
                showNewNoteSheet: $showNewNoteSheet,
                newNoteTitle: $newNoteTitle
            )
            .frame(width: 260)

            divider

            // Center: transcript / overview
            if let meeting = selectedMeeting {
                MeetingDetailView(meeting: meeting, session: session)
            } else {
                notesPlaceholder
            }

            divider

            // Right: player + assistant
            MeetingRightPanel(meeting: selectedMeeting, session: session)
                .frame(width: 420)
        }
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showNewNoteSheet) { newNoteSheet }
        .onAppear {
            if selectedMeetingID == nil, let first = manager.meetings.first {
                selectedMeetingID = first.id
            }
        }
        .onChange(of: session.meetingID) { id in
            if let id { selectedMeetingID = id }
        }
        .onChange(of: manager.meetings) { meetings in
            if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                selectedMeetingID = meetings.first?.id
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
            // Icon with radial glow
            ZStack {
                // Outer glow ring
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "5B6CF7").opacity(0.18), Color.clear],
                            center: .center, startRadius: 10, endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)

                // Inner card
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

            // Text hierarchy
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

            // CTA
            Button {
                newNoteTitle = defaultNoteTitle()
                showNewNoteSheet = true
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

            // Feature pills
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

    // MARK: - New note sheet

    private var newNoteSheet: some View {
        VStack(spacing: 20) {
            Text("New Note")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("TITLE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.5))
                TextField("Note title", text: $newNoteTitle)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 12) {
                Button("Cancel") { showNewNoteSheet = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("Start Recording") {
                    showNewNoteSheet = false
                    let title = newNoteTitle.isEmpty ? defaultNoteTitle() : newNoteTitle
                    Task { await session.startRecording(title: title) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Color(hex: "14142B"))
        .environment(\.colorScheme, .dark)
    }

    private func defaultNoteTitle() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy h:mm a"
        return "Note \(fmt.string(from: Date()))"
    }
}
