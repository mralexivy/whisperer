//
//  RecordingSidebarView.swift
//  Whisperer
//
//  The context column. Which tabs a recording gets is decided in one place (`RecordingSidebarPolicy`);
//  the full player is pinned above the tabs, outside anything that scrolls, so it never leaves the
//  window while the tab content changes.
//

import SwiftUI

enum RecordingSidebarTab: String, CaseIterable, Identifiable {
    case details = "Details", askAI = "Ask AI", notes = "Notes", people = "People"
    var id: String { rawValue }
}

enum RecordingSidebarPolicy {
    static func tabs(for kind: RecordingKind) -> [RecordingSidebarTab] {
        switch kind {
        case .dictation: return [.details, .askAI]
        case .meeting: return [.askAI, .notes, .people]
        case .file: return [.askAI, .notes]
        }
    }

    static func defaultTab(for kind: RecordingKind) -> RecordingSidebarTab { tabs(for: kind)[0] }

    static func starters(for kind: RecordingKind) -> [String]? {
        switch kind {
        case .meeting: return ["What did we decide?", "What needs my attention?", "Draft a follow-up"]
        case .dictation: return ["Summarize this", "What are the key points?", "Turn this into a short message"]
        case .file: return ["What are the key takeaways?", "Find the most useful moments", "Turn this into practical notes"]
        }
    }

    static func headline(for kind: RecordingKind) -> [String] {
        switch kind {
        case .meeting: return ["Good conversations.", "Clear next steps."]
        case .file: return ["A long recording.", "A little more clarity."]
        case .dictation: return ["A quick thought.", "Made useful."]
        }
    }

    static func subtitle(for kind: RecordingKind) -> String {
        switch kind {
        case .meeting: return "Find the decisions, connect the ideas, and turn this conversation into action."
        case .file: return "Explore the ideas, find the useful moments, and ask your next question."
        case .dictation: return "Ask for a summary, a cleaner version, or a message you are ready to send."
        }
    }

    static func noun(for kind: RecordingKind) -> String {
        switch kind {
        case .meeting: return "meeting"
        case .dictation: return "dictation"
        case .file: return "recording"
        }
    }
}

struct RecordingSidebarView: View {
    let document: TranscriptDocument
    let meetingRecord: MeetingRecord
    @ObservedObject var playback: RecordingPlaybackController
    @ObservedObject var session: MeetingSession
    @ObservedObject var detail: RecordingDetailModel
    @Binding var tab: RecordingSidebarTab
    let onCitation: (RAGChunk) -> Void
    let onCollapse: () -> Void

    private var tabs: [RecordingSidebarTab] { RecordingSidebarPolicy.tabs(for: document.kind) }
    private var current: RecordingSidebarTab { tabs.contains(tab) ? tab : tabs[0] }

    var body: some View {
        VStack(spacing: 0) {
            header
            RecordingPlayerView(controller: playback, style: .full)
                .padding(.horizontal, 16).padding(.bottom, 14)
            tabStrip
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            content
        }
        .background(Color(hex: "0A0A18"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: document.kind == .dictation ? "mic" : "sparkles")
                .font(.system(size: 13, weight: .medium)).foregroundColor(Color.white.opacity(0.7))
            Text(document.kind == .dictation ? "Dictation details" : "Your thinking partner")
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Spacer()
            Button(action: onCollapse) {
                Image(systemName: "sidebar.right").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.55))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).help("Hide sidebar").accessibilityLabel("Hide sidebar")
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { item in
                Button { tab = item } label: {
                    HStack(spacing: 4) {
                        if item == .askAI { Image(systemName: "sparkles").font(.system(size: 10)) }
                        Text(item.rawValue)
                        if item == .people, document.speakerNames.count > 0 {
                            Text("\(document.speakerNames.count)").foregroundColor(Color.white.opacity(0.35))
                        }
                    }
                    .font(.system(size: 12, weight: current == item ? .semibold : .medium))
                    .foregroundColor(current == item ? .white : Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(current == item ? Color.white.opacity(0.10) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current == item ? .isSelected : [])
                .uiTestFrame("recordings.sidebar.tab.\(item.rawValue.lowercased().replacingOccurrences(of: " ", with: ""))")
            }
        }
        .padding(3).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch current {
        case .askAI:
            AskAIPane(meeting: meetingRecord, noun: RecordingSidebarPolicy.noun(for: document.kind),
                      onCitation: onCitation, starters: RecordingSidebarPolicy.starters(for: document.kind),
                      headline: RecordingSidebarPolicy.headline(for: document.kind),
                      subtitle: RecordingSidebarPolicy.subtitle(for: document.kind), scopeTitle: document.title)
                // A conversation belongs to one recording: a new selection starts a new pane, so an
                // answer still in flight cannot land under a different recording.
                .id(document.id.key)
        case .notes:
            if document.kind == .meeting {
                LiveNotesPane(session: session, meeting: meetingRecord).id(document.id.key)
            } else {
                RecordingNotesPane(documentID: document.id, initial: document.legacyNotes ?? "").id(document.id.key)
            }
        case .people:
            SpeakersPane(meeting: meetingRecord, session: session, onSpeakerRenamed: { _, _ in detail.reload() })
                .id(document.id.key)
        case .details:
            DictationDetailsPane(document: document, detail: detail)
        }
    }
}

// MARK: - Notes for imported files

/// Plain-text notes on an imported file, stored in the row's existing `notes` field.
private struct RecordingNotesPane: View {
    let documentID: RecordingID
    @State private var text: String
    @State private var saveTask: Task<Void, Never>?

    init(documentID: RecordingID, initial: String) {
        self.documentID = documentID
        _text = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(size: 13)).foregroundColor(.white).scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Add notes about this recording…").font(.system(size: 13)).foregroundColor(Color.white.opacity(0.3))
                            .padding(.horizontal, 15).padding(.vertical, 18).allowsHitTesting(false)
                    }
                }
                .onChange(of: text) { _, value in scheduleSave(value) }
                .uiTestFrame("recordings.notes.editor")
            Text("Saved on this Mac as you type.").font(.system(size: 11)).foregroundColor(Color.white.opacity(0.3))
        }
        .padding(14)
        .onDisappear { saveTask?.cancel(); save(text) }
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            save(value)
        }
    }

    private func save(_ value: String) {
        guard documentID.store == .transcription else { return }
        HistoryManager.shared.update(id: documentID.uuid) { $0.notes = value.isEmpty ? nil : value }
    }
}

// MARK: - Dictation details

private struct DictationDetailsPane: View {
    let document: TranscriptDocument
    @ObservedObject var detail: RecordingDetailModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                label("RECORDING DETAILS")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    stat("clock", "Duration", document.duration > 0 ? FileTranscriptClock.format(document.duration) : "—")
                    stat("text.alignleft", "Words", "\(document.wordCount)")
                    stat("speedometer", "Speaking pace", document.duration > 0 ? "\(document.wordsPerMinute) wpm" : "—")
                    stat("globe", "Language", Locale.current.localizedString(forLanguageCode: document.language)?.capitalized ?? document.language)
                }
                row("square.stack.3d.up", "Transcription model", document.model.isEmpty ? "—" : document.model)
                if let app = document.sourceName {
                    row("keyboard", "Inserted into", app)
                }
                enhancement
                if document.correctionCount > 0 {
                    row("character.book.closed", "Dictionary", "\(document.correctionCount) correction\(document.correctionCount == 1 ? "" : "s") applied")
                }
                HStack {
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy text", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(copied ? Color(hex: "22C55E") : .white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                    }.buttonStyle(.plain)
                    Spacer()
                    if document.audioURL != nil {
                        RetranscribeControl(document: document, onMeeting: { _ in }, showsLabel: true)
                    }
                }
                .padding(.top, 6)
            }
            .padding(14)
        }
    }

    @ViewBuilder private var enhancement: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("TEXT ENHANCEMENT")
            if document.hasOriginalVersion {
                HStack {
                    Text(document.enhancementName ?? "Enhanced").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    Spacer()
                    Text(detail.showOriginal ? "Viewing original" : "Viewing enhanced")
                        .font(.system(size: 11)).foregroundColor(Color.white.opacity(0.45))
                }
                HStack(spacing: 8) {
                    pill(detail.showOriginal ? "Show enhanced" : "Show original", "eye") { detail.showOriginal.toggle() }
                    pill("Undo", "arrow.uturn.backward") {
                        Task {
                            if let record = HistoryManager.shared.record(id: document.id.uuid) {
                                try? await HistoryManager.shared.revertAIEnhancement(record)
                                detail.reload()
                            }
                        }
                    }
                }
            } else {
                Text("Original wording").font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                Text("Your words, exactly as transcribed.").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(document.fullText, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).tracking(1.0).foregroundColor(Color.white.opacity(0.4))
    }

    private func stat(_ icon: String, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(WhispererColors.accent)
            Text(title).font(.system(size: 10.5, weight: .medium)).foregroundColor(Color.white.opacity(0.4))
            Text(value).font(.system(size: 17, weight: .light, design: .rounded)).foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.5)).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5)).foregroundColor(Color.white.opacity(0.4))
                Text(value).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
            }
            Spacer()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.04)))
    }

    private func pill(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
        }.buttonStyle(.plain)
    }
}
