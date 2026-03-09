//
//  UsageStatisticsManager.swift
//  Whisperer
//
//  Computes aggregated usage statistics from transcription history
//

import Foundation
import CoreData
import Combine

// MARK: - Period Selection

enum StatsPeriod: String, CaseIterable {
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var days: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .year: return 365
        }
    }

    var startDate: Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }

    var previousPeriodStartDate: Date {
        Calendar.current.date(byAdding: .day, value: -(days * 2), to: Date()) ?? Date()
    }
}

// MARK: - Data Models

struct DailyActivity: Identifiable {
    let id = UUID()
    let date: Date
    let wordCount: Int
    let duration: TimeInterval
    let sessionCount: Int

    var dayLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    var shortDateLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

struct AppUsage: Identifiable {
    let id = UUID()
    let appName: String
    let wordCount: Int
    let sessionCount: Int
    var percentage: Double
}

struct HourSlot: Identifiable {
    let id: String
    let dayOfWeek: Int   // 1=Sun...7=Sat
    let hourSlot: Int    // 0-11 (2-hour blocks: 0=00:00, 1=02:00, ...)
    let count: Int
}

struct LanguageUsage: Identifiable {
    let id = UUID()
    let languageCode: String
    let displayName: String
    let wordCount: Int
    let sessionCount: Int
    var percentage: Double
}

struct MonthlyTotal: Identifiable {
    let id = UUID()
    let label: String
    let wordCount: Int
}

// MARK: - Milestones

enum MilestoneCategory: String {
    case words = "Words"
    case sessions = "Sessions"
    case streak = "Streak"
}

struct Milestone: Identifiable, Equatable {
    let id = UUID()
    let category: MilestoneCategory
    let threshold: Int
    let label: String
    let icon: String
    var achieved: Bool
    var achievedDate: Date?

    static func == (lhs: Milestone, rhs: Milestone) -> Bool {
        lhs.category == rhs.category && lhs.threshold == rhs.threshold
    }

    static let all: [Milestone] = [
        // Words
        Milestone(category: .words, threshold: 1_000, label: "1K Words", icon: "text.word.spacing", achieved: false),
        Milestone(category: .words, threshold: 5_000, label: "5K Words", icon: "text.word.spacing", achieved: false),
        Milestone(category: .words, threshold: 10_000, label: "10K Words", icon: "text.word.spacing", achieved: false),
        Milestone(category: .words, threshold: 50_000, label: "50K Words", icon: "text.word.spacing", achieved: false),
        Milestone(category: .words, threshold: 100_000, label: "100K Words", icon: "text.word.spacing", achieved: false),
        Milestone(category: .words, threshold: 500_000, label: "500K Words", icon: "text.word.spacing", achieved: false),
        // Sessions
        Milestone(category: .sessions, threshold: 50, label: "50 Sessions", icon: "mic.fill", achieved: false),
        Milestone(category: .sessions, threshold: 100, label: "100 Sessions", icon: "mic.fill", achieved: false),
        Milestone(category: .sessions, threshold: 500, label: "500 Sessions", icon: "mic.fill", achieved: false),
        Milestone(category: .sessions, threshold: 1_000, label: "1K Sessions", icon: "mic.fill", achieved: false),
        Milestone(category: .sessions, threshold: 5_000, label: "5K Sessions", icon: "mic.fill", achieved: false),
        // Streak
        Milestone(category: .streak, threshold: 7, label: "7-Day Streak", icon: "flame.fill", achieved: false),
        Milestone(category: .streak, threshold: 14, label: "14-Day Streak", icon: "flame.fill", achieved: false),
        Milestone(category: .streak, threshold: 30, label: "30-Day Streak", icon: "flame.fill", achieved: false),
        Milestone(category: .streak, threshold: 60, label: "60-Day Streak", icon: "flame.fill", achieved: false),
        Milestone(category: .streak, threshold: 100, label: "100-Day Streak", icon: "flame.fill", achieved: false),
        Milestone(category: .streak, threshold: 365, label: "365-Day Streak", icon: "flame.fill", achieved: false),
    ]
}

// MARK: - Personal Records

struct PersonalRecords: Equatable {
    var longestTranscriptionWords: Int = 0
    var longestTranscriptionDate: Date?
    var mostWordsInDay: Int = 0
    var mostWordsInDayDate: Date?
    var mostSessionsInDay: Int = 0
    var mostSessionsInDayDate: Date?
}

// MARK: - Manager

@MainActor
class UsageStatisticsManager: ObservableObject {
    // Summary
    @Published var totalWords: Int = 0
    @Published var totalDuration: TimeInterval = 0
    @Published var totalSessions: Int = 0
    @Published var averageWPM: Int = 0

    // Sections
    @Published var dailyActivity: [DailyActivity] = []
    @Published var appUsage: [AppUsage] = []
    @Published var peakHours: [HourSlot] = []
    @Published var languageUsage: [LanguageUsage] = []
    @Published var monthlyTotals: [MonthlyTotal] = []
    @Published var growthPercentage: Double = 0
    @Published var activeStreak: Int = 0
    @Published var bestStreak: Int = 0

    // Time saved
    @Published var timeSavedMinutes: Double = 0
    @Published var userTypingWPM: Int = 40 {
        didSet {
            UserDefaults.standard.set(userTypingWPM, forKey: "userTypingWPM")
        }
    }

    // Milestones
    @Published var achievedMilestones: [Milestone] = []
    @Published var nextMilestone: Milestone?
    @Published var milestoneProgress: Double = 0

    // Personal records
    @Published var personalRecords: PersonalRecords = PersonalRecords()

    // Previous period for comparison
    @Published var previousPeriodWords: Int = 0
    @Published var previousPeriodDuration: TimeInterval = 0
    @Published var previousPeriodSessions: Int = 0
    @Published var previousPeriodWPM: Int = 0

    // State
    @Published var selectedPeriod: StatsPeriod = .week
    @Published var isLoading: Bool = false

    private let database = HistoryDatabase.shared
    private var transcriptionObserver: Any?

    init() {
        if UserDefaults.standard.object(forKey: "userTypingWPM") != nil {
            userTypingWPM = UserDefaults.standard.integer(forKey: "userTypingWPM")
        }
        if UserDefaults.standard.object(forKey: "bestStreak") != nil {
            bestStreak = UserDefaults.standard.integer(forKey: "bestStreak")
        }

        transcriptionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("TranscriptionSaved"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.computeStatistics()
            }
        }
    }

    deinit {
        if let observer = transcriptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Main Computation

    func computeStatistics() async {
        isLoading = true

        let period = selectedPeriod
        let context = database.viewContext

        // Fetch entities for current period
        let currentEntities = fetchEntities(in: context, from: period.startDate, to: Date())
        // Fetch entities for previous period (for comparison)
        let previousEntities = fetchEntities(in: context, from: period.previousPeriodStartDate, to: period.startDate)
        // Fetch all entities (for streak and monthly totals)
        let allEntities = fetchEntities(in: context, from: nil, to: nil)

        computeSummary(current: currentEntities, previous: previousEntities)
        computeDailyActivity(entities: currentEntities, period: period)
        computeAppUsage(entities: currentEntities)
        computePeakHours(entities: currentEntities)
        computeLanguages(entities: currentEntities)
        computeGrowth(current: currentEntities, previous: previousEntities)
        computeStreak(allEntities: allEntities)
        computeMonthlyTotals(allEntities: allEntities)
        computeTimeSaved(allEntities: allEntities)
        computeMilestones(allEntities: allEntities)
        computePersonalRecords(allEntities: allEntities)

        isLoading = false
    }

    // MARK: - Fetch

    private func fetchEntities(in context: NSManagedObjectContext, from startDate: Date?, to endDate: Date?) -> [TranscriptionEntity] {
        let request: NSFetchRequest<TranscriptionEntity> = TranscriptionEntity.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        var predicates: [NSPredicate] = []
        if let start = startDate {
            predicates.append(NSPredicate(format: "timestamp >= %@", start as NSDate))
        }
        if let end = endDate {
            predicates.append(NSPredicate(format: "timestamp <= %@", end as NSDate))
        }
        if !predicates.isEmpty {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        do {
            return try context.fetch(request)
        } catch {
            Logger.error("Failed to fetch transcription entities for statistics: \(error)", subsystem: .app)
            return []
        }
    }

    // MARK: - Summary

    private func computeSummary(current: [TranscriptionEntity], previous: [TranscriptionEntity]) {
        totalSessions = current.count
        totalWords = current.reduce(0) { $0 + Int($1.wordCount) }
        totalDuration = current.reduce(0.0) { $0 + $1.duration }
        averageWPM = totalDuration > 0 ? Int(Double(totalWords) / (totalDuration / 60.0)) : 0

        previousPeriodWords = previous.reduce(0) { $0 + Int($1.wordCount) }
        previousPeriodSessions = previous.count
        let prevDuration = previous.reduce(0.0) { $0 + $1.duration }
        previousPeriodDuration = prevDuration
        previousPeriodWPM = prevDuration > 0 ? Int(Double(previousPeriodWords) / (prevDuration / 60.0)) : 0
    }

    // MARK: - Daily Activity

    private func computeDailyActivity(entities: [TranscriptionEntity], period: StatsPeriod) {
        let calendar = Calendar.current

        // Group by day
        var dayMap: [Date: (words: Int, duration: TimeInterval, sessions: Int)] = [:]
        for entity in entities {
            let day = calendar.startOfDay(for: entity.timestamp)
            var entry = dayMap[day] ?? (0, 0, 0)
            entry.words += Int(entity.wordCount)
            entry.duration += entity.duration
            entry.sessions += 1
            dayMap[day] = entry
        }

        // Fill in all days in the period
        var dailyActivities: [DailyActivity] = []
        let today = calendar.startOfDay(for: Date())
        for offset in stride(from: -(period.days - 1), through: 0, by: 1) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let entry = dayMap[day]
            dailyActivities.append(DailyActivity(
                date: day,
                wordCount: entry?.words ?? 0,
                duration: entry?.duration ?? 0,
                sessionCount: entry?.sessions ?? 0
            ))
        }

        // Year view: group by week to avoid 365 tiny bars
        if period == .year {
            var weeklyActivities: [DailyActivity] = []
            var weekStart = 0
            while weekStart < dailyActivities.count {
                let weekEnd = min(weekStart + 7, dailyActivities.count)
                let chunk = dailyActivities[weekStart..<weekEnd]
                let totalWords = chunk.reduce(0) { $0 + $1.wordCount }
                let totalDuration = chunk.reduce(0.0) { $0 + $1.duration }
                let totalSessions = chunk.reduce(0) { $0 + $1.sessionCount }
                // Use the first day of the week as the representative date
                weeklyActivities.append(DailyActivity(
                    date: chunk.first!.date,
                    wordCount: totalWords,
                    duration: totalDuration,
                    sessionCount: totalSessions
                ))
                weekStart = weekEnd
            }
            dailyActivity = weeklyActivities
        } else {
            dailyActivity = dailyActivities
        }
    }

    // MARK: - App Usage

    private func computeAppUsage(entities: [TranscriptionEntity]) {
        var appMap: [String: (words: Int, sessions: Int)] = [:]

        for entity in entities {
            let name = entity.targetAppName ?? "Unknown"
            var entry = appMap[name] ?? (0, 0)
            entry.words += Int(entity.wordCount)
            entry.sessions += 1
            appMap[name] = entry
        }

        let totalWords = max(entities.reduce(0) { $0 + Int($1.wordCount) }, 1)

        appUsage = appMap.map { key, value in
            AppUsage(
                appName: key,
                wordCount: value.words,
                sessionCount: value.sessions,
                percentage: Double(value.words) / Double(totalWords) * 100
            )
        }
        .sorted { $0.wordCount > $1.wordCount }
    }

    // MARK: - Peak Hours

    private func computePeakHours(entities: [TranscriptionEntity]) {
        let calendar = Calendar.current
        var slotMap: [String: Int] = [:]

        for entity in entities {
            let weekday = calendar.component(.weekday, from: entity.timestamp)
            let hour = calendar.component(.hour, from: entity.timestamp)
            let slot = hour / 2  // 2-hour blocks
            let key = "\(weekday)-\(slot)"
            slotMap[key, default: 0] += 1
        }

        var slots: [HourSlot] = []
        for weekday in 1...7 {
            for slot in 0..<12 {
                let key = "\(weekday)-\(slot)"
                slots.append(HourSlot(
                    id: key,
                    dayOfWeek: weekday,
                    hourSlot: slot,
                    count: slotMap[key] ?? 0
                ))
            }
        }

        peakHours = slots
    }

    var peakHoursMaxCount: Int {
        peakHours.map(\.count).max() ?? 1
    }

    // MARK: - Languages

    private func computeLanguages(entities: [TranscriptionEntity]) {
        var langMap: [String: (words: Int, sessions: Int)] = [:]

        for entity in entities {
            let code = entity.language.isEmpty ? "auto" : entity.language
            var entry = langMap[code] ?? (0, 0)
            entry.words += Int(entity.wordCount)
            entry.sessions += 1
            langMap[code] = entry
        }

        let totalWords = max(entities.reduce(0) { $0 + Int($1.wordCount) }, 1)

        languageUsage = langMap.map { code, value in
            let displayName: String
            if code == "auto" {
                displayName = "Auto-detect"
            } else {
                displayName = Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
            }
            return LanguageUsage(
                languageCode: code,
                displayName: displayName,
                wordCount: value.words,
                sessionCount: value.sessions,
                percentage: Double(value.words) / Double(totalWords) * 100
            )
        }
        .sorted { $0.wordCount > $1.wordCount }
    }

    // MARK: - Growth

    private func computeGrowth(current: [TranscriptionEntity], previous: [TranscriptionEntity]) {
        let currentWords = current.reduce(0) { $0 + Int($1.wordCount) }
        let previousWords = previous.reduce(0) { $0 + Int($1.wordCount) }

        if previousWords > 0 {
            growthPercentage = Double(currentWords - previousWords) / Double(previousWords) * 100
        } else {
            growthPercentage = currentWords > 0 ? 100 : 0
        }
    }

    // MARK: - Streak

    private func computeStreak(allEntities: [TranscriptionEntity]) {
        let calendar = Calendar.current
        let transcriptionDays = Set(allEntities.map { calendar.startOfDay(for: $0.timestamp) })

        // Compute active streak (from today/yesterday backwards)
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        // If no transcription today, start counting from yesterday
        if !transcriptionDays.contains(checkDate) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                activeStreak = 0
                return
            }
            checkDate = yesterday
        }

        while transcriptionDays.contains(checkDate) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
            checkDate = prev
        }

        activeStreak = streak

        // Compute best-ever streak by scanning all days chronologically
        let sortedDays = transcriptionDays.sorted()
        var currentRun = 0
        var longestRun = 0
        var previousDay: Date?

        for day in sortedDays {
            if let prev = previousDay,
               let nextExpected = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(day, inSameDayAs: nextExpected) {
                currentRun += 1
            } else {
                currentRun = 1
            }
            longestRun = max(longestRun, currentRun)
            previousDay = day
        }

        // Persist best streak (only update if we beat the record)
        if longestRun > bestStreak {
            bestStreak = longestRun
            UserDefaults.standard.set(bestStreak, forKey: "bestStreak")
        }
    }

    // MARK: - Monthly Totals (Sparkline)

    private func computeMonthlyTotals(allEntities: [TranscriptionEntity]) {
        let calendar = Calendar.current
        let now = Date()

        var totals: [MonthlyTotal] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM"

        for offset in stride(from: -6, through: 0, by: 1) {
            guard let monthStart = calendar.date(byAdding: .month, value: offset, to: now) else { continue }
            let components = calendar.dateComponents([.year, .month], from: monthStart)
            guard let rangeStart = calendar.date(from: components),
                  let rangeEnd = calendar.date(byAdding: .month, value: 1, to: rangeStart) else { continue }

            let monthWords = allEntities
                .filter { $0.timestamp >= rangeStart && $0.timestamp < rangeEnd }
                .reduce(0) { $0 + Int($1.wordCount) }

            totals.append(MonthlyTotal(
                label: formatter.string(from: rangeStart),
                wordCount: monthWords
            ))
        }

        monthlyTotals = totals
    }

    // MARK: - Time Saved

    private func computeTimeSaved(allEntities: [TranscriptionEntity]) {
        let allWords = allEntities.reduce(0) { $0 + Int($1.wordCount) }
        let typingWPM = max(userTypingWPM, 1)
        let speakingWPM = 150.0

        // Time it would take to type vs time spent speaking
        let typingMinutes = Double(allWords) / Double(typingWPM)
        let speakingMinutes = Double(allWords) / speakingWPM
        timeSavedMinutes = max(0, typingMinutes - speakingMinutes)
    }

    var formattedTimeSaved: String {
        if timeSavedMinutes < 1 {
            return "< 1 min"
        } else if timeSavedMinutes < 60 {
            return "\(Int(timeSavedMinutes)) min"
        } else {
            let hours = Int(timeSavedMinutes) / 60
            let mins = Int(timeSavedMinutes) % 60
            return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
        }
    }

    // MARK: - Milestones

    private func computeMilestones(allEntities: [TranscriptionEntity]) {
        let totalWordsAll = allEntities.reduce(0) { $0 + Int($1.wordCount) }
        let totalSessionsAll = allEntities.count

        var milestones = Milestone.all
        for i in milestones.indices {
            switch milestones[i].category {
            case .words:
                milestones[i].achieved = totalWordsAll >= milestones[i].threshold
            case .sessions:
                milestones[i].achieved = totalSessionsAll >= milestones[i].threshold
            case .streak:
                milestones[i].achieved = bestStreak >= milestones[i].threshold
            }
        }

        achievedMilestones = milestones.filter { $0.achieved }

        // Find next unachieved milestone (first unachieved in each category, pick closest)
        let nextByCategory: [Milestone] = [MilestoneCategory.words, .sessions, .streak].compactMap { cat in
            milestones.first { $0.category == cat && !$0.achieved }
        }

        if let next = nextByCategory.min(by: { progressFor($0, words: totalWordsAll, sessions: totalSessionsAll) > progressFor($1, words: totalWordsAll, sessions: totalSessionsAll) }) {
            nextMilestone = next
            milestoneProgress = progressFor(next, words: totalWordsAll, sessions: totalSessionsAll)
        } else {
            nextMilestone = nil
            milestoneProgress = 1.0
        }
    }

    private func progressFor(_ milestone: Milestone, words: Int, sessions: Int) -> Double {
        let current: Int
        switch milestone.category {
        case .words: current = words
        case .sessions: current = sessions
        case .streak: current = bestStreak
        }
        return min(1.0, Double(current) / Double(max(milestone.threshold, 1)))
    }

    // MARK: - Personal Records

    private func computePersonalRecords(allEntities: [TranscriptionEntity]) {
        let calendar = Calendar.current
        var records = PersonalRecords()

        // Longest single transcription
        if let longest = allEntities.max(by: { Int($0.wordCount) < Int($1.wordCount) }) {
            records.longestTranscriptionWords = Int(longest.wordCount)
            records.longestTranscriptionDate = longest.timestamp
        }

        // Most words and sessions in a single day
        var dayWords: [Date: Int] = [:]
        var daySessions: [Date: Int] = [:]
        for entity in allEntities {
            let day = calendar.startOfDay(for: entity.timestamp)
            dayWords[day, default: 0] += Int(entity.wordCount)
            daySessions[day, default: 0] += 1
        }

        if let (date, words) = dayWords.max(by: { $0.value < $1.value }) {
            records.mostWordsInDay = words
            records.mostWordsInDayDate = date
        }

        if let (date, count) = daySessions.max(by: { $0.value < $1.value }) {
            records.mostSessionsInDay = count
            records.mostSessionsInDayDate = date
        }

        personalRecords = records
    }

    // MARK: - Formatting Helpers

    func formattedWords(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    func formattedDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    func comparisonLabel(current: Int, previous: Int, suffix: String = "") -> String {
        guard previous > 0 else {
            return current > 0 ? "New this \(selectedPeriod.rawValue.lowercased())" : ""
        }
        let change = Int(round(Double(current - previous) / Double(previous) * 100))
        let arrow = change >= 0 ? "↑" : "↓"
        return "\(arrow) \(abs(change))%\(suffix) vs last \(selectedPeriod.rawValue.lowercased())"
    }

    func durationComparisonLabel(current: TimeInterval, previous: TimeInterval) -> String {
        guard previous > 0 else {
            return current > 0 ? "New this \(selectedPeriod.rawValue.lowercased())" : ""
        }
        let change = Int(round((current - previous) / previous * 100))
        let arrow = change >= 0 ? "↑" : "↓"
        return "\(arrow) \(abs(change))% vs last \(selectedPeriod.rawValue.lowercased())"
    }
}
