//
//  HistoryWindowView.swift
//  Whisperer
//
//  Main SwiftUI view for history window with sidebar navigation
//

import SwiftUI
import AppKit

// MARK: - Design System Colors

struct WhispererColors {
    // Primary accent blue (selections, indicators, toggles — matches onboarding)
    static let accent = Color(red: 0.357, green: 0.424, blue: 0.969)    // #5B6CF7
    static let accentDark = Color(red: 0.298, green: 0.365, blue: 0.910) // #4C5DE8

    // Blue-purple accent for primary CTA buttons (matches onboarding)
    static let accentBlue = Color(red: 0.357, green: 0.424, blue: 0.969)    // #5B6CF7
    static let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)  // #8B5CF6

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentBlue, accentPurple], startPoint: .leading, endPoint: .trailing)
    }

    // Backgrounds — deep navy palette (always dark)
    static func background(_ scheme: ColorScheme) -> Color {
        Color(red: 0.047, green: 0.047, blue: 0.102)       // #0C0C1A
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        Color(red: 0.078, green: 0.078, blue: 0.169)       // #14142B
    }

    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        Color(red: 0.039, green: 0.039, blue: 0.094)       // #0A0A18
    }

    static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        Color(red: 0.110, green: 0.110, blue: 0.227)       // #1C1C3A
    }

    // Text — white with opacity levels
    static func primaryText(_ scheme: ColorScheme) -> Color {
        Color.white
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(0.5)
    }

    static func tertiaryText(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(0.35)
    }

    // Borders — subtle white
    static func border(_ scheme: ColorScheme) -> Color {
        Color.white.opacity(0.06)
    }

    // Pill/badge backgrounds
    static let pillBackground = Color.white.opacity(0.08)
}

// MARK: - Time Format Setting

enum TimeFormatSetting: String, CaseIterable {
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    var displayName: String {
        switch self {
        case .twelveHour: return "12-hour (AM/PM)"
        case .twentyFourHour: return "24-hour"
        }
    }

    var dateFormat: String {
        switch self {
        case .twelveHour: return "h:mm a"
        case .twentyFourHour: return "HH:mm"
        }
    }
}

// MARK: - Navigation

enum HistorySidebarItem: String, CaseIterable, Identifiable {
    case transcriptions = "Transcriptions"
    case fileTranscription = "File Transcription"
    case dictionary = "Dictionary"
    case statistics = "Statistics"
    case settings = "Settings"
    case commandMode = "Command Mode"
    case setup = "Setup"
    case feedback = "Feedback"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcriptions: return "waveform.and.mic"
        case .fileTranscription: return "doc.text.magnifyingglass"
        case .statistics: return "chart.xyaxis.line"
        case .dictionary: return "book.closed"
        case .settings: return "gearshape"
        case .commandMode: return "terminal.fill"
        case .setup: return "checkmark.circle.fill"
        case .feedback: return "envelope.fill"
        }
    }

    var color: Color {
        switch self {
        case .transcriptions: return WhispererColors.accentBlue
        case .fileTranscription: return .purple
        case .statistics: return .cyan
        case .dictionary: return .red
        case .settings: return .orange
        case .commandMode: return Color(hex: "22C55E")
        case .setup: return .blue
        case .feedback: return Color(hex: "22C55E")
        }
    }

    /// Items shown in the sidebar (commandMode only in non-sandboxed builds)
    static var visibleItems: [HistorySidebarItem] {
        var items: [HistorySidebarItem] = [.transcriptions, .fileTranscription, .dictionary, .statistics, .setup, .feedback, .settings]
        #if !ENABLE_APP_SANDBOX
        items.insert(.commandMode, at: items.count - 3) // Before setup
        #endif
        return items
    }
}

// MARK: - Main View

struct HistoryWindowView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var selectedSidebarItem: HistorySidebarItem = .transcriptions
    @State private var isSidebarCollapsed = false

    #if !ENABLE_APP_SANDBOX
    @StateObject private var commandModeService: CommandModeService = {
        if let processor = AppState.shared.llmPostProcessor, processor.isModelLoaded {
            return CommandModeService(llmProcessor: processor)
        }
        return CommandModeService(llmProcessor: LLMPostProcessor())
    }()
    #else
    private let commandModeService: AnyObject? = nil
    #endif

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar (collapsible)
            if !isSidebarCollapsed {
                sidebarView

                // Divider
                Rectangle()
                    .fill(WhispererColors.border(colorScheme))
                    .frame(width: 1)
            }

            // Main content
            Group {
                switch selectedSidebarItem {
                case .transcriptions:
                    TranscriptionsView()
                case .fileTranscription:
                    FileTranscriptionView()
                case .statistics:
                    StatisticsView()
                case .dictionary:
                    DictionaryView()
                case .settings:
                    HistorySettingsView()
                case .commandMode:
                    #if !ENABLE_APP_SANDBOX
                    CommandModeView(commandService: commandModeService)
                    #else
                    EmptyView()
                    #endif
                case .setup:
                    SetupChecklistView()
                case .feedback:
                    FeedbackView()
                }
            }
        }
        .frame(minWidth: isSidebarCollapsed ? 700 : 1100, minHeight: 700)
        .tahoeTextFix()
        .background(WhispererColors.background(colorScheme))
        .onReceive(NotificationCenter.default.publisher(for: .switchToDictionaryTab)) { notification in
            withAnimation(.spring(response: 0.3)) {
                selectedSidebarItem = .dictionary
                if isSidebarCollapsed {
                    isSidebarCollapsed = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleWorkspaceSidebar)) { _ in
            withAnimation(.spring(response: 0.3)) {
                isSidebarCollapsed.toggle()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Logo/Brand header
            brandHeader

            // Navigation items
            VStack(spacing: 4) {
                ForEach(HistorySidebarItem.visibleItems) { item in
                    SidebarNavItem(
                        item: item,
                        isSelected: selectedSidebarItem == item,
                        colorScheme: colorScheme
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            selectedSidebarItem = item
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Spacer()

            // Stats card
            if let stats = historyManager.statistics {
                sidebarStatsCard(stats)
            }

            sidebarVersionLabel
        }
        .frame(width: 220)
        .background(WhispererColors.sidebarBackground(colorScheme))
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            // App icon — rounded square with blue-purple gradient
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accentBlue.opacity(0.18),
                                WhispererColors.accentPurple.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(WhispererColors.accentBlue.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: WhispererColors.accentBlue.opacity(0.15), radius: 6, y: 2)

                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Whisperer")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Workspace")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
        .padding(20)
        .frame(height: 84, alignment: .center)
        .background(WhispererColors.sidebarBackground(colorScheme))

    }

    private func sidebarStatsCard(_ stats: HistoryStatistics) -> some View {
        VStack(spacing: 14) {
            sidebarStatRow(label: "RECORDINGS", value: "\(stats.totalRecordings)", valueColor: WhispererColors.accentBlue)
            sidebarStatRow(label: "WORDS", value: formatSidebarNumber(stats.totalWords), valueColor: .red)
            sidebarStatRow(label: "AVG WPM", value: "\(stats.averageWPM)", valueColor: .orange)
            sidebarStatRow(label: "DAYS", value: "\(stats.totalDays)", valueColor: .cyan)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            WhispererColors.accent.opacity(colorScheme == .dark ? 0.1 : 0.06),
                            WhispererColors.accent.opacity(colorScheme == .dark ? 0.04 : 0.02),
                            WhispererColors.cardBackground(colorScheme)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [
                            WhispererColors.accent.opacity(0.2),
                            WhispererColors.accent.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: WhispererColors.accent.opacity(colorScheme == .dark ? 0.08 : 0.04),
            radius: 8,
            y: 2
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func sidebarStatRow(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .tracking(0.8)

            Spacer()

            Text(value)
                .font(.system(size: 16, weight: .light, design: .rounded))
                .foregroundColor(valueColor ?? WhispererColors.primaryText(colorScheme))
        }
    }

    private func formatSidebarNumber(_ number: Int) -> String {
        if number >= 1000 {
            return String(format: "%.1fK", Double(number) / 1000)
        }
        return "\(number)"
    }

    private var sidebarVersionLabel: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        return Text("Whisperer v\(version) (\(build))")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
    }
}

// MARK: - Sidebar Navigation Item

struct SidebarNavItem: View {
    let item: HistorySidebarItem
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(item.color)
                    .frame(width: 20)

                Text(item.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? WhispererColors.primaryText(colorScheme) : (isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme)))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? item.color.opacity(0.15) : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? item.color.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .shadow(
                color: isSelected ? item.color.opacity(0.06) : Color.clear,
                radius: 4, y: 1
            )
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Transcriptions View (Main Content)

struct TranscriptionsView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var historyManager = HistoryManager.shared
    @State private var searchText = ""
    @State private var selectedFilter: TranscriptionFilter = .all
    @State private var selectedTranscription: TranscriptionRecord?
    @State private var detailPanelWidth: CGFloat = 420
    @State private var dailyQuote: String = DailyQuotes.random
    @State private var dateRangeStart: Date?
    @State private var dateRangeEnd: Date?
    @State private var showCalendarPicker = false
    @State private var datesWithTranscriptions: Set<Date> = []

    private let minDetailWidth: CGFloat = 320
    private let maxDetailWidth: CGFloat = 600

    var body: some View {
        HStack(spacing: 0) {
            // List panel
            VStack(spacing: 0) {
                headerView
                toolbarView
                transcriptionList
            }
            .frame(minWidth: 400, maxWidth: .infinity)
            .clipped()

            // Detail panel with resizable divider
            if let selected = selectedTranscription {
                // Resizable divider
                ResizableDivider(colorScheme: colorScheme) { delta in
                    let newWidth = detailPanelWidth - delta
                    detailPanelWidth = min(max(newWidth, minDetailWidth), maxDetailWidth)
                }

                TranscriptionDetailView(
                    transcription: selected,
                    onClose: { withAnimation(.spring(response: 0.3)) { selectedTranscription = nil } }
                )
                .id(selected.id) // Force view recreation when transcription changes
                .frame(width: detailPanelWidth)
                .clipped()
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .background(WhispererColors.background(colorScheme))
        .onAppear {
            // Auto-select first transcription so detail panel is open by default
            if selectedTranscription == nil, let first = historyManager.transcriptions.first {
                selectedTranscription = first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            dailyQuote = DailyQuotes.random
        }
        .onChange(of: historyManager.transcriptions.count) { _ in
            // Select first item when data loads if nothing is selected
            if selectedTranscription == nil, let first = historyManager.transcriptions.first {
                selectedTranscription = first
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                // Avatar — blue-purple gradient fill with shadow
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [
                                    WhispererColors.accentBlue.opacity(0.18),
                                    WhispererColors.accentPurple.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(WhispererColors.accentBlue.opacity(0.2), lineWidth: 0.5)
                        )
                        .shadow(color: WhispererColors.accentBlue.opacity(0.1), radius: 6, y: 2)

                    Text(initials)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(firstName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    Text(greeting)
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                Spacer()

                // Daily quote
                HStack(alignment: .center, spacing: 10) {
                    Text("\u{201C}")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(y: -2)

                    Text(dailyQuote)
                        .font(.system(size: 15, weight: .light, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                        .italic()
                        .lineLimit(1)

                    Text("\u{201D}")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .offset(y: -2)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 72)

            // Subtle gradient separator
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            WhispererColors.border(colorScheme).opacity(0.6),
                            WhispererColors.border(colorScheme),
                            WhispererColors.border(colorScheme).opacity(0.6)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        VStack(spacing: 12) {
            // Search row
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))

                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .onChange(of: searchText) { _ in
                        performSearch()
                    }

                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                    .buttonStyle(.plain).pointerOnHover()
                } else {
                    // ⌘K shortcut badge
                    HStack(spacing: 2) {
                        Text("⌘")
                            .font(.system(size: 10, weight: .medium))
                        Text("K")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(WhispererColors.elevatedBackground(colorScheme))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WhispererColors.elevatedBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.06 : 0.03),
                radius: 3, y: 1
            )

            // Filters row (separate line)
            HStack(spacing: 6) {
                FilterTab(title: "All", isSelected: selectedFilter == .all, colorScheme: colorScheme, color: WhispererColors.accentBlue) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .all }
                    performSearch()
                }
                FilterTab(title: "Pinned", isSelected: selectedFilter == .pinned, colorScheme: colorScheme, color: .orange) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .pinned }
                    performSearch()
                }
                FilterTab(title: "Flagged", isSelected: selectedFilter == .flagged, colorScheme: colorScheme, color: .red) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .flagged }
                    performSearch()
                }

                if let start = dateRangeStart {
                    dateRangeChip(start: start, end: dateRangeEnd ?? start)
                }

                Spacer()

                calendarButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - List

    private var transcriptionList: some View {
        Group {
            if historyManager.transcriptions.isEmpty && !historyManager.isLoadingPage {
                emptyStateView
            } else if historyManager.transcriptions.isEmpty && historyManager.isLoadingPage {
                // Initial load — show centered loading
                VStack {
                    Spacer()
                    loadingIndicator
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedTranscriptions.keys.sorted(by: >), id: \.self) { date in
                            Section(header: sectionHeader(for: date)) {
                                VStack(spacing: 8) {
                                    ForEach(groupedTranscriptions[date] ?? []) { transcription in
                                        TranscriptionRow(
                                            transcription: transcription,
                                            isSelected: selectedTranscription?.id == transcription.id,
                                            colorScheme: colorScheme,
                                            onSelect: {
                                                withAnimation(.spring(response: 0.3)) {
                                                    selectedTranscription = transcription
                                                }
                                            }
                                        )
                                    }
                                }
                                .padding(.bottom, 8)
                            }
                        }

                        // Sentinel + loading indicator for next page
                        if historyManager.hasMorePages {
                            loadingIndicator
                                .id("sentinel-\(historyManager.transcriptions.count)")
                                .onAppear {
                                    Task {
                                        await historyManager.loadNextPage()
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private var loadingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(WhispererColors.accentBlue)
            Text("Loading...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accentBlue.opacity(0.18),
                                WhispererColors.accentPurple.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 28))
                    .foregroundColor(WhispererColors.accentBlue)
            }

            VStack(spacing: 6) {
                Text("No Transcriptions Yet")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Hold Fn to record, then release to transcribe.")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    }

    private func sectionHeader(for date: Date) -> some View {
        HStack(spacing: 10) {
            Text(dateHeaderString(for: date))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.5)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            WhispererColors.border(colorScheme),
                            WhispererColors.border(colorScheme).opacity(0.2)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
        }
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(WhispererColors.background(colorScheme))

    }

    // MARK: - Helpers

    private var initials: String {
        let name = NSFullUserName()
        let components = name.split(separator: " ")
        if components.count >= 2 {
            return "\(components[0].prefix(1))\(components[1].prefix(1))"
        }
        return String(name.prefix(2)).uppercased()
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "User"
    }

    private var greeting: String {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0

        // Time-of-day greetings — the main pool
        let timeMessages: [String]
        switch hour {
        case 5..<8:
            timeMessages = [
                "You're up early. I like that",
                "Early bird gets the words",
                "Coffee first, then conquer",
                "Up before the sun? Respect",
                "The world's still sleeping",
                "Best time to get things done",
            ]
        case 8..<12:
            timeMessages = [
                "Good morning",
                "Morning! Big day ahead?",
                "Let's make today count",
                "Ready to crush it today?",
                "Fresh day, fresh start",
                "Morning. What's the plan?",
            ]
        case 12..<14:
            timeMessages = [
                "Lunch can wait, right?",
                "Halfway through the day",
                "Good midday",
                "Powering through, I see",
                "Hope your morning was solid",
            ]
        case 14..<17:
            timeMessages = [
                "Good afternoon",
                "Afternoon hustle. Love to see it",
                "The home stretch",
                "Keep the momentum going",
                "Almost there. Finish strong",
            ]
        case 17..<20:
            timeMessages = [
                "Good evening",
                "Wrapping up for the day?",
                "One more thing before you go?",
                "Hope today was a good one",
                "Evening vibes. Nice",
            ]
        case 20..<22:
            timeMessages = [
                "Still at it? Impressive",
                "Your dedication is showing",
                "Evening grind. Respect",
                "Shouldn't you be relaxing?",
                "Going the extra mile tonight",
            ]
        default:
            timeMessages = [
                "What are you doing up so late?",
                "Shouldn't you be sleeping?",
                "Your bed misses you",
                "The best ideas come at night",
                "Go to sleep... after this one thing",
                "Does anyone know you're still up?",
                "Okay, one more. Then bed",
                "Night owl energy",
            ]
        }

        // Day-of-week greetings
        let weekdayMessages: [String]
        switch weekday {
        case 1: weekdayMessages = ["Sunday funday", "Productive Sunday, huh?"]
        case 2: weekdayMessages = ["Monday again. We got this", "New week, new energy"]
        case 3: weekdayMessages = ["Tuesday momentum", "Let's keep it rolling"]
        case 4: weekdayMessages = ["Hump day. Downhill from here", "Midweek already"]
        case 5: weekdayMessages = ["Thursday. So close to Friday", "One more day"]
        case 6: weekdayMessages = ["It's Friday! You made it", "TGIF", "Weekend countdown: started"]
        case 7: weekdayMessages = ["Working on a Saturday? Dedication", "Saturday vibes"]
        default: weekdayMessages = ["Welcome back"]
        }

        let universalMessages = [
            "Welcome back",
            "Look who's here",
            "Missed you. A little",
            "Back for more?",
            "Good to see you again",
            "The usual?",
            "Right where we left off",
        ]

        // Pick category first, then pick within it.
        // 3 out of 5 days → time-of-day, 1 → day-of-week, 1 → universal.
        // Ensures time-relevant greetings appear most often.
        let pool: [String]
        switch day % 5 {
        case 0, 1, 2: pool = timeMessages
        case 3: pool = weekdayMessages
        default: pool = universalMessages
        }

        // Deterministic within time window — stable across view redraws
        let index = (day + hour) % pool.count
        return pool[index]
    }

    private var groupedTranscriptions: [Date: [TranscriptionRecord]] {
        Dictionary(grouping: historyManager.transcriptions) { transcription in
            Calendar.current.startOfDay(for: transcription.timestamp)
        }
    }

    private func dateHeaderString(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMMM d"
            return formatter.string(from: date)
        }
    }

    private func performSearch() {
        var dateRange: (start: Date, end: Date)?
        if let start = dateRangeStart {
            dateRange = (start: start, end: dateRangeEnd ?? start)
        }
        Task {
            await historyManager.loadTranscriptions(
                filter: selectedFilter,
                searchQuery: searchText.isEmpty ? nil : searchText,
                dateRange: dateRange
            )
        }
    }

    private func performSearchWithDateRange(start: Date, end: Date) {
        Task {
            await historyManager.loadTranscriptions(
                filter: selectedFilter,
                searchQuery: searchText.isEmpty ? nil : searchText,
                dateRange: (start: start, end: end)
            )
        }
    }

    // MARK: - Calendar Filter

    private var calendarButton: some View {
        let isActive = dateRangeStart != nil
        return Button(action: {
            Task { datesWithTranscriptions = await historyManager.fetchDatesWithTranscriptions() }
            showCalendarPicker.toggle()
        }) {
            Image(systemName: "calendar")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isActive ? .white : WhispererColors.secondaryText(colorScheme))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isActive ? WhispererColors.accentBlue : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(isActive ? Color.clear : WhispererColors.border(colorScheme), lineWidth: 1)
                )
                .shadow(
                    color: isActive ? WhispererColors.accentBlue.opacity(0.25) : Color.clear,
                    radius: 4, y: 1
                )
        }
        .buttonStyle(.plain).pointerOnHover()
        .popover(isPresented: $showCalendarPicker, arrowEdge: .top) {
            CalendarPickerView(
                startDate: $dateRangeStart,
                endDate: $dateRangeEnd,
                datesWithTranscriptions: datesWithTranscriptions,
                colorScheme: colorScheme,
                onApply: { start, end in
                    dateRangeStart = start
                    dateRangeEnd = end
                    performSearchWithDateRange(start: start, end: end)
                },
                onPresetApply: { start, end in
                    dateRangeStart = start
                    dateRangeEnd = end
                    showCalendarPicker = false
                    performSearchWithDateRange(start: start, end: end)
                },
                onReset: {
                    dateRangeStart = nil
                    dateRangeEnd = nil
                    showCalendarPicker = false
                    performSearch()
                }
            )
        }
    }

    private func dateRangeChip(start: Date, end: Date) -> some View {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)
        let label = Calendar.current.isDate(start, inSameDayAs: end) ? startStr : "\(startStr) – \(endStr)"

        return HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .semibold))
            Button(action: {
                withAnimation(.spring(response: 0.3)) {
                    dateRangeStart = nil
                    dateRangeEnd = nil
                }
                performSearch()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).pointerOnHover()
        }
        .foregroundColor(WhispererColors.accentBlue)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(WhispererColors.accentBlue.opacity(0.12))
        )
    }
}

// MARK: - History Settings View

struct HistorySettingsView: View {
    @Environment(\.colorScheme) var colorScheme
    @AppStorage("saveAudioRecordings") private var saveAudioRecordings = true
    @AppStorage("autoDeleteAfterDays") private var autoDeleteAfterDays = 0
    @AppStorage("timeFormat") private var timeFormat: String = TimeFormatSetting.twelveHour.rawValue
    @State private var showDeleteConfirmation = false

    private var selectedTimeFormat: Binding<TimeFormatSetting> {
        Binding(
            get: { TimeFormatSetting(rawValue: timeFormat) ?? .twelveHour },
            set: { timeFormat = $0.rawValue }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                settingsHeader
                    .padding(.bottom, 32)

                // Settings content
                VStack(alignment: .leading, spacing: 28) {
                    displaySection
                    overlaySection
                    rewriteSection
                    dictionarySection
                    storageSection
                    dataManagementSection
                    dangerZoneSection
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .alert("Delete All History?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteAllHistory()
            }
        } message: {
            Text("This will permanently remove all transcriptions and audio files. This action cannot be undone.")
        }
    }

    // MARK: - Header

    private var settingsHeader: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accentBlue.opacity(0.18),
                                WhispererColors.accentPurple.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: WhispererColors.accentBlue.opacity(0.08), radius: 4, y: 1)

                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(WhispererColors.accentBlue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Configure your transcription history preferences")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Display Section

    private var displaySection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "clock.fill",
                    title: "Display",
                    colorScheme: colorScheme,
                    color: .orange
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text("Time Format")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    HStack(spacing: 12) {
                        ForEach(TimeFormatSetting.allCases, id: \.self) { format in
                            TimeFormatCard(
                                format: format,
                                isSelected: selectedTimeFormat.wrappedValue == format,
                                colorScheme: colorScheme
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    selectedTimeFormat.wrappedValue = format
                                }
                            }
                        }

                        Spacer()
                    }

                    Text("Choose how timestamps appear in your history")
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                // Live transcription preview toggle
                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.purple.opacity(0.18),
                                            Color.purple.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "text.bubble")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.purple)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Live Transcription Preview")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Show words as you speak during recording")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { AppState.shared.liveTranscriptionEnabled },
                            set: { AppState.shared.liveTranscriptionEnabled = $0 }
                        ))
                            .toggleStyle(.switch)
                            .tint(WhispererColors.accent)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Dictionary Section

    private var dictionarySection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "book.closed.fill",
                    title: "Dictionary Corrections",
                    colorScheme: colorScheme,
                    color: .red
                )

                // Enable dictionary toggle
                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            WhispererColors.accentBlue.opacity(0.18),
                                            WhispererColors.accentPurple.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "text.badge.checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.accentBlue)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Enable Dictionary Corrections")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Auto-correct technical terms and common mistakes")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { DictionaryManager.shared.isEnabled },
                            set: { DictionaryManager.shared.isEnabled = $0 }
                        ))
                            .toggleStyle(.switch)
                            .tint(WhispererColors.accent)
                            .labelsHidden()
                    }
                }

                // Fuzzy matching sensitivity slider
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Fuzzy Matching Sensitivity")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Spacer()

                        Text(sensitivityLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(WhispererColors.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.12))
                            )
                    }

                    HStack(spacing: 12) {
                        Text("Strict")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))

                        Slider(
                            value: Binding(
                                get: { Double(DictionaryManager.shared.fuzzyMatchingSensitivity) },
                                set: { DictionaryManager.shared.fuzzyMatchingSensitivity = Int($0) }
                            ),
                            in: 0...3,
                            step: 1
                        )
                        .tint(WhispererColors.accent)

                        Text("Lenient")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }

                    Text(sensitivityDescription)
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                // Phonetic matching toggle
                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            WhispererColors.accentBlue.opacity(0.18),
                                            WhispererColors.accentPurple.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "waveform.and.mic")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.accentBlue)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Phonetic Matching")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Match words by sound (e.g., 'jason' → 'JSON')")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { DictionaryManager.shared.usePhoneticMatching },
                            set: { DictionaryManager.shared.usePhoneticMatching = $0 }
                        ))
                            .toggleStyle(.switch)
                            .tint(WhispererColors.accent)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    private var sensitivityLabel: String {
        let sensitivity = DictionaryManager.shared.fuzzyMatchingSensitivity
        switch sensitivity {
        case 0: return "Exact Only"
        case 1: return "Strict"
        case 2: return "Balanced"
        case 3: return "Lenient"
        default: return "Balanced"
        }
    }

    private var sensitivityDescription: String {
        let sensitivity = DictionaryManager.shared.fuzzyMatchingSensitivity
        switch sensitivity {
        case 0: return "Only exact matches will be corrected (no fuzzy matching)"
        case 1: return "Only very close matches (1 character difference)"
        case 2: return "Balanced corrections (up to 2 character differences) — recommended"
        case 3: return "Lenient corrections (up to 3 character differences) — may have false positives"
        default: return "Balanced corrections — recommended"
        }
    }

    // MARK: - Overlay Section

    private var overlaySection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "rectangle.inset.bottomleading.filled",
                    title: "Overlay",
                    colorScheme: colorScheme,
                    color: .blue
                )

                Text("recording panel appearance")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.blue.opacity(0.18), Color.blue.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.blue)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Position")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Where the recording overlay appears")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: {
                                let raw = UserDefaults.standard.string(forKey: "overlayPosition") ?? OverlayPosition.bottomCenter.rawValue
                                return OverlayPosition(rawValue: raw) ?? .bottomCenter
                            },
                            set: {
                                UserDefaults.standard.set($0.rawValue, forKey: "overlayPosition")
                                NotificationCenter.default.post(name: .overlaySettingsChanged, object: nil)
                            }
                        )) {
                            ForEach(OverlayPosition.allCases, id: \.self) { pos in
                                Text(pos.rawValue).tag(pos)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .tint(WhispererColors.accent)
                    }
                }

                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.purple.opacity(0.18), Color.purple.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.purple)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Size")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Recording overlay panel size")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: {
                                let raw = UserDefaults.standard.string(forKey: "overlaySize") ?? OverlaySize.medium.rawValue
                                return OverlaySize(rawValue: raw) ?? .medium
                            },
                            set: {
                                UserDefaults.standard.set($0.rawValue, forKey: "overlaySize")
                                NotificationCenter.default.post(name: .overlaySettingsChanged, object: nil)
                            }
                        )) {
                            ForEach(OverlaySize.allCases, id: \.self) { size in
                                Text(size.rawValue).tag(size)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                        .tint(WhispererColors.accent)
                    }
                }

                // Sound feedback
                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.cyan.opacity(0.18), Color.cyan.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.cyan)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Sound Feedback")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Audio cue when recording starts and stops")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Picker("", selection: Binding(
                            get: { AppState.shared.soundPlayer?.soundOption ?? .defaultSounds },
                            set: { newValue in
                                AppState.shared.soundPlayer?.soundOption = newValue
                                newValue.save()
                            }
                        )) {
                            ForEach(SoundOption.allCases, id: \.self) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 110)
                        .tint(WhispererColors.accent)
                    }
                }
            }
        }
    }

    // MARK: - Rewrite Section

    private var rewriteSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "wand.and.stars",
                    title: "Rewrite Mode",
                    colorScheme: colorScheme,
                    color: Color(hex: "8B5CF6")
                )

                Text("AI-powered text editing via voice")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(hex: "8B5CF6").opacity(0.18), Color(hex: "8B5CF6").opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "keyboard")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(hex: "8B5CF6"))
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Rewrite Shortcut")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Hold to rewrite selected text with voice instructions")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        let config = AppState.shared.keyListener?.rewriteShortcutConfig ?? .defaultConfig
                        Text(config.displayString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(config.isEnabled ? WhispererColors.accent : WhispererColors.tertiaryText(colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                    }
                }

                Text("Select text in any app, hold the rewrite shortcut, and speak your instruction. The AI will rewrite the selected text accordingly. Configure the shortcut in the menu bar settings.")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .lineSpacing(3)
            }
        }
    }

    // MARK: - Storage Section

    private var storageSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "externaldrive.fill",
                    title: "Storage",
                    colorScheme: colorScheme,
                    color: .cyan
                )

                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            WhispererColors.accentBlue.opacity(0.18),
                                            WhispererColors.accentPurple.opacity(0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)

                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.accentBlue)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Save Audio Recordings")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text("Keep original audio files with transcriptions")
                                .font(.system(size: 11))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }

                        Spacer()

                        Toggle("", isOn: $saveAudioRecordings)
                            .toggleStyle(.switch)
                            .tint(WhispererColors.accent)
                            .labelsHidden()
                    }
                }
            }
        }
    }

    // MARK: - Data Management Section

    private var dataManagementSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "clock.arrow.circlepath",
                    title: "Data Management",
                    colorScheme: colorScheme,
                    color: .red
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text("Auto-delete old transcriptions")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    // Custom retention picker
                    HStack(spacing: 8) {
                        ForEach(retentionOptions, id: \.value) { option in
                            RetentionOptionButton(
                                label: option.label,
                                isSelected: autoDeleteAfterDays == option.value,
                                colorScheme: colorScheme
                            ) {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                    autoDeleteAfterDays = option.value
                                }
                            }
                        }
                    }

                    Text("Transcriptions older than the selected period will be automatically removed")
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
            }
        }
    }

    // MARK: - Danger Zone Section

    private var dangerZoneSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.red)

                Text("Danger Zone")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.red)
            }

            SettingsCard(colorScheme: colorScheme, borderColor: .red.opacity(colorScheme == .dark ? 0.15 : 0.3)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.red.opacity(colorScheme == .dark ? 0.15 : 0.12),
                                        Color.red.opacity(colorScheme == .dark ? 0.06 : 0.05)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 42, height: 42)

                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.red)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Delete All History")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text("Permanently remove all transcriptions and audio files")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }

                    Spacer()

                    DangerButton(action: { showDeleteConfirmation = true }, colorScheme: colorScheme)
                }
            }
        }
    }

    // MARK: - Helpers

    private var retentionOptions: [(label: String, value: Int)] {
        [
            ("Never", 0),
            ("7 days", 7),
            ("30 days", 30),
            ("90 days", 90),
            ("1 year", 365)
        ]
    }

    private func deleteAllHistory() {
        Task {
            try? await HistoryManager.shared.deleteAllTranscriptions()
        }
    }
}

// MARK: - Settings Components

struct SettingsCard<Content: View>: View {
    let colorScheme: ColorScheme
    var borderColor: Color? = nil
    var fillHeight: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isHovered ? WhispererColors.elevatedBackground(colorScheme).opacity(0.3) : WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(
                        borderColor ?? WhispererColors.border(colorScheme).opacity(isHovered ? (colorScheme == .dark ? 2.5 : 1.2) : 1),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? (isHovered ? 0.12 : 0.06) : (isHovered ? 0.06 : 0.03)),
                radius: isHovered ? 6 : 4, y: isHovered ? 2 : 1
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

struct SettingsSectionHeader: View {
    let icon: String
    let title: String
    let colorScheme: ColorScheme
    var color: Color = WhispererColors.accentBlue

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)
                    .shadow(color: color.opacity(0.08), radius: 3, y: 1)

                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(color)
            }

            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
        }
    }
}

struct SettingsRow<Content: View>: View {
    let colorScheme: ColorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5))
            )
    }
}

struct DangerButton: View {
    let action: () -> Void
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Delete All")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.red.opacity(0.85) : Color.red)
                )
                .shadow(
                    color: isHovered ? Color.red.opacity(colorScheme == .dark ? 0.2 : 0.3) : .clear,
                    radius: 6, y: 2
                )
                .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct TimeFormatCard: View {
    let format: TimeFormatSetting
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    private var exampleTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = format.dateFormat
        var components = DateComponents()
        components.hour = 19
        components.minute = 30
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(exampleTime)
                    .font(.system(size: 18, weight: .light, design: .monospaced))
                    .foregroundColor(isSelected ? .white : WhispererColors.primaryText(colorScheme))

                Text(format.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.85) : WhispererColors.secondaryText(colorScheme))
            }
            .frame(width: 140, height: 72)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? WhispererColors.accent : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : WhispererColors.background(colorScheme)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected
                            ? WhispererColors.accent
                            : WhispererColors.border(colorScheme).opacity(isHovered ? (colorScheme == .dark ? 2.5 : 1.2) : 1),
                        lineWidth: isSelected ? 0 : 1
                    )
            )
            .shadow(
                color: isSelected
                    ? WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.3)
                    : .clear,
                radius: 8, x: 0, y: 4
            )
            .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct RetentionOptionButton: View {
    let label: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : (isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme)))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? WhispererColors.accent : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            isSelected
                                ? Color.clear
                                : WhispererColors.border(colorScheme).opacity(isHovered ? (colorScheme == .dark ? 2.5 : 1.2) : 1),
                            lineWidth: 1
                        )
                )
                .shadow(
                    color: isSelected ? WhispererColors.accent.opacity(colorScheme == .dark ? 0.15 : 0.25) : .clear,
                    radius: 4, y: 1
                )
                .scaleEffect(isHovered && !isSelected ? 1.02 : 1.0)
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Calendar Picker

struct CalendarPickerView: View {
    @Binding var startDate: Date?
    @Binding var endDate: Date?
    let datesWithTranscriptions: Set<Date>
    let colorScheme: ColorScheme
    let onApply: (_ start: Date, _ end: Date) -> Void
    let onPresetApply: (_ start: Date, _ end: Date) -> Void
    let onReset: () -> Void

    @State private var leftMonth: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var rightMonth: Date = Date()

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...]) + Array(symbols[..<offset])
    }

    var body: some View {
        VStack(spacing: 0) {
            // Two calendars side by side
            HStack(alignment: .top, spacing: 0) {
                // Left calendar — FROM
                calendarGrid(
                    month: $leftMonth,
                    label: "FROM",
                    labelColor: WhispererColors.accentBlue,
                    side: .start
                )

                // Vertical divider
                Rectangle()
                    .fill(WhispererColors.border(colorScheme))
                    .frame(width: 0.5)
                    .padding(.vertical, 16)

                // Right calendar — TO
                calendarGrid(
                    month: $rightMonth,
                    label: "TO",
                    labelColor: WhispererColors.accentPurple,
                    side: .end
                )
            }

            // Divider
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(height: 0.5)
                .padding(.horizontal, 16)

            // Quick presets + reset
            HStack(spacing: 6) {
                presetButton("Today") {
                    let today = calendar.startOfDay(for: Date())
                    applyRange(today, today)
                }
                presetButton("7 Days") {
                    let today = calendar.startOfDay(for: Date())
                    applyRange(calendar.date(byAdding: .day, value: -6, to: today)!, today)
                }
                presetButton("30 Days") {
                    let today = calendar.startOfDay(for: Date())
                    applyRange(calendar.date(byAdding: .day, value: -29, to: today)!, today)
                }
                presetButton("This Month") {
                    let today = Date()
                    applyRange(
                        calendar.date(from: calendar.dateComponents([.year, .month], from: today))!,
                        calendar.startOfDay(for: today)
                    )
                }

                Spacer()

                if startDate != nil {
                    Button(action: onReset) {
                        Text("Reset")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain).pointerOnHover()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 580)
        .background(WhispererColors.cardBackground(colorScheme))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Calendar Side

    private enum CalendarSide {
        case start, end
    }

    // MARK: - Calendar Grid

    private func calendarGrid(month: Binding<Date>, label: String, labelColor: Color, side: CalendarSide) -> some View {
        VStack(spacing: 0) {
            // Label
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(labelColor)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            // Month navigation
            HStack {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        month.wrappedValue = calendar.date(byAdding: .month, value: -1, to: month.wrappedValue) ?? month.wrappedValue
                    }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(WhispererColors.accentBlue)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(WhispererColors.accentBlue.opacity(0.1)))
                }
                .buttonStyle(.plain).pointerOnHover()

                Spacer()

                Text(monthYearString(for: month.wrappedValue))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        month.wrappedValue = calendar.date(byAdding: .month, value: 1, to: month.wrappedValue) ?? month.wrappedValue
                    }
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(canGoForward(month: month.wrappedValue) ? WhispererColors.accentBlue : WhispererColors.secondaryText(colorScheme))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(canGoForward(month: month.wrappedValue) ? WhispererColors.accentBlue.opacity(0.1) : Color.clear))
                }
                .buttonStyle(.plain).pointerOnHover()
                .disabled(!canGoForward(month: month.wrappedValue))
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Weekday labels
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.3)
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        .frame(height: 20)
                }
            }
            .padding(.horizontal, 10)

            // Day grid
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(daysInMonth(for: month.wrappedValue).enumerated()), id: \.offset) { _, date in
                    if let date = date {
                        dayCell(for: date, side: side)
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Day Cell

    private func dayCell(for date: Date, side: CalendarSide) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isStart = startDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let isEnd = endDate.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        let isInRange = isDateInRange(date)
        let hasTranscription = datesWithTranscriptions.contains(calendar.startOfDay(for: date))
        let isFuture = date > Date()
        let dayNumber = calendar.component(.day, from: date)

        return Button(action: {
            guard !isFuture else { return }
            selectDate(date, side: side)
        }) {
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.system(size: 12, weight: isStart || isEnd ? .bold : .medium))
                    .foregroundColor(
                        isFuture ? .white.opacity(0.2) :
                        (isStart || isEnd) ? .white :
                        .white.opacity(0.85)
                    )

                Circle()
                    .fill(hasTranscription ? WhispererColors.accentBlue : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: 30, height: 34)
            .background(
                Group {
                    if isStart {
                        Circle()
                            .fill(WhispererColors.accentBlue)
                            .frame(width: 30, height: 30)
                    } else if isEnd {
                        Circle()
                            .fill(WhispererColors.accentPurple)
                            .frame(width: 30, height: 30)
                    } else if isInRange {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(WhispererColors.accentBlue.opacity(0.12))
                            .frame(height: 30)
                    } else if isToday {
                        Circle()
                            .stroke(WhispererColors.accentBlue.opacity(0.3), lineWidth: 1.5)
                            .frame(width: 30, height: 30)
                    }
                }
            )
        }
        .buttonStyle(.plain).pointerOnHover()
        .disabled(isFuture)
        .onHover { hovering in
            if !isFuture {
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }

    // MARK: - Preset Button

    private func presetButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.cyan)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.cyan.opacity(0.1)))
                .overlay(Capsule().stroke(Color.cyan.opacity(0.2), lineWidth: 0.5))
        }
        .buttonStyle(.plain).pointerOnHover()
    }

    // MARK: - Helpers

    private func applyRange(_ start: Date, _ end: Date) {
        startDate = start
        endDate = end
        onPresetApply(start, end)
    }

    private func selectDate(_ date: Date, side: CalendarSide) {
        let day = calendar.startOfDay(for: date)

        switch side {
        case .start:
            startDate = day
            // If end is before new start, clear it
            if let end = endDate, end < day {
                endDate = nil
            }
            // Apply with current end or same day
            let effectiveEnd = endDate ?? day
            onApply(day, effectiveEnd)

        case .end:
            endDate = day
            // If start is after new end, clear it
            if let start = startDate, start > day {
                startDate = nil
            }
            // Apply with current start or same day
            let effectiveStart = startDate ?? day
            onApply(effectiveStart, day)
        }
    }

    private func monthYearString(for month: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: month)
    }

    private func canGoForward(month: Date) -> Bool {
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: month) ?? month
        let startOfNextMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: nextMonth))!
        return startOfNextMonth <= Date()
    }

    private func isDateInRange(_ date: Date) -> Bool {
        guard let start = startDate, let end = endDate else { return false }
        let day = calendar.startOfDay(for: date)
        return day >= calendar.startOfDay(for: start) && day <= calendar.startOfDay(for: end)
    }

    private func daysInMonth(for month: Date) -> [Date?] {
        let components = calendar.dateComponents([.year, .month], from: month)
        guard let firstDay = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: firstDay) else { return [] }

        let rawWeekday = calendar.component(.weekday, from: firstDay)
        let firstWeekday = (rawWeekday - calendar.firstWeekday + 7) % 7

        var days: [Date?] = Array(repeating: nil, count: firstWeekday)
        for day in range {
            days.append(calendar.date(byAdding: .day, value: day - 1, to: firstDay))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}

// MARK: - Filter Tab

struct FilterTab: View {
    let title: String
    let isSelected: Bool
    let colorScheme: ColorScheme
    var color: Color = WhispererColors.accent
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(
                    isSelected
                        ? .white
                        : (isHovered ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(isSelected ? color : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : WhispererColors.border(colorScheme), lineWidth: 1)
                )
                .shadow(
                    color: isSelected ? color.opacity(0.25) : Color.clear,
                    radius: 4, y: 1
                )
        }
        .buttonStyle(.plain).pointerOnHover()
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    let colorScheme: ColorScheme
    let onDrag: (CGFloat) -> Void

    @State private var isHovered = false
    @State private var isDragging = false
    @State private var lastTranslation: CGFloat = 0

    private var isActive: Bool { isDragging || isHovered }

    var body: some View {
        ZStack {
            // Background track
            Rectangle()
                .fill(isActive ? WhispererColors.accent.opacity(0.15) : Color.clear)
                .frame(width: 12)

            // Visible line
            Rectangle()
                .fill(isActive ? WhispererColors.accent : WhispererColors.border(colorScheme))
                .frame(width: isDragging ? 3 : (isHovered ? 2 : 1))

            // Grip handle — 3 horizontal bars centered on the divider
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(isActive ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme).opacity(0.4))
                        .frame(width: 8, height: 1.5)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive
                        ? WhispererColors.accent.opacity(colorScheme == .dark ? 0.25 : 0.15)
                        : WhispererColors.elevatedBackground(colorScheme).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? WhispererColors.accent.opacity(0.4) : WhispererColors.border(colorScheme), lineWidth: 0.5)
            )
            .opacity(isActive ? 1 : 0)
            .scaleEffect(isActive ? 1 : 0.8)
        }
        .frame(width: 12)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isDragging = true
                        }
                        lastTranslation = 0
                    }
                    let delta = value.translation.width - lastTranslation
                    lastTranslation = value.translation.width
                    onDrag(delta)
                }
                .onEnded { _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        isDragging = false
                    }
                    lastTranslation = 0
                }
        )
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
