//
//  RecordingDetailView.swift
//  Whisperer
//
//  The one detail screen. Header and source row, a Transcript / Overview tab pair, and the shared
//  reader. What differs by recording type is only the context row and what the sidebar offers.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum RecordingDetailTab: String, CaseIterable, Identifiable {
    case transcript = "Transcript", overview = "Overview"
    var id: String { rawValue }
    var icon: String { self == .transcript ? "text.alignleft" : "sparkles" }
}

struct RecordingDetailView: View {
    @ObservedObject var detail: RecordingDetailModel
    @ObservedObject var playback: RecordingPlaybackController
    @ObservedObject var workspace: RecordingsWorkspaceModel
    @ObservedObject var session: MeetingSession
    @Binding var tab: RecordingDetailTab
    @Binding var sidebarVisible: Bool
    /// The compact player shows under the reader when the sidebar (and its full player) is not visible.
    let showsCompactPlayer: Bool
    /// Opens the sidebar on its Details tab (the dictation's "Dictation details" link).
    let onOpenDetails: () -> Void

    @StateObject private var search = RecordingSearchModel()
    @ObservedObject private var retranscriber = RecordingRetranscriber.shared
    @ObservedObject private var meetings = MeetingManager.shared
    @ObservedObject private var polish = TranscriptPolishController.shared
    @State private var titleDraft = ""
    @State private var searching = false
    @State private var copied = false
    @State private var confirmDelete = false
    @State private var hiddenSpeakers: Set<String> = []
    @FocusState private var titleFocused: Bool
    @FocusState private var searchFocused: Bool
    @AppStorage("timeFormat") private var timeFormat = "12h"

    private let accent = WhispererColors.accent

    var body: some View {
        Group {
            if let document = detail.document {
                if document.isInProgress { liveNotice(document) } else { content(document) }
            } else if detail.isLoading {
                skeleton
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 28, weight: .light)).foregroundColor(Color.white.opacity(0.25))
                    Text("Select a recording").font(.system(size: 13, weight: .medium)).foregroundColor(Color.white.opacity(0.4))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(hex: "0C0C1A"))
    }

    /// The paragraphs on screen: the shown version, minus speakers the user hid.
    private var visibleParagraphs: [TranscriptParagraph] {
        hiddenSpeakers.isEmpty ? detail.shownParagraphs : detail.shownParagraphs.filter { !hiddenSpeakers.contains($0.speakerName ?? "") }
    }

    // MARK: Content

    private func content(_ document: TranscriptDocument) -> some View {
        VStack(spacing: 0) {
            topBar(document)
            VStack(alignment: .leading, spacing: 12) {
                titleField(document)
                metaRow(document)
                contextRow(document)
            }
            .padding(.horizontal, 28).padding(.top, 6).padding(.bottom, 18)
            tabBar(document)
            Group {
                switch tab {
                case .transcript: transcript(document)
                case .overview: overview(document)
                }
            }
            .frame(maxHeight: .infinity)
            if showsCompactPlayer, playback.availability != .none {
                RecordingPlayerView(controller: playback, style: .compact)
                    .padding(.horizontal, 28).padding(.bottom, 14).padding(.top, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { titleDraft = document.title; search.setParagraphs(visibleParagraphs) }
        .onChange(of: document.id) { _, _ in titleDraft = document.title; search.clear(); searching = false; hiddenSpeakers = [] }
        .onChange(of: document.title) { _, title in if !titleFocused { titleDraft = title } }
        .onChange(of: visibleParagraphs) { _, paragraphs in search.setParagraphs(paragraphs) }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete) {
            Button("Delete “\(document.title)”", role: .destructive) { Task { await workspace.delete(document.id) } }
        } message: { Text("The transcript, its audio and any AI chat are removed from this Mac. This can't be undone.") }
    }

    // MARK: Top bar

    private func topBar(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Recordings").foregroundColor(Color.white.opacity(0.45))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(Color.white.opacity(0.25))
                Text(document.kind == .file ? "Imported file" : document.kind.label).foregroundColor(Color.white.opacity(0.75))
            }
            .font(.system(size: 12.5, weight: .medium))
            Spacer()
            squareButton(document.isPinned ? "pin.fill" : "pin", active: document.isPinned, help: document.isPinned ? "Unpin" : "Pin") {
                if let item = workspace.items.first(where: { $0.id == document.id }) { workspace.togglePin(item) }
                detail.reload()
            }
            Menu {
                Button("Export as text…") { export(document) }
                Button("Copy transcript") { copyTranscript(document) }
            } label: {
                HStack(spacing: 6) { Image(systemName: "square.and.arrow.up").font(.system(size: 12)); Text("Export") }
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(Color.white.opacity(0.8))
                    .padding(.horizontal, 12).frame(height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .uiTestFrame("recordings.export")
            Menu {
                Button(document.isFlagged ? "Remove flag" : "Flag") {
                    if let item = workspace.items.first(where: { $0.id == document.id }) { workspace.toggleFlag(item) }
                    detail.reload()
                }
                if let audio = document.audioURL {
                    Button("Show audio in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audio]) }
                }
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)).foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            squareButton("sidebar.right", active: sidebarVisible, help: sidebarVisible ? "Hide sidebar" : "Show sidebar") {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { sidebarVisible.toggle() }
            }
            .uiTestFrame("recordings.sidebar.toggle")
        }
        .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 12)
    }

    /// A 32 pt bordered square; accent-tinted while its state is on.
    private func squareButton(_ symbol: String, active: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundColor(active ? accent : Color.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(active ? accent.opacity(0.16) : Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(active ? accent.opacity(0.4) : Color.white.opacity(0.09), lineWidth: 1))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    /// A plain icon, no frame — the toolbar's quiet actions.
    private func plainIcon(_ symbol: String, active: Bool = false, tint: Color? = nil, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                .foregroundColor(tint ?? (active ? accent : Color.white.opacity(0.6)))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(active ? accent.opacity(0.14) : .clear))
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    // MARK: Header

    private func titleField(_ document: TranscriptDocument) -> some View {
        TextField("Title", text: $titleDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...2)
            .font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
            .focused($titleFocused)
            .onSubmit { commitTitle(document) }
            .onChange(of: titleFocused) { _, focused in if !focused { commitTitle(document) } }
            .uiTestFrame("recordings.title")
    }

    private func commitTitle(_ document: TranscriptDocument) {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { titleDraft = document.title; return }
        guard trimmed != document.title else { return }
        workspace.rename(document.id, to: trimmed)
    }

    private func metaRow(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: document.kind == .meeting ? "video" : document.kind == .file ? "doc.text" : "mic").font(.system(size: 12))
                Text(sourceLabel(document))
            }
            dot
            Text(document.createdAt.formatted(.dateTime.month(.wide).day()))
            dot
            Text(RecordingTimeFormat.string(document.createdAt, setting: timeFormat))
            if document.duration > 0 { dot; Text(FileTranscriptClock.format(document.duration)).monospacedDigit() }
            dot
            Text(Locale.current.localizedString(forLanguageCode: document.language)?.capitalized ?? document.language)
            if detail.document?.id == retranscriber.runningID || meetings.processingPhases[document.id.uuid] != nil {
                dot
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Working…") }.foregroundColor(accent)
            }
        }
        .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.5))
    }

    private var dot: some View { Text("·").foregroundColor(Color.white.opacity(0.25)) }

    private func sourceLabel(_ document: TranscriptDocument) -> String {
        switch document.kind {
        case .meeting: return document.sourceName ?? "Meeting"
        case .dictation: return document.sourceName ?? "Dictation"
        case .file: return "File import"
        }
    }

    /// The row that says where this recording came from — the only part of the header that differs by type.
    @ViewBuilder private func contextRow(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 14) {
            switch document.kind {
            case .meeting:
                let names = document.speakerNames.isEmpty ? document.participants.map { $0.displayName } : document.speakerNames
                if !names.isEmpty {
                    HStack(spacing: -7) {
                        ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { index, name in
                            let tint = speakerColor(for: index)
                            Text(String(name.split(separator: " ").prefix(2).compactMap { $0.first }).uppercased())
                                .font(.system(size: 9.5, weight: .bold)).foregroundColor(tint)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color(hex: "14142B")))
                                .overlay(Circle().fill(tint.opacity(0.18)))
                                .overlay(Circle().stroke(Color(hex: "0C0C1A"), lineWidth: 2))
                        }
                    }
                    Text(names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : ""))
                        .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.65)).lineLimit(1)
                }
            case .file:
                HStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 12))
                    Text(document.sourceName ?? "Imported file").lineLimit(1)
                }
                .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.65))
            case .dictation:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 13))
                    Text(document.sourceName.map { "Inserted into \($0)" } ?? "Dictation").lineLimit(1)
                }
                .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.65))
            }
            Spacer()
            contextAction(document)
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder private func contextAction(_ document: TranscriptDocument) -> some View {
        if document.kind == .dictation {
            Button(action: onOpenDetails) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text("Dictation details")
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(Color.white.opacity(0.6))
            }.buttonStyle(.plain)
        } else if let summary = document.summary {
            Button { tab = .overview } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 11))
                    Text(summaryChip(summary, kind: document.kind))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(Color.white.opacity(0.6))
            }.buttonStyle(.plain)
        }
    }

    private func summaryChip(_ summary: MeetingAISummary, kind: RecordingKind) -> String {
        guard kind == .meeting else { return "Overview ready" }
        var parts: [String] = []
        if !summary.decisions.isEmpty { parts.append("\(summary.decisions.count) decision\(summary.decisions.count == 1 ? "" : "s")") }
        if !summary.actionItems.isEmpty { parts.append("\(summary.actionItems.count) action\(summary.actionItems.count == 1 ? "" : "s")") }
        return parts.isEmpty ? "Overview ready" : parts.joined(separator: " · ")
    }

    // MARK: Tabs

    private func tabBar(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 28) {
            ForEach(RecordingDetailTab.allCases) { item in
                Button { withAnimation(.easeInOut(duration: 0.15)) { tab = item } } label: {
                    VStack(spacing: 11) {
                        HStack(spacing: 7) {
                            Image(systemName: item.icon).font(.system(size: 12))
                            Text(item.rawValue).font(.system(size: 14, weight: tab == item ? .semibold : .medium))
                        }
                        .foregroundColor(tab == item ? .white : Color.white.opacity(0.45))
                        Rectangle().fill(tab == item ? accent : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
                .uiTestFrame("recordings.tab.\(item.rawValue.lowercased())")
            }
            Spacer()
            Label("Saved locally", systemImage: "checkmark").font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 28)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    // MARK: Transcript

    private func transcript(_ document: TranscriptDocument) -> some View {
        VStack(spacing: 0) {
            toolbar(document)
            infoLine(document)
            if document.captureFailed {
                notice("No audio was captured for this recording.")
            } else if visibleParagraphs.isEmpty {
                notice("There is no transcript for this recording.")
            } else {
                RecordingReaderView(paragraphs: visibleParagraphs, language: TranscriptionLanguage(rawValue: document.language),
                                    style: RecordingReaderView.style(for: document), playback: playback, search: search)
            }
        }
    }

    private func toolbar(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 10) {
            if document.hasSpeakers { speakersMenu(document) } else {
                Label("Paragraphs", systemImage: "text.alignleft")
                    .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.45))
            }
            if document.hasOriginalVersion { versionSwitch(document) }
            Spacer()
            if searching { searchField }
            TranscriptPolishBar(meetingID: document.id.uuid, segments: document.segments, compact: false, quiet: true)
            plainIcon("doc.on.doc", tint: copied ? Color(hex: "22C55E") : nil, help: "Copy transcript") { copyTranscript(document) }
            plainIcon("magnifyingglass", active: searching, help: "Search this transcript") {
                withAnimation(.easeInOut(duration: 0.15)) { searching.toggle() }
                if searching { searchFocused = true } else { search.clear() }
            }
            .keyboardShortcut("f", modifiers: .command)
            .uiTestFrame("recordings.transcript.search")
            RetranscribeControl(document: document, onMeeting: { language in startMeetingRetranscribe(document, language) })
            plainIcon(workspace.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      active: workspace.focusMode, help: workspace.focusMode ? "Leave focus mode" : "Focus mode") {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { workspace.focusMode.toggle() }
            }
            .uiTestFrame("recordings.focus.toggle")
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
    }

    /// "Speakers ⌄": show everyone, or hide some.
    private func speakersMenu(_ document: TranscriptDocument) -> some View {
        Menu {
            Button("All speakers") { hiddenSpeakers = [] }
            Divider()
            ForEach(document.speakerNames, id: \.self) { name in
                Button {
                    if hiddenSpeakers.contains(name) { hiddenSpeakers.remove(name) } else { hiddenSpeakers.insert(name) }
                } label: {
                    Text(hiddenSpeakers.contains(name) ? name : "✓  \(name)")
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "person.2").font(.system(size: 12))
                Text(hiddenSpeakers.isEmpty ? "Speakers" : "Speakers · \(document.speakerNames.count - hiddenSpeakers.count)")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.7))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    /// Enhanced / Original, as two flat buttons (the design system avoids system segmented controls).
    private func versionSwitch(_ document: TranscriptDocument) -> some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { original in
                Button { detail.showOriginal = original } label: {
                    Text(original ? "Original" : (document.enhancementName ?? "Enhanced"))
                        .font(.system(size: 12, weight: detail.showOriginal == original ? .semibold : .medium))
                        .foregroundColor(detail.showOriginal == original ? .white : Color.white.opacity(0.5))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(detail.showOriginal == original ? Color.white.opacity(0.10) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(detail.showOriginal == original ? .isSelected : [])
                .uiTestFrame("recordings.version.\(original ? "original" : "enhanced")")
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    /// "⏱ 4 speakers · Time-aligned transcript" and the word count.
    private func infoLine(_ document: TranscriptDocument) -> some View {
        HStack {
            Label(infoText(document), systemImage: document.hasTiming ? "clock" : "text.alignleft")
                .font(.system(size: 12)).foregroundColor(Color.white.opacity(0.4))
            Spacer()
            HStack(spacing: 6) {
                Text("\(document.wordCount.formatted()) words")
                Image(systemName: "info.circle").font(.system(size: 11))
            }
            .font(.system(size: 12.5)).foregroundColor(Color.white.opacity(0.55))
            .help(document.hasTiming ? "Times are approximate where the recording was split into chunks." : "This recording has no timing, so paragraphs have no times.")
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
    }

    private func infoText(_ document: TranscriptDocument) -> String {
        let speakers = document.hasSpeakers ? "\(document.speakerNames.count) speaker\(document.speakerNames.count == 1 ? "" : "s") · " : ""
        switch document.kind {
        case .dictation: return "A thought, captured."
        case .file: return (document.hasTiming ? "Time-aligned paragraphs" : "Paragraphs") + " · No speaker labels"
        case .meeting: return "\(speakers)\(document.hasTiming ? "Time-aligned transcript" : "Transcript")"
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            TextField("Find in transcript", text: $search.query)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundColor(.white).frame(width: 150)
                .focused($searchFocused)
                .onChange(of: search.query) { _, _ in search.queryChanged() }
                .onSubmit { search.next() }
            if search.isActive {
                Text(search.matchIDs.isEmpty ? "0" : "\(search.currentIndex + 1)/\(search.matchIDs.count)")
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(Color.white.opacity(0.5)).monospacedDigit()
                Button { search.previous() } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { search.next() } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
            }
        }
        .font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6))
        .padding(.horizontal, 10).frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
        .onExitCommand { searching = false; search.clear() }
    }

    // MARK: Overview

    private func overview(_ document: TranscriptDocument) -> some View {
        MeetingOverviewView(meeting: detail.meetingRecord)
            .id(document.id.key)
    }

    // MARK: Pieces

    private func notice(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundColor(Color.white.opacity(0.45)).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)).frame(width: 260, height: 28)
            ForEach(0..<6, id: \.self) { _ in RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.04)).frame(height: 14) }
            Spacer()
        }.padding(28)
    }

    /// A meeting still being recorded keeps its live experience — the live window.
    private func liveNotice(_ document: TranscriptDocument) -> some View {
        VStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text("Recording in progress").font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
            Text("“\(document.title)” will open here with its transcript, overview and Ask AI as soon as it ends.")
                .font(.system(size: 13)).foregroundColor(Color.white.opacity(0.5)).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Open live window") { MeetingLiveWindowManager.shared.show(session: session) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func copyTranscript(_ document: TranscriptDocument) {
        let text = visibleParagraphs.map(\.text).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    private func export(_ document: TranscriptDocument) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(document.title).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var shown = document
        shown.paragraphs = detail.shownParagraphs
        try? shown.exportText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func startMeetingRetranscribe(_ document: TranscriptDocument, _ language: TranscriptionLanguage) {
        guard let record = detail.meetingRecord else { return }
        let audioURL = record.resolvedAudioURL, segments = record.segments, id = document.id.uuid
        Task {
            if language == .auto {
                MeetingTranscriptRefiner.shared.start(meetingID: id, segments: segments, audioURL: audioURL, redoAll: true)
            } else {
                await MeetingManager.shared.updateLanguage(meetingID: id, language: language.rawValue)
                MeetingTranscriptRefiner.shared.start(meetingID: id, segments: segments, audioURL: audioURL, forcedLanguage: language)
            }
        }
    }
}

// MARK: - Re-transcribe

/// The re-transcribe control: pick a language, then run. Dictation and files go through
/// `RecordingRetranscriber`; meetings through the refiner.
struct RetranscribeControl: View {
    let document: TranscriptDocument
    let onMeeting: (TranscriptionLanguage) -> Void
    /// Show "Re-transcribe" next to the icon (the Details pane) instead of the icon alone (the toolbar).
    var showsLabel = false
    @ObservedObject private var retranscriber = RecordingRetranscriber.shared
    @State private var open = false
    @State private var language: TranscriptionLanguage = .auto

    private var reason: String? {
        if document.kind == .meeting {
            return document.audioURL == nil ? "This recording has no audio on this Mac." : nil
        }
        return retranscriber.unavailableReason(for: document)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: showsLabel ? 12 : 14, weight: .regular))
                if showsLabel { Text("Re-transcribe").font(.system(size: 12, weight: .medium)) }
            }
            .foregroundColor(Color.white.opacity(showsLabel ? 0.65 : 0.6))
            .frame(minWidth: showsLabel ? 0 : 30, minHeight: 30)
        }
        .buttonStyle(.plain).help("Re-transcribe").accessibilityLabel("Re-transcribe")
        .uiTestFrame("recordings.retranscribe")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Re-transcribe").font(.system(size: 14, weight: .semibold))
                Text("Run the recording through the speech model again. The original text is kept.")
                    .font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Language", selection: $language) {
                    ForEach(TranscriptionLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if let reason { Text(reason).font(.system(size: 11.5)).foregroundColor(.orange) }
                HStack {
                    Spacer()
                    Button("Cancel") { open = false }
                    Button("Re-transcribe") {
                        open = false
                        if document.kind == .meeting { onMeeting(language) } else { retranscriber.start(document, language: language) }
                    }
                    .keyboardShortcut(.defaultAction).disabled(reason != nil)
                }
            }
            .padding(16).frame(width: 300)
            .onAppear { language = TranscriptionLanguage(rawValue: document.language) ?? .auto }
        }
    }
}
