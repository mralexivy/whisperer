//
//  MeetingAssistantPanel.swift
//  Whisperer
//
//  Right panel bottom: Ask AI / Live Notes / Speakers sub-panes.
//

import SwiftUI
import AppKit

// MARK: - Notification name

extension Notification.Name {
    static let meetingScrollToTimestamp = Notification.Name("meetingScrollToTimestamp")
}

// MARK: - Pane tabs

enum AssistantPaneTab: String, CaseIterable, Identifiable {
    case askAI     = "Ask AI"
    case liveNotes = "Live Notes"
    case speakers  = "Speakers"
    var id: String { rawValue }
}

// MARK: - Root panel

struct MeetingAssistantPanel: View {
    let meeting: MeetingRecord?
    @ObservedObject var session: MeetingSession
    @State private var selectedPane: AssistantPaneTab = .askAI

    var body: some View {
        VStack(spacing: 0) {
            paneTabBar
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            Group {
                switch selectedPane {
                case .askAI:     AskAIPane(meeting: meeting)
                case .liveNotes: LiveNotesPane(session: session, meeting: meeting)
                case .speakers:  SpeakersPane(meeting: meeting, session: session)
                }
            }
        }
        .background(Color(hex: "0A0A18"))
    }

    private var paneTabBar: some View {
        HStack(spacing: 0) {
            ForEach(AssistantPaneTab.allCases) { pane in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedPane = pane }
                } label: {
                    Text(pane == .askAI ? "✦ \(pane.rawValue)" : pane.rawValue)
                        .font(.system(size: 12, weight: selectedPane == pane ? .semibold : .medium))
                        .foregroundColor(selectedPane == pane ? Color(hex: "5B6CF7") : .white.opacity(0.4))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - Ask AI pane

struct AskAIPane: View {
    let meeting: MeetingRecord?

    @State private var messages:      [MeetingChatMessage] = []
    @State private var question:      String = ""
    @State private var isThinking:    Bool   = false
    @State private var thinkingPhase: String = "Searching transcript…"
    @State private var expandedSourceID: UUID? = nil
    @State private var showClearConfirm: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1)

            if messages.isEmpty {
                emptyState
            } else {
                chatList
            }

            Divider().overlay(Color.white.opacity(0.06))
            inputBar
        }
        .onAppear { onAppear() }
        .onChange(of: meeting?.id) { _ in onAppear() }
        .alert("Clear conversation?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) { clearConversation() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all messages for this meeting.")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            Spacer()

            if !messages.isEmpty {
                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(hex: "5B6CF7").opacity(0.3), Color(hex: "8B5CF6").opacity(0.15)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 56, height: 56)
                Text("✦")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "5B6CF7"))
            }

            Text("Ask anything about this meeting")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            VStack(spacing: 6) {
                ForEach(starterQuestions, id: \.self) { q in
                    Button {
                        question = q
                        sendMessage()
                    } label: {
                        Text(q)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var starterQuestions: [String] {
        // Prefer topic-derived suggestions from the AI summary
        if let topics = meeting?.aiSummary?.keyTopics, !topics.isEmpty {
            return Array(topics.prefix(3).map { "Tell me about \($0.text)" })
        }
        return [
            "What were the main decisions?",
            "Summarize the action items",
            "What was discussed about the timeline?",
        ]
    }

    // MARK: - Chat list

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { msg in
                        if msg.role == "user" {
                            userBubble(msg)
                        } else {
                            assistantBubble(msg)
                        }
                    }

                    if isThinking {
                        thinkingBubble
                    }
                }
                .padding(14)
                .id("chatBottom")
            }
            .onChange(of: messages.count) { _ in
                withAnimation { proxy.scrollTo("chatBottom", anchor: .bottom) }
            }
            .onChange(of: isThinking) { thinking in
                if thinking { withAnimation { proxy.scrollTo("chatBottom", anchor: .bottom) } }
            }
        }
    }

    /// Detects RTL script (Hebrew, Arabic) from the first 50 characters of text.
    /// Per CLAUDE.md, SwiftUI Text cannot set paragraph base writing direction reliably —
    /// RTL text requires NSTextField via NSViewRepresentable.
    private static func detectRTL(_ text: String) -> Bool {
        for scalar in text.prefix(50).unicodeScalars {
            let v = scalar.value
            if (v >= 0x0590 && v <= 0x05FF) || (v >= 0x0600 && v <= 0x06FF) { return true }
        }
        return false
    }

    @ViewBuilder
    private func userBubble(_ msg: MeetingChatMessage) -> some View {
        let isRTL = Self.detectRTL(msg.text)
        HStack {
            if !isRTL { Spacer() }
            ChatBubbleTextView(
                text: msg.text, isRTL: isRTL,
                fontSize: 13, textColor: .white
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(hex: "5B6CF7").opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if isRTL { Spacer() }
        }
    }

    @ViewBuilder
    private func assistantBubble(_ msg: MeetingChatMessage) -> some View {
        let isRTL = Self.detectRTL(msg.text)
        VStack(alignment: isRTL ? .trailing : .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                if isRTL { Spacer() }
                if !isRTL {
                    Text("✦")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "5B6CF7"))
                        .padding(.top, 1)
                }
                ChatBubbleTextView(
                    text: msg.text, isRTL: isRTL,
                    fontSize: 13, textColor: NSColor.white.withAlphaComponent(0.85)
                )
                if isRTL {
                    Text("✦")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "5B6CF7"))
                        .padding(.top, 1)
                }
                if !isRTL { Spacer() }
            }

            if let sources = msg.sources, !sources.isEmpty {
                sourcesDisclosure(messageID: msg.id, sources: sources)
            }
        }
    }

    @ViewBuilder
    private func sourcesDisclosure(messageID: UUID, sources: [RAGChunk]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedSourceID = (expandedSourceID == messageID) ? nil : messageID
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 10))
                    Text("\(sources.count) source\(sources.count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: expandedSourceID == messageID ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundColor(Color(hex: "5B6CF7").opacity(0.7))
                .padding(.leading, 20)
            }
            .buttonStyle(.plain)

            if expandedSourceID == messageID {
                VStack(spacing: 5) {
                    ForEach(sources.indices, id: \.self) { i in
                        sourceChip(sources[i])
                    }
                }
                .padding(.leading, 20)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    @ViewBuilder
    private func sourceChip(_ chunk: RAGChunk) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .meetingScrollToTimestamp,
                object: chunk.startTimestamp
            )
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(chunk.formattedStart)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundColor(.orange)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                    Text(chunk.speakersLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "5B6CF7").opacity(0.5))
                }
                Text(chunk.text)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(2)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(hex: "14142B"))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(hex: "5B6CF7").opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Jump to \(chunk.formattedStart) in transcript")
    }

    private var thinkingBubble: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("✦")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "5B6CF7").opacity(0.5))

            HStack(spacing: 4) {
                Text(thinkingPhase)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.35))
                    .animation(.none, value: thinkingPhase)

                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color(hex: "5B6CF7").opacity(0.5))
                            .frame(width: 4, height: 4)
                            .scaleEffect(isThinking ? 1.0 : 0.4)
                            .animation(
                                .easeInOut(duration: 0.5)
                                    .repeatForever()
                                    .delay(Double(i) * 0.15),
                                value: isThinking
                            )
                    }
                }
            }
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about this meeting…", text: $question, axis: .vertical)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .onSubmit { sendMessage() }

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(question.isEmpty || isThinking
                                     ? .white.opacity(0.2)
                                     : Color(hex: "5B6CF7"))
            }
            .buttonStyle(.plain)
            .disabled(question.isEmpty || isThinking)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04))
    }

    // MARK: - Send

    private func sendMessage() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let meeting else { return }
        question = ""

        let userMsg = MeetingChatMessage(role: "user", text: q)
        messages.append(userMsg)
        isThinking = true
        thinkingPhase = "Searching transcript…"

        Task {
            await MeetingChatStore.shared.append(userMsg, meetingID: meeting.id)

            // Switch phase label before LLM call
            await MainActor.run { thinkingPhase = "Generating answer…" }

            let answer = await MeetingAIService.shared.ask(
                question: q,
                meetingID: meeting.id,
                segments: meeting.segments
            )

            let assistantMsg = MeetingChatMessage(
                role:    "assistant",
                text:    answer.text,
                sources: answer.sources.isEmpty ? nil : answer.sources
            )

            await MainActor.run {
                messages.append(assistantMsg)
                isThinking = false
            }

            await MeetingChatStore.shared.append(assistantMsg, meetingID: meeting.id)
        }
    }

    // MARK: - Clear

    private func clearConversation() {
        guard let meeting else { return }
        messages = []
        Task { await MeetingChatStore.shared.clear(meetingID: meeting.id) }
    }

    // MARK: - On appear

    private func onAppear() {
        guard let meeting else { return }
        Task {
            let saved: [MeetingChatMessage] = await MeetingChatStore.shared.load(meetingID: meeting.id)
            await MainActor.run { messages = saved }
        }
    }
}

// MARK: - Live Notes pane

struct LiveNotesPane: View {
    @ObservedObject var session: MeetingSession
    let meeting: MeetingRecord?

    private var notes: [MeetingNote] {
        if session.isRecording && session.meetingID == meeting?.id {
            return session.notes
        }
        return meeting?.notes ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            if notes.isEmpty {
                emptyNotes
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(notes) { note in
                            NoteCard(note: note, onUpdate: { updated in
                                if session.isRecording { session.updateNote(updated) }
                            })
                        }
                    }
                    .padding(12)
                }
            }

            if session.isRecording {
                addNoteBar
            }
        }
    }

    private var emptyNotes: some View {
        VStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.white.opacity(0.15))
            Text("No notes yet")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.3))
            if session.isRecording {
                Text("Add timestamped notes while recording")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.2))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var addNoteBar: some View {
        HStack(spacing: 8) {
            Text("Add:")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.4))
            ForEach(NoteKind.allCases, id: \.self) { kind in
                Button {
                    session.addNote(kind: kind)
                } label: {
                    Text(kind.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: kind.colorHex))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(hex: kind.colorHex).opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }
}

struct NoteCard: View {
    @State var note: MeetingNote
    var onUpdate: ((MeetingNote) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(note.kind.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.4)
                    .foregroundColor(Color(hex: note.kind.colorHex))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: note.kind.colorHex).opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Text(formatTimestamp(note.timestamp))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.3))
            }
            TextField("Note…", text: $note.text, axis: .vertical)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .textFieldStyle(.plain)
                .onChange(of: note.text) { _ in onUpdate?(note) }
        }
        .padding(10)
        .background(Color(hex: "14142B"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - Speakers pane

struct SpeakersPane: View {
    let meeting: MeetingRecord?
    @ObservedObject var session: MeetingSession

    private var segments: [MeetingSegment] {
        if session.isRecording && session.meetingID == meeting?.id {
            return session.segments
        }
        return meeting?.segments ?? []
    }

    private var speakerStats: [(index: Int, name: String, wordCount: Int, turns: Int)] {
        var stats: [Int: (name: String, words: Int, turns: Int)] = [:]
        for seg in segments {
            let wc = seg.text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
            stats[seg.speakerIndex, default: (seg.speakerName, 0, 0)].words += wc
            stats[seg.speakerIndex, default: (seg.speakerName, 0, 0)].turns += 1
            stats[seg.speakerIndex, default: (seg.speakerName, 0, 0)].name = seg.speakerName
        }
        return stats.map { (index: $0.key, name: $0.value.name, wordCount: $0.value.words, turns: $0.value.turns) }
            .sorted { $0.wordCount > $1.wordCount }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if speakerStats.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(.white.opacity(0.15))
                        Text("No speakers yet")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    let totalWords = max(1, speakerStats.map { $0.wordCount }.reduce(0, +))
                    ForEach(speakerStats, id: \.index) { sp in
                        SpeakerStatRow(
                            speaker: sp,
                            fraction: Double(sp.wordCount) / Double(totalWords)
                        )
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - RTL-aware chat text view

/// NSTextField wrapper that sets paragraph base writing direction for RTL text.
/// SwiftUI Text cannot set baseWritingDirection reliably (see CLAUDE.md), so Hebrew and
/// Arabic answers would render with punctuation and [Xs] citations on the wrong side.
/// Mirrors the pattern in MeetingSegmentTextView (MeetingSegmentRow.swift).
private struct ChatBubbleTextView: NSViewRepresentable {
    let text: String
    let isRTL: Bool
    let fontSize: CGFloat
    let textColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isEditable = false
        field.isSelectable = true   // preserves text-selection behaviour
        field.drawsBackground = false
        field.isBordered = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.truncatesLastVisibleLine = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let c = context.coordinator
        guard text != c.lastText || isRTL != c.lastIsRTL else { return }
        c.lastText = text
        c.lastIsRTL = isRTL

        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        style.alignment = isRTL ? .right : .left

        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ])
    }

    final class Coordinator {
        var lastText: String = ""
        var lastIsRTL: Bool = false
    }
}

struct SpeakerStatRow: View {
    let speaker: (index: Int, name: String, wordCount: Int, turns: Int)
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(speakerColor(for: speaker.index).opacity(0.2))
                        .frame(width: 32, height: 32)
                    Text(String(speaker.name.prefix(1)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(speakerColor(for: speaker.index))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Text("\(speaker.wordCount) words · \(speaker.turns) turns")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(speakerColor(for: speaker.index))
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(speakerColor(for: speaker.index).opacity(0.7))
                        .frame(width: geo.size.width * fraction, height: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(Color(hex: "14142B"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
