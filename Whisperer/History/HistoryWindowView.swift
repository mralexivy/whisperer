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
    case dictionary = "Dictionary"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcriptions: return "waveform.and.mic"
        case .dictionary: return "book.closed"
        case .settings: return "gearshape"
        }
    }

    var color: Color {
        switch self {
        case .transcriptions: return WhispererColors.accentBlue
        case .dictionary: return .purple
        case .settings: return .orange
        }
    }
}

// MARK: - Main View

struct HistoryWindowView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject private var historyManager = HistoryManager.shared
    @State private var selectedSidebarItem: HistorySidebarItem = .transcriptions
    @State private var isSidebarCollapsed = false

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
                case .dictionary:
                    DictionaryView()
                case .settings:
                    HistorySettingsView()
                }
            }
        }
        .frame(minWidth: isSidebarCollapsed ? 700 : 1100, minHeight: 700)
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
                ForEach(HistorySidebarItem.allCases) { item in
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

            // Keyboard shortcut hint at bottom
            shortcutHint
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
            sidebarStatRow(label: "WORDS", value: formatSidebarNumber(stats.totalWords), valueColor: .purple)
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

    private var shortcutHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))

            HStack(spacing: 3) {
                Text("Fn")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(WhispererColors.pillBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 0.5)
                    )

                Text("+")
                    .font(.system(size: 10))

                Text("S")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(WhispererColors.pillBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 0.5)
                    )
            }
            .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text("to toggle")
                .font(.system(size: 10))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.5))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(WhispererColors.elevatedBackground(colorScheme).opacity(0.4))
        .overlay(
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(height: 1),
            alignment: .top
        )
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
        .buttonStyle(.plain)
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
            HStack(spacing: 14) {
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

                    Text("Welcome back")
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }

                Spacer()
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
                    .buttonStyle(.plain)
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

                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - List

    private var transcriptionList: some View {
        Group {
            if historyManager.transcriptions.isEmpty {
                emptyStateView
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
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
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
        Task {
            await historyManager.loadTranscriptions(
                filter: selectedFilter,
                searchQuery: searchText.isEmpty ? nil : searchText
            )
        }
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
                    color: .purple
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
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
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
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
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
        .buttonStyle(.plain)
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
