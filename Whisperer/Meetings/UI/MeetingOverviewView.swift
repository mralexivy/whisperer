//
//  MeetingOverviewView.swift
//  Whisperer
//
//  AI-generated overview tab: summary, decisions, action items.
//

import SwiftUI

struct MeetingOverviewView: View {
    let meeting: MeetingRecord?
    @State private var isGenerating = false
    @State private var generationFailed = false
    @State private var shimmerPhase = false
    @State private var noLLMBanner = false

    private var summary: MeetingAISummary? { meeting?.aiSummary }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if noLLMBanner {
                    noLLMWarning
                }
                if isGenerating {
                    generatingSkeleton
                } else if generationFailed {
                    failureState
                } else if let s = summary {
                    overviewContent(s)
                } else {
                    emptyState
                }
            }
            .padding(20)
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingOverviewDidGenerate)) { note in
            guard let nid = note.object as? UUID, nid == meeting?.id else { return }
            isGenerating = false
            generationFailed = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .meetingOverviewDidFail)) { note in
            guard let nid = note.object as? UUID, nid == meeting?.id else { return }
            isGenerating = false
            generationFailed = true
        }
    }

    // MARK: - Content

    private func overviewContent(_ s: MeetingAISummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Provenance bar
            provenanceBar(s)

            // AI overview card
            overviewCard(s)

            // Key topics
            if !s.keyTopics.isEmpty {
                sectionCard(title: "KEY TOPICS", icon: "tag.fill", color: Color(hex: "5B6CF7")) {
                    ForEach(s.keyTopics) { topic in
                        topicRow(topic)
                    }
                }
            }

            // Decisions
            if !s.decisions.isEmpty {
                sectionCard(title: "DECISIONS", icon: "checkmark.seal.fill", color: Color(hex: "10B981")) {
                    ForEach(s.decisions) { decision in
                        decisionRow(decision)
                    }
                }
            }

            // Open questions
            if !s.openQuestions.isEmpty {
                sectionCard(title: "OPEN QUESTIONS", icon: "questionmark.circle.fill", color: Color(hex: "F59E0B")) {
                    ForEach(s.openQuestions) { q in
                        questionRow(q)
                    }
                }
            }

            // Next meeting
            if let next = s.nextMeeting, !next.isEmpty {
                nextMeetingCard(next)
            }

            // Action items
            if !s.actionItems.isEmpty {
                actionItemsCard(s.actionItems)
            }
        }
    }

    // MARK: - Overview card

    // MARK: - Provenance bar

    private func provenanceBar(_ s: MeetingAISummary) -> some View {
        HStack(spacing: 0) {
            Text("✦ AI overview")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            Text("  ·  from \(meeting?.displayDuration ?? "") of audio  ·  \(generatedAgoString(s.generatedAt))")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.28))
            Spacer()
            Button { regenerate() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Regenerate overview")
            .padding(.leading, 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s.overview, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
            .help("Copy overview")
            .padding(.leading, 8)
        }
    }

    private func generatedAgoString(_ date: Date?) -> String {
        guard let date = date else { return "generated recently" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86400)d ago"
    }

    // MARK: - Overview card

    private func overviewCard(_ s: MeetingAISummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("✦")
                    .font(.system(size: 14))
                    .foregroundColor(Color(hex: "5B6CF7"))
                Text("AI OVERVIEW")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundColor(Color(hex: "5B6CF7"))
                Spacer()
            }

            Text(s.overview)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white.opacity(0.85))
                .lineSpacing(4)
        }
        .padding(16)
        .background(Color(hex: "14142B"))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "5B6CF7").opacity(0.2), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Section card

    private func sectionCard<Content: View>(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(color)
            }
            content()
        }
        .padding(14)
        .background(Color(hex: "14142B"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func topicRow(_ topic: TopicItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: "5B6CF7").opacity(0.5))
                .frame(width: 5, height: 5)
            Text(topic.text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
            Text(formatTimestamp(topic.timestampSeconds))
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func decisionRow(_ decision: DecisionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(decision.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "10B981"))
                Spacer()
                Text(formatTimestamp(decision.timestampSeconds))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.white.opacity(0.3))
            }
            Text(decision.text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(2)
        }
        .padding(.vertical, 4)
    }

    private func questionRow(_ q: QuestionItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color(hex: "F59E0B"))
                .frame(width: 18, height: 18)
                .background(Color(hex: "F59E0B").opacity(0.12))
                .clipShape(Circle())
            Text(q.text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
            Spacer()
        }
    }

    private func nextMeetingCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: "5B6CF7"))
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT MEETING")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Color(hex: "5B6CF7").opacity(0.7))
                Text(text)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
            }
            Spacer()
        }
        .padding(14)
        .background(Color(hex: "5B6CF7").opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Action items

    private func actionItemsCard(_ items: [MeetingActionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "8B5CF6"))
                Text("ACTION ITEMS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
                    .foregroundColor(Color(hex: "8B5CF6"))
            }

            if let meetingID = meeting?.id {
                ForEach(items) { item in
                    ActionItemRow(item: item, meetingID: meetingID)
                }
            }
        }
        .padding(14)
        .background(Color(hex: "14142B"))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Generating skeleton

    private var generatingSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status header
            HStack(spacing: 8) {
                Text("✦")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "5B6CF7"))
                Text("Generating AI overview…")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                ProgressView()
                    .scaleEffect(0.7)
                    .colorScheme(.dark)
            }
            .padding(16)
            .background(Color(hex: "14142B"))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Shimmer placeholder rows
            VStack(alignment: .leading, spacing: 10) {
                skeletonRow(width: nil, height: 14)
                skeletonRow(width: nil, height: 14)
                skeletonRow(width: 200, height: 14)
            }
            .padding(16)
            .background(Color(hex: "14142B"))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            skeletonRow(width: nil, height: 80)
            skeletonRow(width: nil, height: 60)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                shimmerPhase = true
            }
        }
        .onDisappear { shimmerPhase = false }
    }

    private func skeletonRow(width: CGFloat?, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(shimmerPhase ? 0.07 : 0.03))
            .frame(maxWidth: width ?? .infinity)
            .frame(height: height)
    }

    // MARK: - Failure state

    private var failureState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(.red.opacity(0.8))
            Text("Overview generation failed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Text("The AI model could not generate a summary. Check that an AI model is loaded in Settings → AI Modes.")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button("Try Again") { regenerate() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "5B6CF7"))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.white.opacity(0.15))
            Text("No AI overview yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            if meeting?.fullTranscript.isEmpty ?? true {
                Text("Record a meeting to generate an overview")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.25))
                    .multilineTextAlignment(.center)
            } else {
                Button {
                    regenerate()
                } label: {
                    Label("Generate Overview", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [Color(hex: "5B6CF7"), Color(hex: "8B5CF6")],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - No LLM warning

    private var noLLMWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "F59E0B"))
            VStack(alignment: .leading, spacing: 2) {
                Text("No AI model loaded")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Text("Load a model in Settings → AI Modes, then try again.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            Button {
                withAnimation { noLLMBanner = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(hex: "F59E0B").opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(hex: "F59E0B").opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Helpers

    private func regenerate() {
        guard !isGenerating else { return }
        guard let meeting else { return }
        noLLMBanner = false
        generationFailed = false
        isGenerating = true
        let segments = meeting.segments
        let id = meeting.id
        let title = meeting.title
        Task {
            // generateTitle / generateOverview each own their borrow/release via
            // MeetingEngines.borrowLLM(). If the engine is unavailable either method
            // posts .meetingOverviewDidFail, which sets generationFailed = true.
            await MeetingAIService.shared.generateTitle(segments: segments, meetingID: id, currentTitle: title)
            await MeetingAIService.shared.generateOverview(segments: segments, meetingID: id)
            await MainActor.run { isGenerating = false }
        }
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Action item row

struct ActionItemRow: View {
    @State var item: MeetingActionItem
    let meetingID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                item.isDone.toggle()
                Task { await MeetingManager.shared.updateActionItem(meetingID: meetingID, item: item) }
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(item.isDone ? Color(hex: "10B981") : .white.opacity(0.3))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundColor(item.isDone ? .white.opacity(0.4) : .white.opacity(0.85))
                    .strikethrough(item.isDone, color: .white.opacity(0.3))
                HStack(spacing: 8) {
                    if !item.ownerName.isEmpty {
                        Label(item.ownerName, systemImage: "person")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    if let due = item.dueLabel {
                        Label(due, systemImage: "calendar")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}
