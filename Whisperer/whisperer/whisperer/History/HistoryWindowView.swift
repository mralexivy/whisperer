//
//  HistoryWindowView.swift
//  Whisperer
//
//  Main SwiftUI view for history window with sidebar navigation
//

import SwiftUI

// MARK: - Design System Colors

struct WhispererColors {
    // Primary brand green
    static let accent = Color(hex: "22C55E")
    static let accentDark = Color(hex: "16A34A")

    // Backgrounds (adapt to color scheme)
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "0D0D0D") : Color(hex: "F8FAFC")
    }

    static func cardBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "1A1A1A") : Color.white
    }

    static func sidebarBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "141414") : Color(hex: "FFFFFF")
    }

    static func elevatedBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "262626") : Color(hex: "F1F5F9")
    }

    // Text
    static func primaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white : Color(hex: "0F172A")
    }

    static func secondaryText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "9CA3AF") : Color(hex: "64748B")
    }

    // Borders
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
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
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcriptions: return "waveform.and.mic"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Main View

struct HistoryWindowView: View {
    @Environment(\.colorScheme) var colorScheme
    @State private var selectedSidebarItem: HistorySidebarItem = .transcriptions

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            sidebarView

            // Divider
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(width: 1)

            // Main content
            Group {
                switch selectedSidebarItem {
                case .transcriptions:
                    TranscriptionsView()
                case .settings:
                    HistorySettingsView()
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .background(WhispererColors.background(colorScheme))
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

            // Keyboard shortcut hint at bottom
            shortcutHint
        }
        .frame(width: 220)
        .background(WhispererColors.sidebarBackground(colorScheme))
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(WhispererColors.accent)
                    .frame(width: 36, height: 36)

                Image(systemName: "waveform")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Whisperer")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("History")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
        .padding(16)
        .background(WhispererColors.sidebarBackground(colorScheme))
        .overlay(
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var shortcutHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "keyboard")
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text("Fn + S")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))

            Text("to toggle")
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.7))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(WhispererColors.elevatedBackground(colorScheme).opacity(0.5))
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
                    .foregroundColor(isSelected ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme))
                    .frame(width: 20)

                Text(item.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? WhispererColors.primaryText(colorScheme) : WhispererColors.secondaryText(colorScheme))

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? WhispererColors.accent.opacity(0.15) : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? WhispererColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
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
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Welcome
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(WhispererColors.accent)
                        .frame(width: 44, height: 44)

                    Text(initials)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome back")
                        .font(.system(size: 12))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))

                    Text(firstName)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                }

                Spacer()
            }

            // Stats
            if let stats = historyManager.statistics {
                HStack(spacing: 20) {
                    CompactStatItem(value: "\(stats.totalRecordings)", label: "Recordings", icon: "waveform", colorScheme: colorScheme)
                    CompactStatItem(value: formatNumber(stats.totalWords), label: "Words", icon: "text.alignleft", colorScheme: colorScheme)
                    CompactStatItem(value: "\(stats.averageWPM)", label: "Avg WPM", icon: "speedometer", colorScheme: colorScheme)
                    CompactStatItem(value: "\(stats.totalDays)", label: "Days", icon: "calendar", colorScheme: colorScheme)
                }
            }
        }
        .padding(20)
        .background(WhispererColors.cardBackground(colorScheme))
        .overlay(
            Rectangle()
                .fill(WhispererColors.border(colorScheme))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Toolbar

    private var toolbarView: some View {
        HStack(spacing: 14) {
            // Search
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

            Spacer()

            // Filters
            HStack(spacing: 4) {
                FilterChip(title: "All", isSelected: selectedFilter == .all, colorScheme: colorScheme) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .all }
                    performSearch()
                }
                FilterChip(title: "Pinned", icon: "pin.fill", isSelected: selectedFilter == .pinned, colorScheme: colorScheme) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .pinned }
                    performSearch()
                }
                FilterChip(title: "Flagged", icon: "flag.fill", isSelected: selectedFilter == .flagged, colorScheme: colorScheme) {
                    withAnimation(.spring(response: 0.3)) { selectedFilter = .flagged }
                    performSearch()
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(WhispererColors.elevatedBackground(colorScheme))
            )
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
                                VStack(spacing: 6) {
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
                                .padding(.bottom, 14)
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
                    .fill(WhispererColors.accent.opacity(0.12))
                    .frame(width: 72, height: 72)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 28))
                    .foregroundColor(WhispererColors.accent)
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
                .fill(WhispererColors.border(colorScheme))
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

    private func formatNumber(_ number: Int) -> String {
        if number >= 1000 {
            return String(format: "%.1fK", Double(number) / 1000)
        }
        return "\(number)"
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
                    .fill(WhispererColors.accent.opacity(0.12))
                    .frame(width: 52, height: 52)

                Image(systemName: "gearshape.fill")
                    .font(.system(size: 22))
                    .foregroundColor(WhispererColors.accent)
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
                    colorScheme: colorScheme
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

    // MARK: - Storage Section

    private var storageSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "externaldrive.fill",
                    title: "Storage",
                    colorScheme: colorScheme
                )

                SettingsRow(colorScheme: colorScheme) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(WhispererColors.accent.opacity(0.12))
                                .frame(width: 36, height: 36)

                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.accent)
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
                    colorScheme: colorScheme
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

            SettingsCard(colorScheme: colorScheme, borderColor: .red.opacity(0.3)) {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.red.opacity(0.12))
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

                    Button(action: { showDeleteConfirmation = true }) {
                        Text("Delete All")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.red)
                            )
                    }
                    .buttonStyle(.plain)
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

    var body: some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(WhispererColors.cardBackground(colorScheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor ?? WhispererColors.border(colorScheme), lineWidth: 1)
            )
    }
}

struct SettingsSectionHeader: View {
    let icon: String
    let title: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(WhispererColors.accent)

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
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
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
                    .stroke(isSelected ? WhispererColors.accent : WhispererColors.border(colorScheme), lineWidth: isSelected ? 0 : 1)
            )
            .shadow(color: isSelected ? WhispererColors.accent.opacity(0.3) : .clear, radius: 8, x: 0, y: 4)
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
                .foregroundColor(isSelected ? .white : WhispererColors.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? WhispererColors.accent : (isHovered ? WhispererColors.elevatedBackground(colorScheme) : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.clear : WhispererColors.border(colorScheme), lineWidth: 1)
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

// MARK: - Compact Stat Item

struct CompactStatItem: View {
    let value: String
    let label: String
    let icon: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(WhispererColors.accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(WhispererColors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    var icon: String? = nil
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : WhispererColors.primaryText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? WhispererColors.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Resizable Divider

struct ResizableDivider: View {
    let colorScheme: ColorScheme
    let onDrag: (CGFloat) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(isDragging || isHovered ? WhispererColors.accent : WhispererColors.border(colorScheme))
            .frame(width: isDragging || isHovered ? 4 : 1)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
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
                            isDragging = true
                        }
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
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
