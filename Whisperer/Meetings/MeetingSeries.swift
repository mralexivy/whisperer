//
//  MeetingSeries.swift
//  Whisperer
//
//  Recurring meetings (a weekly 1:1, a daily stand-up) grouped into series for the Notes list.
//
//  A series is two or more meetings with the same title once dates, times and numbering are
//  stripped. Titles from a calendar repeat exactly across occurrences, so this works on the whole
//  history with nothing new stored; the app's own placeholder titles ("Unscheduled Zoom meeting ·
//  11:24", "Meeting") are never grouped. Pure: list items in, series out.
//

import Foundation

enum MeetingSeries {

    enum Cadence: Equatable {
        case daily, weekly(weekday: Int), biweekly, monthly, recurring

        func label(calendar: Calendar = .current) -> String {
            switch self {
            case .daily: return "Daily"
            case .weekly(let weekday): return "Weekly · \(calendar.shortWeekdaySymbols[(weekday - 1) % 7])"
            case .biweekly: return "Every 2 weeks"
            case .monthly: return "Monthly"
            case .recurring: return "Recurring"
            }
        }
    }

    struct Series: Identifiable, Equatable {
        let id: String
        let title: String
        /// Newest first.
        let meetings: [MeetingListItem]
        let cadence: Cadence
        var latest: Date { meetings.first?.createdAt ?? .distantPast }
        var totalDuration: Double { meetings.reduce(0) { $0 + $1.duration } }
    }

    /// Series (newest activity first) and everything that is not part of one.
    static func group(_ items: [MeetingListItem], calendar: Calendar = .current) -> (series: [Series], oneOffs: [MeetingListItem]) {
        var buckets: [String: [MeetingListItem]] = [:]
        var order: [String] = []
        var oneOffs: [MeetingListItem] = []
        for item in items {
            guard let key = key(for: item.title) else { oneOffs.append(item); continue }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
        }
        var series: [Series] = []
        for key in order {
            let members = buckets[key]!.sorted { $0.createdAt > $1.createdAt }
            guard members.count >= 2 else { oneOffs += members; continue }
            series.append(Series(id: key, title: members[0].title, meetings: members,
                                 cadence: cadence(members.map(\.createdAt), calendar: calendar)))
        }
        return (series.sorted { $0.latest > $1.latest }, oneOffs.sorted { $0.createdAt > $1.createdAt })
    }

    /// The title a series is matched on, or nil for a title that is not the meeting's own name.
    static func key(for title: String) -> String? {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("Unscheduled ") || t.hasPrefix("Note ") { return nil }
        if ["meeting", "note", "untitled"].contains(t.lowercased()) { return nil }
        // Trailing dates, times and counters an organiser or the app may append.
        let trailing = [
            #"\s*[·\-–—|,:]\s*\d{1,2}:\d{2}(\s*[AaPp][Mm])?$"#,                 // · 11:24
            #"\s*[·\-–—|,(]?\s*\d{1,4}[./-]\d{1,2}([./-]\d{2,4})?\)?$"#,       // - 10/11, 2026-11-10
            #"\s*[·\-–—|,(]?\s*(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(,?\s*\d{4})?\)?$"#,
            #"\s*[(#]\s*\d+\s*\)?$"#,                                            // (2), #14
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in trailing {
                if let range = t.range(of: pattern, options: [.regularExpression, .caseInsensitive]), !range.isEmpty {
                    t.removeSubrange(range)
                    changed = true
                }
            }
        }
        let key = t.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return key.isEmpty ? nil : key
    }

    /// From the gaps between occurrences: the median gap decides, the weekday is the most common.
    static func cadence(_ dates: [Date], calendar: Calendar = .current) -> Cadence {
        let sorted = dates.sorted()
        guard sorted.count >= 2 else { return .recurring }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) / 86_400 }.sorted()
        let median = gaps[gaps.count / 2]
        switch median {
        case 0.6...1.6: return .daily
        case 5.5...8.5:
            var counts: [Int: Int] = [:]
            for date in sorted { counts[calendar.component(.weekday, from: date), default: 0] += 1 }
            return .weekly(weekday: counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }!.key)
        case 12.5...16: return .biweekly
        case 26...33: return .monthly
        default: return .recurring
        }
    }
}
