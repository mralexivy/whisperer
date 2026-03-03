//
//  StatisticsView.swift
//  Whisperer
//
//  Usage statistics tab for the workspace window
//

import SwiftUI

// MARK: - Main View

struct StatisticsView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var statsManager = UsageStatisticsManager()

    @State private var activityMetric: ActivityMetric = .words
    @State private var hoveredBarIndex: Int? = nil
    @State private var hoveredHeatmapCell: String? = nil
    @State private var appearedSections: Set<Int> = []

    enum ActivityMetric: String, CaseIterable {
        case words = "Words"
        case time = "Time"
        case sessions = "Sessions"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                statisticsHeader
                    .padding(.bottom, 24)

                periodSelector
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 16) {
                    summaryCardsGrid
                        .sectionFadeIn(index: 0, appeared: $appearedSections)

                    HStack(alignment: .top, spacing: 12) {
                        dailyActivityCard
                        appUsageCard
                    }
                    .sectionFadeIn(index: 1, appeared: $appearedSections)

                    HStack(alignment: .top, spacing: 12) {
                        languagesCard
                        peakHoursCard
                    }
                    .sectionFadeIn(index: 2, appeared: $appearedSections)

                    growthAndStreakColumn
                        .sectionFadeIn(index: 3, appeared: $appearedSections)

                    privacyFooter
                        .sectionFadeIn(index: 4, appeared: $appearedSections)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .task {
            await statsManager.computeStatistics()
        }
        .onChange(of: statsManager.selectedPeriod) { _ in
            // Reset animations on period change
            appearedSections = []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                for i in 0..<5 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.08) {
                        withAnimation(.easeOut(duration: 0.4)) {
                            _ = appearedSections.insert(i)
                        }
                    }
                }
            }
        }
        .onAppear {
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * 0.08) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        _ = appearedSections.insert(i)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var statisticsHeader: some View {
        HStack(spacing: 16) {
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

                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 22))
                    .foregroundColor(WhispererColors.accentBlue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Statistics")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Your transcription usage analytics")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Period Selector

    private var periodSelector: some View {
        HStack(spacing: 6) {
            ForEach(StatsPeriod.allCases, id: \.self) { period in
                FilterTab(
                    title: period.rawValue,
                    isSelected: statsManager.selectedPeriod == period,
                    colorScheme: colorScheme,
                    color: WhispererColors.accentBlue
                ) {
                    withAnimation(.spring(response: 0.3)) {
                        statsManager.selectedPeriod = period
                    }
                    Task {
                        await statsManager.computeStatistics()
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Summary Cards

    private var summaryCardsGrid: some View {
        HStack(spacing: 10) {
            StatsSummaryCard(
                icon: "text.word.spacing",
                label: "WORDS TRANSCRIBED",
                value: statsManager.formattedWords(statsManager.totalWords),
                subLabel: statsManager.comparisonLabel(current: statsManager.totalWords, previous: statsManager.previousPeriodWords),
                color: WhispererColors.accentBlue,
                colorScheme: colorScheme
            )
            StatsSummaryCard(
                icon: "clock",
                label: "AUDIO RECORDED",
                value: statsManager.formattedDuration(statsManager.totalDuration),
                subLabel: statsManager.durationComparisonLabel(current: statsManager.totalDuration, previous: statsManager.previousPeriodDuration),
                color: Color(hex: "22C55E"),
                colorScheme: colorScheme
            )
            StatsSummaryCard(
                icon: "waveform",
                label: "TOTAL SESSIONS",
                value: "\(statsManager.totalSessions)",
                subLabel: statsManager.comparisonLabel(current: statsManager.totalSessions, previous: statsManager.previousPeriodSessions),
                color: Color(hex: "F97316"),
                colorScheme: colorScheme
            )
            StatsSummaryCard(
                icon: "speedometer",
                label: "AVG SPEED",
                value: "\(statsManager.averageWPM) wpm",
                subLabel: statsManager.comparisonLabel(current: statsManager.averageWPM, previous: statsManager.previousPeriodWPM),
                color: Color(hex: "06B6D4"),
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - Daily Activity

    private var dailyActivityCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SettingsSectionHeader(
                        icon: "chart.bar.fill",
                        title: "Daily Activity",
                        colorScheme: colorScheme,
                        color: Color(hex: "F97316")
                    )

                    Spacer()

                    HStack(spacing: 4) {
                        ForEach(ActivityMetric.allCases, id: \.self) { metric in
                            FilterTab(
                                title: metric.rawValue,
                                isSelected: activityMetric == metric,
                                colorScheme: colorScheme,
                                color: WhispererColors.accentBlue
                            ) {
                                withAnimation(.spring(response: 0.3)) {
                                    activityMetric = metric
                                }
                            }
                        }
                    }
                }

                Text("this \(statsManager.selectedPeriod.rawValue.lowercased())")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                barChart
                    .frame(height: 140)

                summaryPills
            }
        }
    }

    private var barChart: some View {
        let data = statsManager.dailyActivity
        let maxValue: Double = {
            switch activityMetric {
            case .words: return Double(data.map(\.wordCount).max() ?? 1)
            case .time: return data.map(\.duration).max() ?? 1
            case .sessions: return Double(data.map(\.sessionCount).max() ?? 1)
            }
        }()

        return GeometryReader { geo in
            HStack(alignment: .bottom, spacing: max(4, (geo.size.width - CGFloat(data.count) * 24) / CGFloat(max(data.count - 1, 1)))) {
                ForEach(Array(data.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 6) {
                        ZStack(alignment: .top) {
                            if hoveredBarIndex == index {
                                barTooltip(for: day)
                                    .offset(y: -30)
                            }

                            RoundedRectangle(cornerRadius: 4)
                                .fill(
                                    hoveredBarIndex == index
                                        ? LinearGradient(colors: [WhispererColors.accentBlue, WhispererColors.accentPurple], startPoint: .bottom, endPoint: .top)
                                        : LinearGradient(colors: [WhispererColors.accentBlue.opacity(0.2), WhispererColors.accentBlue.opacity(0.12)], startPoint: .bottom, endPoint: .top)
                                )
                                .frame(width: 24, height: barHeight(for: day, maxValue: maxValue, containerHeight: geo.size.height - 26))
                                .animation(.spring(response: 0.5, dampingFraction: 0.7), value: activityMetric)
                        }
                        .frame(height: geo.size.height - 20, alignment: .bottom)

                        Text(day.dayLabel)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(
                                hoveredBarIndex == index
                                    ? WhispererColors.primaryText(colorScheme)
                                    : WhispererColors.tertiaryText(colorScheme)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.12)) {
                            hoveredBarIndex = hovering ? index : nil
                        }
                    }
                }
            }
        }
    }

    private func barHeight(for day: DailyActivity, maxValue: Double, containerHeight: CGFloat) -> CGFloat {
        guard maxValue > 0 else { return 4 }
        let value: Double
        switch activityMetric {
        case .words: value = Double(day.wordCount)
        case .time: value = day.duration
        case .sessions: value = Double(day.sessionCount)
        }
        let ratio = value / maxValue
        return max(4, CGFloat(ratio) * containerHeight)
    }

    private func barTooltip(for day: DailyActivity) -> some View {
        let text: String
        switch activityMetric {
        case .words: text = "\(day.wordCount) words"
        case .time: text = statsManager.formattedDuration(day.duration)
        case .sessions: text = "\(day.sessionCount) sessions"
        }

        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(WhispererColors.primaryText(colorScheme))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(WhispererColors.elevatedBackground(colorScheme))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                    )
            )
    }

    private var summaryPills: some View {
        let data = statsManager.dailyActivity
        let peakDay = data.max(by: { $0.wordCount < $1.wordCount })
        let avgWords = data.isEmpty ? 0 : data.reduce(0) { $0 + $1.wordCount } / data.count

        return HStack(spacing: 6) {
            if let peak = peakDay, peak.wordCount > 0 {
                statsPill(
                    icon: "arrow.up",
                    text: "Peak \(peak.dayLabel) · \(statsManager.formattedWords(peak.wordCount)) words",
                    color: WhispererColors.accentBlue
                )
            }
            if avgWords > 0 {
                statsPill(
                    icon: "divide",
                    text: "⌀ \(statsManager.formattedWords(avgWords)) / day",
                    color: Color(hex: "F97316")
                )
            }
            if statsManager.averageWPM > 0 {
                statsPill(
                    icon: "speedometer",
                    text: "\(statsManager.averageWPM) wpm avg",
                    color: WhispererColors.accentPurple
                )
            }
        }
    }

    // MARK: - App Usage

    private var appUsageCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(
                    icon: "square.grid.2x2.fill",
                    title: "Usage by App",
                    colorScheme: colorScheme,
                    color: Color(hex: "6366F1")
                )

                Text("where Whisperer was triggered")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                if statsManager.appUsage.isEmpty {
                    emptyStateLabel("App tracking active — data appears after your next transcription")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(statsManager.appUsage.prefix(6).enumerated()), id: \.element.id) { index, app in
                            AppUsageRow(app: app, colorScheme: colorScheme, colorIndex: index)

                            if index < min(statsManager.appUsage.count, 6) - 1 {
                                Divider()
                                    .background(WhispererColors.border(colorScheme))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Languages

    private var languagesCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(
                    icon: "globe",
                    title: "Languages",
                    colorScheme: colorScheme,
                    color: .red
                )

                Text("detected in audio")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                if statsManager.languageUsage.isEmpty {
                    emptyStateLabel("No transcription data yet")
                } else {
                    // Donut centered
                    HStack {
                        Spacer()
                        DonutChart(
                            segments: statsManager.languageUsage.map { lang in
                                DonutSegment(
                                    label: lang.displayName,
                                    value: lang.percentage,
                                    color: languageColor(for: lang.languageCode)
                                )
                            },
                            centerLabel: statsManager.formattedWords(statsManager.totalWords),
                            colorScheme: colorScheme
                        )
                        .frame(width: 130, height: 130)
                        .shadow(color: WhispererColors.accentBlue.opacity(0.08), radius: 12, y: 2)
                        Spacer()
                    }

                    // Language rows
                    VStack(spacing: 0) {
                        ForEach(Array(statsManager.languageUsage.prefix(5).enumerated()), id: \.element.id) { index, lang in
                            let color = languageColor(for: lang.languageCode)

                            VStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(color)
                                        .frame(width: 4, height: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(lang.displayName)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                                        Text("\(statsManager.formattedWords(lang.wordCount)) words · \(lang.sessionCount) session\(lang.sessionCount == 1 ? "" : "s")")
                                            .font(.system(size: 10))
                                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                                    }

                                    Spacer()

                                    Text("\(Int(lang.percentage))%")
                                        .font(.system(size: 18, weight: .light, design: .rounded))
                                        .foregroundColor(color)
                                        .monospacedDigit()
                                }

                                // Progress bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(color.opacity(0.1))
                                            .frame(height: 3)

                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(color.opacity(0.6))
                                            .frame(width: geo.size.width * CGFloat(lang.percentage / 100.0), height: 3)
                                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: lang.percentage)
                                    }
                                }
                                .frame(height: 3)
                            }
                            .padding(.vertical, 8)

                            if index < min(statsManager.languageUsage.count, 5) - 1 {
                                Divider()
                                    .background(WhispererColors.border(colorScheme))
                            }
                        }
                    }

                    // Summary footer
                    HStack(spacing: 16) {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            Text("\(statsManager.languageUsage.count) language\(statsManager.languageUsage.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "text.word.spacing")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            Text("\(statsManager.formattedWords(statsManager.totalWords)) total")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        }
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Peak Hours Heatmap

    private var peakHoursCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(
                    icon: "clock.badge.checkmark",
                    title: "Peak Hours",
                    colorScheme: colorScheme,
                    color: Color(hex: "22C55E")
                )

                Text("transcription intensity · last \(statsManager.selectedPeriod.days) days")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                if statsManager.peakHours.isEmpty {
                    emptyStateLabel("No transcription data yet")
                } else {
                    heatmapGrid

                    heatmapLegend
                }
            }
        }
    }

    private let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]
    private let hourLabels = ["12a", "2a", "4a", "6a", "8a", "10a", "12p", "2p", "4p", "6p", "8p", "10p"]

    private var heatmapGrid: some View {
        VStack(spacing: 3) {
            // Hour labels
            HStack(spacing: 3) {
                Text("")
                    .frame(width: 16)
                ForEach(hourLabels, id: \.self) { label in
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .frame(maxWidth: .infinity)
                }
            }

            // Grid rows
            ForEach(0..<7, id: \.self) { dayIndex in
                HStack(spacing: 3) {
                    Text(dayLabels[dayIndex])
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .frame(width: 16, alignment: .trailing)

                    ForEach(0..<12, id: \.self) { slot in
                        let weekday = dayIndex + 1  // 1=Sun, 7=Sat
                        let cellId = "\(weekday)-\(slot)"
                        let count = statsManager.peakHours.first(where: { $0.dayOfWeek == weekday && $0.hourSlot == slot })?.count ?? 0
                        let maxCount = statsManager.peakHoursMaxCount

                        RoundedRectangle(cornerRadius: 3)
                            .fill(heatmapCellColor(count: count, max: maxCount))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(
                                        hoveredHeatmapCell == cellId ? WhispererColors.accentBlue.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .onHover { hovering in
                                hoveredHeatmapCell = hovering ? cellId : nil
                            }
                    }
                }
            }
        }
    }

    private func heatmapCellColor(count: Int, max: Int) -> Color {
        guard count > 0, max > 0 else {
            return WhispererColors.border(colorScheme)
        }
        let intensity = min(Double(count) / Double(max), 1.0)
        return WhispererColors.accentBlue.opacity(0.15 + intensity * 0.65)
    }

    private var heatmapLegend: some View {
        HStack(spacing: 0) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                .padding(.trailing, 5)

            ForEach([0.1, 0.3, 0.5, 0.7, 1.0], id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 3)
                    .fill(WhispererColors.accentBlue.opacity(opacity))
                    .frame(width: 12, height: 12)
                    .padding(.horizontal, 1)
            }

            Text("More")
                .font(.system(size: 9))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                .padding(.leading, 5)

            Spacer()

            if let cellId = hoveredHeatmapCell {
                let parts = cellId.split(separator: "-")
                if parts.count == 2,
                   let weekday = Int(parts[0]),
                   let slot = Int(parts[1]),
                   let slotData = statsManager.peakHours.first(where: { $0.dayOfWeek == weekday && $0.hourSlot == slot }),
                   slotData.count > 0 {
                    Text("\(dayLabels[weekday - 1]) · \(slot * 2):00 — ")
                        .font(.system(size: 10))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    +
                    Text("\(slotData.count) sessions")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(WhispererColors.accentBlue)
                }
            }
        }
    }

    // MARK: - Growth & Streak

    private var growthAndStreakColumn: some View {
        HStack(alignment: .top, spacing: 12) {
            growthCard
            streakCard
        }
    }

    private var growthCard: some View {
        SettingsCard(colorScheme: colorScheme, fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "arrow.up.right",
                    title: "Growth",
                    colorScheme: colorScheme,
                    color: Color(hex: "06B6D4")
                )

                Text("word output over time")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                // Growth percentage hero
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(growthColor.opacity(0.1))
                            .frame(width: 56, height: 56)

                        Circle()
                            .stroke(growthColor.opacity(0.2), lineWidth: 1.5)
                            .frame(width: 56, height: 56)

                        Image(systemName: statsManager.growthPercentage >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(growthColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(growthLabel)
                            .font(.system(size: 32, weight: .light, design: .rounded))
                            .foregroundColor(growthColor)
                            .monospacedDigit()

                        Text("vs last \(statsManager.selectedPeriod.rawValue.lowercased())")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }

                    Spacer()
                }

                // Current vs Previous comparison
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Text("CURRENT")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            .tracking(0.8)
                        Text(statsManager.formattedWords(statsManager.totalWords))
                            .font(.system(size: 16, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.accentBlue)
                            .monospacedDigit()
                        Text("words")
                            .font(.system(size: 9))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(WhispererColors.border(colorScheme))
                        .frame(width: 1, height: 36)

                    VStack(spacing: 4) {
                        Text("PREVIOUS")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            .tracking(0.8)
                        Text(statsManager.formattedWords(statsManager.previousPeriodWords))
                            .font(.system(size: 16, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .monospacedDigit()
                        Text("words")
                            .font(.system(size: 9))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.4))
                )

                // Sparkline
                VStack(spacing: 6) {
                    Text("MONTHLY TREND")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .tracking(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    SparklineView(
                        data: statsManager.monthlyTotals.map { Double($0.wordCount) },
                        color: Color(hex: "06B6D4"),
                        colorScheme: colorScheme
                    )
                    .frame(height: 52)

                    HStack {
                        ForEach(statsManager.monthlyTotals) { month in
                            Text(month.label)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    private var growthLabel: String {
        let pct = statsManager.growthPercentage
        if pct == 0 { return "—" }
        return String(format: "%+.0f%%", pct)
    }

    private var growthColor: Color {
        if statsManager.growthPercentage > 0 { return Color(hex: "22C55E") }
        if statsManager.growthPercentage < 0 { return Color(hex: "EF4444") }
        return WhispererColors.secondaryText(colorScheme)
    }

    private var streakCard: some View {
        SettingsCard(colorScheme: colorScheme, borderColor: Color(hex: "F97316").opacity(0.12), fillHeight: true) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "flame.fill",
                    title: "Active Streak",
                    colorScheme: colorScheme,
                    color: Color(hex: "F97316")
                )

                Text("consecutive days")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(.leading, 38)

                // Streak hero
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        ZStack {
                            // Glow rings
                            Circle()
                                .fill(Color(hex: "F97316").opacity(0.05))
                                .frame(width: 96, height: 96)

                            Circle()
                                .stroke(Color(hex: "F97316").opacity(0.1), lineWidth: 1)
                                .frame(width: 96, height: 96)

                            Circle()
                                .fill(Color(hex: "F97316").opacity(0.08))
                                .frame(width: 72, height: 72)

                            Circle()
                                .stroke(Color(hex: "F97316").opacity(0.15), lineWidth: 1.5)
                                .frame(width: 72, height: 72)

                            // Inner circle with number
                            VStack(spacing: 0) {
                                Text("\(statsManager.activeStreak)")
                                    .font(.system(size: 32, weight: .light, design: .rounded))
                                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                                    .monospacedDigit()

                                Text("days")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "F97316"))
                                    .tracking(0.5)
                            }
                        }

                        Text(streakMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)

                // Streak context stats
                HStack(spacing: 0) {
                    VStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(WhispererColors.accentBlue)
                        Text("\(statsManager.totalSessions)")
                            .font(.system(size: 14, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                            .monospacedDigit()
                        Text("sessions")
                            .font(.system(size: 9))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(WhispererColors.border(colorScheme))
                        .frame(width: 1, height: 36)

                    VStack(spacing: 4) {
                        Image(systemName: "text.word.spacing")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "22C55E"))
                        Text(statsManager.formattedWords(statsManager.totalWords))
                            .font(.system(size: 14, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                            .monospacedDigit()
                        Text("words")
                            .font(.system(size: 9))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)

                    Rectangle()
                        .fill(WhispererColors.border(colorScheme))
                        .frame(width: 1, height: 36)

                    VStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "06B6D4"))
                        Text("\(statsManager.averageWPM)")
                            .font(.system(size: 14, weight: .light, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                            .monospacedDigit()
                        Text("wpm")
                            .font(.system(size: 9))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.4))
                )
            }
        }
    }

    private var streakMessage: String {
        let streak = statsManager.activeStreak
        if streak == 0 { return "Start transcribing to begin your streak" }
        if streak == 1 { return "Great start! Keep it going" }
        if streak < 7 { return "Building momentum" }
        if streak < 30 { return "On fire! Impressive consistency" }
        return "Legendary dedication"
    }

    // MARK: - Footer

    private var privacyFooter: some View {
        HStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
                Text("All data stored locally on your Mac")
                    .font(.system(size: 11))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.6))
            }
            Spacer()
        }
        .padding(.top, 16)
    }

    // MARK: - Helpers

    private func statsPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }

    private func emptyStateLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            .frame(maxWidth: .infinity, minHeight: 60)
    }

    private func languageColor(for code: String) -> Color {
        let colors: [Color] = [
            WhispererColors.accentBlue,
            WhispererColors.accentPurple,
            Color(hex: "F97316"),
            Color(hex: "22C55E"),
            Color(hex: "06B6D4"),
            Color(hex: "EF4444"),
        ]
        // Deterministic color based on language code hash
        let hash = abs(code.hashValue)
        return colors[hash % colors.count]
    }

    static let appIconColors: [Color] = [
        Color(red: 0.357, green: 0.424, blue: 0.969), // accentBlue
        Color(hex: "6366F1"),  // indigo
        Color(hex: "06B6D4"),  // cyan
        Color(hex: "F97316"),  // orange
        Color(hex: "22C55E"),  // green
        Color.white.opacity(0.25),
    ]

    static let appIcons: [String: String] = [
        "Notion": "doc.text",
        "Slack": "message",
        "VS Code": "chevron.left.forwardslash.chevron.right",
        "Visual Studio Code": "chevron.left.forwardslash.chevron.right",
        "Mail": "envelope",
        "Notes": "note.text",
        "TextEdit": "doc.plaintext",
        "Safari": "safari",
        "Chrome": "globe",
        "Google Chrome": "globe",
        "Firefox": "globe",
        "Terminal": "terminal",
        "Messages": "message",
        "Pages": "doc.richtext",
        "Xcode": "hammer",
        "Unknown": "ellipsis",
    ]
}

// MARK: - Section Fade-In Modifier

private struct SectionFadeIn: ViewModifier {
    let index: Int
    @Binding var appeared: Set<Int>

    func body(content: Content) -> some View {
        content
            .opacity(appeared.contains(index) ? 1 : 0)
            .offset(y: appeared.contains(index) ? 0 : 12)
    }
}

extension View {
    func sectionFadeIn(index: Int, appeared: Binding<Set<Int>>) -> some View {
        modifier(SectionFadeIn(index: index, appeared: appeared))
    }
}

// MARK: - Stats Summary Card

private struct StatsSummaryCard: View {
    let icon: String
    let label: String
    let value: String
    let subLabel: String
    let color: Color
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.9)

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color)
                }
            }
            .padding(.bottom, 14)

            Text(value)
                .font(.system(size: 32, weight: .light, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: value)

            Text(subLabel.isEmpty ? " " : subLabel)
                .font(.system(size: 11))
                .foregroundColor(subLabel.isEmpty ? .clear : WhispererColors.tertiaryText(colorScheme))
                .padding(.top, 5)

            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: isHovered ? 60 : 40)
                .padding(.top, 14)
                .animation(.spring(response: 0.3), value: isHovered)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 6 : 4,
            y: isHovered ? 2 : 1
        )
        .overlay(
            // Subtle glow in top-right corner
            Circle()
                .fill(color.opacity(0.06))
                .frame(width: 88, height: 88)
                .blur(radius: 24)
                .offset(x: 30, y: -30),
            alignment: .topTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - App Usage Row

private struct AppUsageRow: View {
    let app: AppUsage
    let colorScheme: ColorScheme
    let colorIndex: Int

    @State private var animatedWidth: Double = 0

    private var color: Color {
        StatisticsView.appIconColors[min(colorIndex, StatisticsView.appIconColors.count - 1)]
    }

    private var iconName: String {
        StatisticsView.appIcons[app.appName] ?? "app"
    }

    var body: some View {
        HStack(spacing: 10) {
            // App icon
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(color.opacity(0.15))
                    .frame(width: 28, height: 28)

                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.appName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))

                    Spacer()

                    Text("\(Int(app.percentage))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .monospacedDigit()
                }

                // Progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(WhispererColors.border(colorScheme))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [color, color.opacity(0.4)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * animatedWidth / 100, height: 3)
                    }
                }
                .frame(height: 3)
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text(formatWords(app.wordCount))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .monospacedDigit()

                Text("\(app.sessionCount) sessions")
                    .font(.system(size: 9))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            }
            .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.7).delay(Double(colorIndex) * 0.07)) {
                animatedWidth = app.percentage
            }
        }
        .onChange(of: app.percentage) { newValue in
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                animatedWidth = newValue
            }
        }
    }

    private func formatWords(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }
}

// MARK: - Donut Chart

struct DonutSegment {
    let label: String
    let value: Double
    let color: Color
}

private struct DonutChart: View {
    let segments: [DonutSegment]
    let centerLabel: String
    let colorScheme: ColorScheme

    private let ringWidth: CGFloat = 18
    private let gapDegrees: Double = 3

    var body: some View {
        ZStack {
            // Track ring
            Circle()
                .stroke(Color.white.opacity(0.04), lineWidth: ringWidth)

            // Segments
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                DonutArc(
                    startAngle: startAngle(for: index),
                    endAngle: endAngle(for: index),
                    lineWidth: ringWidth
                )
                .stroke(segment.color.opacity(0.85), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            }

            // Center content
            VStack(spacing: 2) {
                Text("words")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.5)
                Text(centerLabel)
                    .font(.system(size: 16, weight: .light, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .monospacedDigit()
            }
        }
        .padding(ringWidth / 2)
    }

    private func startAngle(for index: Int) -> Angle {
        let total = segments.reduce(0) { $0 + $1.value }
        guard total > 0 else { return .degrees(-90) }
        let precedingSum = segments.prefix(index).reduce(0) { $0 + $1.value }
        let gap = segments.count > 1 ? gapDegrees : 0
        return .degrees((precedingSum / total) * 360 - 90 + gap / 2)
    }

    private func endAngle(for index: Int) -> Angle {
        let total = segments.reduce(0) { $0 + $1.value }
        guard total > 0 else { return .degrees(-90) }
        let sum = segments.prefix(index + 1).reduce(0) { $0 + $1.value }
        let gap = segments.count > 1 ? gapDegrees : 0
        return .degrees((sum / total) * 360 - 90 - gap / 2)
    }
}

private struct DonutArc: Shape {
    let startAngle: Angle
    let endAngle: Angle
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - lineWidth) / 2
        path.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        return path
    }
}

// MARK: - Sparkline

private struct SparklineView: View {
    let data: [Double]
    let color: Color
    let colorScheme: ColorScheme

    var body: some View {
        GeometryReader { geo in
            let maxVal = data.max() ?? 1
            let minVal = 0.0
            let range = max(maxVal - minVal, 1)
            let points: [CGPoint] = data.enumerated().map { index, value in
                let x = data.count > 1 ? CGFloat(index) / CGFloat(data.count - 1) * geo.size.width : geo.size.width / 2
                let y = geo.size.height - ((CGFloat(value - minVal) / CGFloat(range)) * (geo.size.height - 6) + 3)
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Fill area
                Path { path in
                    guard !points.isEmpty else { return }
                    path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                    for pt in points {
                        path.addLine(to: pt)
                    }
                    path.addLine(to: CGPoint(x: points.last!.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.2), color.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Line
                Path { path in
                    guard !points.isEmpty else { return }
                    path.move(to: points[0])
                    for pt in points.dropFirst() {
                        path.addLine(to: pt)
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                // End dot
                if let last = points.last {
                    Circle()
                        .fill(color)
                        .frame(width: 6, height: 6)
                        .position(last)
                }
            }
        }
    }
}
