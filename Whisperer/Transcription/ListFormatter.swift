//
//  ListFormatter.swift
//  Whisperer
//
//  Detects and formats spoken enumerations into proper numbered or bulleted lists
//

import Foundation

struct ListFormatter {

    // MARK: - Public API

    /// Formats transcribed text by detecting spoken list patterns and inserting proper
    /// newlines and numbering/bullets. Returns original text unchanged if no list is detected.
    static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Already formatted — don't double-format
        if isAlreadyFormatted(trimmed) { return text }

        // Try unified marker-based detection (handles digits, ordinals, cardinals, "number X", prefixed cardinals)
        if let result = formatByMarkers(trimmed) {
            return result
        }

        // Try bullet trigger detection ("bullet point X", "dash X", "bulletpoint X")
        if let result = formatBulletTriggers(trimmed) {
            return result
        }

        return text
    }

    // MARK: - Marker Types

    private struct Marker {
        let index: Int                    // The list number (1, 2, 3...), -1 for continuation words
        let markerRange: Range<String.Index>  // Range of the marker text itself
        let precedingWord: String?        // Word immediately before the marker (lowercased), nil if at text/sentence start
        let precedingWordStart: String.Index? // Start position of the preceding word
        let isNumberPhrase: Bool          // True if marker is "number X" pattern
    }

    // MARK: - Normalizer Maps

    private static let ordinalMap: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
        "firstly": 1, "secondly": 2, "thirdly": 3, "fourthly": 4, "fifthly": 5,
        "sixthly": 6, "seventhly": 7, "eighthly": 8, "ninthly": 9, "tenthly": 10
    ]

    private static let cardinalMap: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10
    ]

    private static let bulletTriggerPhrases: [[String]] = [
        ["bullet", "point"],
        ["list", "item"],
        ["new", "bullet"],
        ["next", "item"]
    ]

    /// Single-word bullet triggers matched with word boundaries
    private static let singleWordBulletTriggers: Set<String> = ["dash", "bullet"]

    /// "bulletpoint" as one word — matched by case-insensitive string split
    private static let compoundBulletTriggers: [String] = ["bulletpoint"]

    /// Continuation words that extend a list started by ordinals/cardinals.
    /// Index -1 means "auto-increment from previous marker".
    private static let continuationWords: Set<String> = [
        "next", "then", "finally", "last", "lastly"
    ]

    /// Words that get stripped from the end of extracted item text (filler/conjunctions)
    private static let trailingFillerWords: Set<String> = ["uh", "um", "and", "but", "or", "so", "like", "well"]

    /// Noise words that Whisper puts before "number X" markers (mistranscriptions of list cues)
    private static let numberPhraseNoiseWords: Set<String> = [
        "feature", "apple", "section", "point", "line", "entry", "task", "item", "note",
        "topic", "idea", "part", "thing", "step"
    ]

    /// Filler words/phrases that appear between preamble and list (spoken hesitations)
    private static let preambleFillerWords: Set<String> = [
        "sorry", "okay", "ok", "uh", "um", "right", "anyway", "basically",
        "so", "yeah", "actually", "wait", "well"
    ]

    /// Multi-word filler phrases stripped from preamble
    private static let preambleFillerPhrases: [String] = [
        "so yeah", "hold on", "let me think", "i mean", "you know"
    ]

    /// Trailing commentary phrases that appear after the last list item
    private static let trailingCommentaryPhrases: [String] = [
        "and that's it", "that's it", "that's all", "nothing else",
        "and that is it", "that is it", "that is all",
        "and yeah", "and done"
    ]

    /// Single-word trailing commentary
    private static let trailingCommentaryWords: Set<String> = [
        "done", "yeah", "yep", "yes"
    ]

    /// Short trailing commentary phrases (2 words)
    private static let trailingCommentaryShortPhrases: [String] = [
        "i think", "for now"
    ]

    // MARK: - Pre-scan

    private static func isAlreadyFormatted(_ text: String) -> Bool {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return false }

        var formattedCount = 0
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty { continue }
            if trimmedLine.range(of: #"^\d{1,2}\.\s"#, options: .regularExpression) != nil {
                formattedCount += 1
            } else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("• ") {
                formattedCount += 1
            }
        }
        return formattedCount >= 2
    }

    // MARK: - Boundary Check Helpers

    private static func isAtClauseBoundary(_ offset: Int, in text: String) -> Bool {
        if offset == 0 { return true }
        let nsText = (text as NSString)
        let before = nsText.substring(with: NSRange(location: max(0, offset - 3), length: min(3, offset)))
            .trimmingCharacters(in: .whitespaces)
        if before.isEmpty { return true }
        let lastChar = before.last
        return lastChar == "." || lastChar == "!" || lastChar == "?" || lastChar == "," || lastChar == ";" || lastChar == ":"
    }

    private static func isAtSentenceBoundary(_ offset: Int, in text: String) -> Bool {
        if offset == 0 { return true }
        let nsText = (text as NSString)
        let before = nsText.substring(with: NSRange(location: max(0, offset - 3), length: min(3, offset)))
            .trimmingCharacters(in: .whitespaces)
        if before.isEmpty { return true }
        let lastChar = before.last
        return lastChar == "." || lastChar == "!" || lastChar == "?" || lastChar == ":"
    }

    // MARK: - Unified Marker Detection

    /// Finds all potential list markers in the text: ordinals, cardinals, "number X" phrases, and digits.
    private static func findAllMarkers(in text: String) -> [Marker] {
        let lower = text.lowercased()
        let nsLower = lower as NSString
        let length = nsLower.length
        var markers: [Marker] = []

        // Helper: find the word immediately before a marker position
        func precedingWord(before offset: Int) -> (word: String, start: String.Index)? {
            guard offset > 0 else { return nil }
            let before = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: offset)])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let words = before.split(separator: " ")
            guard let last = words.last else { return nil }
            let pw = String(last).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            guard !pw.isEmpty else { return nil }

            let pwLower = pw.lowercased()
            guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: pwLower))\\b", options: .caseInsensitive) else { return nil }
            let matches = regex.matches(in: lower, range: NSRange(location: 0, length: offset))
            guard let lastMatch = matches.last, let swiftRange = Range(lastMatch.range, in: lower) else { return nil }
            return (word: pwLower, start: swiftRange.lowerBound)
        }

        // 1. "number X" phrases (highest priority — most explicit)
        for (word, idx) in cardinalMap {
            let phrase = "number \(word)"
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: lower) else { continue }
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let pw = precedingWord(before: offset)
                markers.append(Marker(index: idx, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: true))
            }
        }
        // "number 1", "number 2", etc.
        if let regex = try? NSRegularExpression(pattern: #"\bnumber\s+(\d{1,2})\b"#, options: .caseInsensitive) {
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: lower) else { continue }
                let digitRange = match.range(at: 1)
                let digitStr = nsLower.substring(with: digitRange)
                guard let idx = Int(digitStr), idx >= 1, idx <= 20 else { continue }
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let pw = precedingWord(before: offset)
                markers.append(Marker(index: idx, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: true))
            }
        }

        // 2. Ordinals ("first", "second", "third", ...)
        for (word, idx) in ordinalMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: lower) else { continue }
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if markers.contains(where: { $0.markerRange.overlaps(range) }) { continue }
                let pw = precedingWord(before: offset)
                markers.append(Marker(index: idx, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: false))
            }
        }

        // 3. Cardinals ("one", "two", "three", ...)
        for (word, idx) in cardinalMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: lower) else { continue }
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                if markers.contains(where: { $0.markerRange.overlaps(range) }) { continue }
                let pw = precedingWord(before: offset)
                markers.append(Marker(index: idx, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: false))
            }
        }

        // 3.5. Continuation words ("next", "then", "finally") — index -1 = auto-increment
        let hasOrdinalOrCardinal = markers.contains { $0.index >= 1 }
        if hasOrdinalOrCardinal {
            for word in continuationWords {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
                for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                    guard let range = Range(match.range, in: lower) else { continue }
                    let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                    if markers.contains(where: { $0.markerRange.overlaps(range) }) { continue }
                    if !isAtClauseBoundary(offset, in: lower) { continue }
                    let pw = precedingWord(before: offset)
                    markers.append(Marker(index: -1, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: false))
                }
            }
        }

        // 4. Digit markers ("1", "2", "1.", "2)", etc.)
        if let regex = try? NSRegularExpression(pattern: #"(?:^|\s)(\d{1,2})(?:[\.\)\:\s,]|$)"#) {
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                let digitRange = match.range(at: 1)
                guard let range = Range(digitRange, in: lower) else { continue }
                let digitStr = nsLower.substring(with: digitRange)
                guard let idx = Int(digitStr), idx >= 1, idx <= 20 else { continue }
                if markers.contains(where: { $0.markerRange.overlaps(range) }) { continue }
                let offset = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let pw = precedingWord(before: offset)
                markers.append(Marker(index: idx, markerRange: range, precedingWord: pw?.word, precedingWordStart: pw?.start, isNumberPhrase: false))
            }
        }

        // Sort by position
        markers.sort { $0.markerRange.lowerBound < $1.markerRange.lowerBound }
        return markers
    }

    // MARK: - Unified List Detection

    private static func formatByMarkers(_ text: String) -> String? {
        let markers = findAllMarkers(in: text)
        guard markers.count >= 2 else { return nil }

        // Try all strategies and pick the one that produces the most items
        var bestResult: String?
        var bestItemCount = 1

        func tryResult(_ result: String?) {
            guard let result = result else { return }
            let count = countListItems(result)
            if count > bestItemCount {
                bestResult = result
                bestItemCount = count
            }
        }

        // Strategy 1: Group markers by shared preceding word (e.g. "Feature one", "Feature two")
        tryResult(tryPrefixedGroups(markers: markers, text: text))

        // Strategy 1.5: "Number X" anchored run — uses all marker types but requires "number X" anchors
        tryResult(tryNumberAnchoredRun(markers: markers, text: text))

        // Strategy 2: Markers at clause/sentence boundaries without requiring shared prefix
        tryResult(tryBoundaryMarkers(markers: markers, text: text))

        // Strategy 2.5: Sequential ordinals without boundary requirements (2+ items)
        tryResult(tryOrdinalSequence(markers: markers, text: text))

        // Strategy 3: Bare sequential digit markers (e.g. "1 apples 2 bananas")
        tryResult(trySequentialDigits(markers: markers, text: text))

        return bestResult
    }

    /// Count formatted list items in a result string
    private static func countListItems(_ result: String) -> Int {
        return result.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil || trimmed.hasPrefix("- ")
        }.count
    }

    /// Strategy 1: Find markers grouped by a shared preceding word
    private static func tryPrefixedGroups(markers: [Marker], text: String) -> String? {
        let lower = text.lowercased()

        var groups: [String: [Marker]] = [:]
        for m in markers {
            guard let pw = m.precedingWord else { continue }
            if falsePositivePrecedingWords.contains(pw) { continue }
            groups[pw, default: []].append(m)
        }

        var bestResult: String?
        var bestCount = 1

        for (_, group) in groups {
            let sorted = group.sorted { $0.markerRange.lowerBound < $1.markerRange.lowerBound }
            guard let sequential = longestSequentialRun(sorted), sequential.count > bestCount else { continue }

            // Reject 2-item groups only if span contains narrative conjunctions
            if sequential.count == 2 {
                let firstEnd = sequential[0].markerRange.upperBound
                let lastStart = sequential[1].markerRange.lowerBound
                if let pwStart = sequential[1].precedingWordStart, pwStart < lastStart {
                    let span = String(lower[firstEnd..<pwStart])
                    if !span.contains(".") && !span.contains("!") && !span.contains("?") {
                        let spanWords = span.split(separator: " ").map {
                            $0.trimmingCharacters(in: .punctuationCharacters).lowercased()
                        }
                        let narrativeConjunctions: Set<String> = [
                            "but", "however", "although", "where", "which",
                            "because", "while", "though", "yet", "whereas"
                        ]
                        if spanWords.contains(where: { narrativeConjunctions.contains($0) }) {
                            continue
                        }
                    }
                }
            }

            if let formatted = formatMarkerGroup(sequential, text: text, lower: lower, mode: .prefixed) {
                bestResult = formatted
                bestCount = sequential.count
            }
        }

        return bestResult
    }

    /// Strategy 1.5: Find longest sequential run from ALL markers, requiring at least one "number X" anchor.
    /// Uses per-marker boundary: "number X" markers strip their preceding noise words from item text,
    /// other marker types (ordinals, cardinals, digits) use their own position as boundary.
    private static func tryNumberAnchoredRun(markers: [Marker], text: String) -> String? {
        let lower = text.lowercased()

        guard let sequential = longestSequentialRun(markers), sequential.count >= 2 else { return nil }

        // Require at least one "number X" marker in the run
        guard sequential.contains(where: { $0.isNumberPhrase }) else { return nil }

        return formatMarkerGroup(sequential, text: text, lower: lower, mode: .numberAnchored)
    }

    /// Strategy 2: Markers at clause/sentence boundaries
    private static func tryBoundaryMarkers(markers: [Marker], text: String) -> String? {
        let lower = text.lowercased()

        let boundaryMarkers = markers.filter { marker in
            let markerOffset = lower.distance(from: lower.startIndex, to: marker.markerRange.lowerBound)
            if isAtClauseBoundary(markerOffset, in: lower) { return true }
            if marker.precedingWord == nil { return true }
            if let pwStart = marker.precedingWordStart {
                let pwOffset = lower.distance(from: lower.startIndex, to: pwStart)
                if isAtClauseBoundary(pwOffset, in: lower) { return true }
            }
            return false
        }

        guard boundaryMarkers.count >= 2 else { return nil }
        guard let sequential = longestSequentialRun(boundaryMarkers), sequential.count >= 2 else { return nil }

        // For digit-only runs, require starting at index 1
        let allDigits = sequential.allSatisfy { marker in
            let markerText = String(lower[marker.markerRange])
            return markerText.allSatisfy { $0.isNumber }
        }
        if allDigits && sequential[0].index != 1 {
            return nil
        }

        // Determine if any markers use preceding word as boundary
        let hasPrefixWord = sequential.contains { marker in
            let markerOffset = lower.distance(from: lower.startIndex, to: marker.markerRange.lowerBound)
            if isAtClauseBoundary(markerOffset, in: lower) || marker.precedingWord == nil { return false }
            if let pwStart = marker.precedingWordStart {
                let pwOffset = lower.distance(from: lower.startIndex, to: pwStart)
                return isAtClauseBoundary(pwOffset, in: lower)
            }
            return false
        }
        return formatMarkerGroup(sequential, text: text, lower: lower, mode: hasPrefixWord ? .prefixed : .plain)
    }

    /// Strategy 2.5: Sequential ordinals without boundary requirements (2+ items)
    private static func tryOrdinalSequence(markers: [Marker], text: String) -> String? {
        let lower = text.lowercased()

        let ordinalMarkers = markers.filter { marker in
            let markerText = String(lower[marker.markerRange])
            return ordinalMap[markerText] != nil || marker.index == -1
        }

        guard ordinalMarkers.count >= 2 else { return nil }
        guard let sequential = longestSequentialRun(ordinalMarkers), sequential.count >= 2 else { return nil }

        return formatMarkerGroup(sequential, text: text, lower: lower, mode: .plain)
    }

    /// Strategy 3: Sequential digits without requiring clause boundaries
    private static func trySequentialDigits(markers: [Marker], text: String) -> String? {
        let lower = text.lowercased()

        let digitMarkers = markers.filter { marker in
            let markerText = String(lower[marker.markerRange])
            return markerText.allSatisfy { $0.isNumber }
        }

        guard digitMarkers.count >= 2 else { return nil }
        guard let sequential = longestSequentialRun(digitMarkers), sequential.count >= 2 else { return nil }

        // Reject if the first marker has a false-positive preceding word AND is NOT at a sentence boundary
        // (looking past filler words to find the real context)
        if let pw = sequential[0].precedingWord, falsePositivePrecedingWords.contains(pw) {
            let offset = lower.distance(from: lower.startIndex, to: sequential[0].markerRange.lowerBound)
            if !isAtSentenceBoundary(offset, in: lower) {
                // Check if preceding words are all fillers and there's a sentence boundary before them
                if !isFillerBridgedSentenceBoundary(before: offset, in: lower) {
                    return nil
                }
            }
        }

        return formatMarkerGroup(sequential, text: text, lower: lower, mode: .plain)
    }

    /// Check if the text before `offset` consists of filler words preceded by a sentence boundary.
    /// e.g., "let me list it. hold on 1..." → "hold on" are fillers, "." is a sentence boundary
    private static func isFillerBridgedSentenceBoundary(before offset: Int, in text: String) -> Bool {
        var prefix = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: offset)])
            .trimmingCharacters(in: .whitespaces)

        // Try stripping filler phrases and words from the end, then check for sentence boundary
        var changed = true
        while changed {
            changed = false
            let lowerPrefix = prefix.lowercased()

            // Try multi-word filler phrases
            for phrase in preambleFillerPhrases {
                if lowerPrefix.hasSuffix(phrase) {
                    prefix = String(prefix.dropLast(phrase.count)).trimmingCharacters(in: .whitespaces)
                    changed = true
                    break
                }
            }
            if changed { continue }

            // Try single filler words
            let words = prefix.split(separator: " ")
            if let lastWord = words.last {
                let cleaned = String(lastWord).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?")).lowercased()
                if preambleFillerWords.contains(cleaned) {
                    prefix = words.dropLast().joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
        }

        // After stripping fillers, check if the remaining prefix ends with sentence punctuation
        if let last = prefix.last, last == "." || last == "!" || last == "?" {
            return true
        }
        return false
    }

    // MARK: - Sequential Run Detection

    private static func longestSequentialRun(_ markers: [Marker]) -> [Marker]? {
        guard markers.count >= 2 else { return nil }

        var bestRun: [Marker] = []
        var currentRun: [Marker] = [markers[0]]
        var currentEffectiveIndex = markers[0].index

        for i in 1..<markers.count {
            let nextIndex = markers[i].index
            let expectedNext = currentEffectiveIndex + 1

            if nextIndex == expectedNext || (nextIndex == -1 && currentEffectiveIndex >= 1) {
                currentRun.append(markers[i])
                currentEffectiveIndex = nextIndex == -1 ? expectedNext : nextIndex
            } else if nextIndex == 1 {
                if currentRun.count > bestRun.count { bestRun = currentRun }
                currentRun = [markers[i]]
                currentEffectiveIndex = 1
            } else {
                if currentRun.count > bestRun.count { bestRun = currentRun }
                currentRun = [markers[i]]
                currentEffectiveIndex = nextIndex
            }
        }
        if currentRun.count > bestRun.count { bestRun = currentRun }

        guard bestRun.count >= 2 else { return nil }

        // Resolve -1 indices to actual sequential numbers
        var resolved: [Marker] = []
        var idx = bestRun[0].index
        if idx == -1 { idx = 1 }
        for m in bestRun {
            if m.index == -1 {
                resolved.append(Marker(index: idx, markerRange: m.markerRange, precedingWord: m.precedingWord, precedingWordStart: m.precedingWordStart, isNumberPhrase: m.isNumberPhrase))
            } else {
                idx = m.index
                resolved.append(m)
            }
            idx += 1
        }

        return resolved
    }

    // MARK: - Item Extraction & Formatting

    private enum FormatMode {
        case plain          // Use marker position for all items
        case prefixed       // Use preceding word position for all items (shared prefix)
        case numberAnchored // "number X" markers strip preceding word; others use marker position
    }

    /// Determine the "start" position for each list item based on format mode
    private static func computeItemStarts(_ markers: [Marker], mode: FormatMode) -> [String.Index] {
        var itemStarts: [String.Index] = []
        for (_, m) in markers.enumerated() {
            switch mode {
            case .plain:
                itemStarts.append(m.markerRange.lowerBound)
            case .prefixed:
                if let pwStart = m.precedingWordStart {
                    itemStarts.append(pwStart)
                } else {
                    itemStarts.append(m.markerRange.lowerBound)
                }
            case .numberAnchored:
                // For "number X" markers with known noise words (feature/apple/section/etc.),
                // use precedingWordStart to strip the noise word from prefix/item text.
                // For real preamble words (e.g., "plan" in "release plan. number one"),
                // use markerRange to keep the word in the prefix.
                if m.isNumberPhrase, let pwStart = m.precedingWordStart,
                   let pw = m.precedingWord, numberPhraseNoiseWords.contains(pw) {
                    itemStarts.append(pwStart)
                } else {
                    itemStarts.append(m.markerRange.lowerBound)
                }
            }
        }
        return itemStarts
    }

    /// Formats a sequential group of markers into a list
    private static func formatMarkerGroup(_ markers: [Marker], text: String, lower: String, mode: FormatMode) -> String? {
        guard markers.count >= 2 else { return nil }

        let itemStarts = computeItemStarts(markers, mode: mode)

        // Extract prefix text (everything before the first item start)
        let firstItemStart = itemStarts[0]
        let prefixOffset = lower.distance(from: lower.startIndex, to: firstItemStart)
        let rawPrefix = String(text[text.startIndex..<text.index(text.startIndex, offsetBy: prefixOffset)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = stripPreambleFillers(rawPrefix)

        // Extract items: text after each marker until the next item start (or end)
        var items: [(index: Int, text: String)] = []
        for i in 0..<markers.count {
            let markerEnd = markers[i].markerRange.upperBound
            let markerEndOffset = lower.distance(from: lower.startIndex, to: markerEnd)
            let itemTextStart = text.index(text.startIndex, offsetBy: markerEndOffset)

            let itemTextEnd: String.Index
            if i + 1 < markers.count {
                let nextStart = itemStarts[i + 1]
                let nextOffset = lower.distance(from: lower.startIndex, to: nextStart)
                itemTextEnd = text.index(text.startIndex, offsetBy: nextOffset)
            } else {
                itemTextEnd = text.endIndex
            }

            guard itemTextStart <= itemTextEnd else { continue }
            let rawItemText = String(text[itemTextStart..<itemTextEnd])
            let itemText = cleanItemText(rawItemText)

            guard !itemText.isEmpty else { continue }
            items.append((index: markers[i].index, text: itemText))
        }

        guard items.count >= 2 else { return nil }

        // Extract trailing commentary from last item
        var commentary: String?
        if var lastItem = items.last {
            let (cleaned, trailing) = extractTrailingCommentary(lastItem.text)
            if let trailing = trailing {
                lastItem = (index: lastItem.index, text: cleaned)
                items[items.count - 1] = lastItem
                commentary = trailing
            }
        }

        return buildFormattedList(prefix: prefix, items: items, style: .numbered, commentary: commentary)
    }

    // MARK: - False-Positive Prevention

    private static let falsePositivePrecedingWords: Set<String> = [
        "have", "has", "had", "is", "are", "was", "were", "be", "been",
        "about", "around", "approximately", "roughly", "nearly", "almost",
        "than", "over", "under", "between", "among",
        "buy", "bought", "get", "got", "need", "needs", "want", "wants",
        "take", "took", "takes", "make", "made", "makes",
        "of", "for", "with", "at", "to", "in", "on", "by",
        "just", "only", "like", "plus", "minus", "times",
        "age", "aged", "year", "years", "old",
        "chapter", "page", "version", "level", "grade", "size",
        "implement", "implementing", "build", "building",
        "costs", "cost", "add", "added", "adds",
        "call", "apartment", "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]

    // MARK: - Bullet Trigger Detection

    private static func formatBulletTriggers(_ text: String) -> String? {
        // Unified approach: find ALL bullet trigger positions, sort by position, extract items
        let lower = text.lowercased()
        let nsLower = lower as NSString
        let length = nsLower.length

        struct BulletMatch {
            let range: Range<String.Index>
        }

        var matches: [BulletMatch] = []

        // Find compound triggers ("bulletpoint")
        for trigger in compoundBulletTriggers {
            var searchStart = lower.startIndex
            while let range = lower.range(of: trigger, options: .caseInsensitive, range: searchStart..<lower.endIndex) {
                matches.append(BulletMatch(range: range))
                searchStart = range.upperBound
            }
        }

        // Find multi-word triggers ("bullet point", "list item", "new bullet", "next item")
        for phrase in bulletTriggerPhrases {
            let trigger = phrase.joined(separator: " ")
            var searchStart = lower.startIndex
            while let range = lower.range(of: trigger, options: .caseInsensitive, range: searchStart..<lower.endIndex) {
                // Don't add if overlapping with existing match
                if !matches.contains(where: { $0.range.overlaps(range) }) {
                    matches.append(BulletMatch(range: range))
                }
                searchStart = range.upperBound
            }
        }

        // Find single-word triggers ("dash", "bullet", "point") with word boundaries
        let singleTriggers = singleWordBulletTriggers.union(["point"])
        for trigger in singleTriggers {
            guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b", options: .caseInsensitive) else { continue }
            for match in regex.matches(in: lower, range: NSRange(location: 0, length: length)) {
                guard let range = Range(match.range, in: lower) else { continue }
                // Don't add if overlapping with existing match (e.g., "bullet" in "bullet point")
                if !matches.contains(where: { $0.range.overlaps(range) }) {
                    matches.append(BulletMatch(range: range))
                }
            }
        }

        guard matches.count >= 2 else { return nil }

        // Sort by position
        matches.sort { $0.range.lowerBound < $1.range.lowerBound }

        // Extract prefix and items
        let firstMatchStart = matches[0].range.lowerBound
        let rawPrefix = String(text[text.startIndex..<firstMatchStart])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = stripPreambleFillers(rawPrefix)

        var items: [String] = []
        for i in 0..<matches.count {
            let itemTextStart = matches[i].range.upperBound
            let itemTextEnd: String.Index
            if i + 1 < matches.count {
                itemTextEnd = matches[i + 1].range.lowerBound
            } else {
                itemTextEnd = text.endIndex
            }
            guard itemTextStart <= itemTextEnd else { continue }
            let rawItemText = String(text[itemTextStart..<itemTextEnd])
            let itemText = cleanItemText(rawItemText)
            if !itemText.isEmpty {
                items.append(itemText)
            }
        }

        guard items.count >= 2 else { return nil }

        // Extract trailing commentary from last item
        var commentary: String?
        let (cleaned, trailing) = extractTrailingCommentary(items[items.count - 1])
        if let trailing = trailing {
            items[items.count - 1] = cleaned
            commentary = trailing
        }

        var output = ""
        if !prefix.isEmpty {
            output += formatPrefixLine(prefix) + "\n"
        }
        for item in items {
            output += "- \(capitalizeFirst(item))\n"
        }
        if let commentary = commentary {
            output += commentary + "\n"
        }
        return output.trimmingCharacters(in: .newlines)
    }

    // MARK: - Helpers

    private enum ListStyle {
        case numbered
        case bulleted
    }

    private static func buildFormattedList(prefix: String, items: [(index: Int, text: String)], style: ListStyle, commentary: String? = nil) -> String {
        var output = ""
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrefix.isEmpty {
            output += formatPrefixLine(trimmedPrefix) + "\n"
        }
        for item in items {
            let capitalizedText = capitalizeFirst(item.text)
            switch style {
            case .numbered:
                output += "\(item.index). \(capitalizedText)\n"
            case .bulleted:
                output += "- \(capitalizedText)\n"
            }
        }
        if let commentary = commentary {
            output += commentary + "\n"
        }
        return output.trimmingCharacters(in: .newlines)
    }

    private static func formatPrefixLine(_ prefix: String) -> String {
        let lastChar = prefix.last
        if lastChar == "." || lastChar == "!" {
            return String(prefix.dropLast()) + ":"
        } else if lastChar == ":" || lastChar == "?" {
            return prefix
        } else {
            return prefix + ":"
        }
    }

    private static func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// Cleans extracted item text: strips leading separator chars, strips trailing periods,
    /// strips trailing filler/conjunction words.
    private static func cleanItemText(_ raw: String) -> String {
        var text = raw
        while let first = text.first, first.isWhitespace || first == "," || first == ";" {
            text = String(text.dropFirst())
        }
        // Strip a leading period followed by space or letter
        if text.hasPrefix(". ") {
            text = String(text.dropFirst(2))
        } else if text.hasPrefix(".") && text.count > 1 && text.dropFirst().first?.isLetter == true {
            text = String(text.dropFirst())
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // Strip trailing periods
        while text.hasSuffix(".") {
            text = String(text.dropLast())
        }
        text = text.trimmingCharacters(in: .whitespaces)

        // Strip trailing filler/conjunction words only when preceded by sentence-ending punctuation
        var words = text.split(separator: " ", omittingEmptySubsequences: true)
        while words.count >= 2, let lastWord = words.last {
            let cleaned = lastWord.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                .lowercased()
            if trailingFillerWords.contains(cleaned) {
                let prevWord = String(words[words.count - 2])
                let prevLastChar = prevWord.last
                if prevLastChar == "." || prevLastChar == "!" || prevLastChar == "?" || prevLastChar == ";" {
                    words.removeLast()
                } else {
                    break
                }
            } else {
                break
            }
        }
        text = words.joined(separator: " ")
        text = text.trimmingCharacters(in: .whitespaces)

        // Strip trailing periods again after filler word removal
        while text.hasSuffix(".") {
            text = String(text.dropLast())
        }
        text = text.trimmingCharacters(in: .whitespaces)

        return text
    }

    /// Strips trailing filler words/phrases from preamble text.
    /// Only strips fillers that come after a sentence boundary (period/!/?) to avoid
    /// breaking meaningful preambles like "all right" or "so basically".
    /// e.g., "for tomorrow. sorry" → "for tomorrow", "here's the list. okay" → "here's the list"
    private static func stripPreambleFillers(_ prefix: String) -> String {
        var result = prefix

        // Strip trailing punctuation first
        while let last = result.last, last == "." || last == "," || last == ";" {
            result = String(result.dropLast())
        }
        result = result.trimmingCharacters(in: .whitespaces)

        // Only strip fillers if there's a sentence boundary before them
        var changed = true
        while changed {
            changed = false
            let lowerResult = result.lowercased()

            // Try multi-word filler phrases first
            for phrase in preambleFillerPhrases {
                if lowerResult.hasSuffix(phrase) {
                    let beforePhrase = String(result.dropLast(phrase.count))
                        .trimmingCharacters(in: .whitespaces)
                    // Only strip if the remaining text ends with sentence punctuation
                    if let last = beforePhrase.last, last == "." || last == "!" || last == "?" || last == "," {
                        result = beforePhrase
                        while let l = result.last, l == "." || l == "," || l == ";" {
                            result = String(result.dropLast())
                        }
                        result = result.trimmingCharacters(in: .whitespaces)
                        changed = true
                        break
                    }
                }
            }

            if changed { continue }

            // Try single filler words
            let words = result.split(separator: " ")
            if words.count >= 2 {
                let lastWord = String(words.last!).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                    .lowercased()
                if preambleFillerWords.contains(lastWord) {
                    let candidate = words.dropLast().joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    // Only strip if the remaining text ends with sentence punctuation
                    if let last = candidate.last, last == "." || last == "!" || last == "?" || last == "," {
                        result = candidate
                        while let l = result.last, l == "." || l == "," || l == ";" {
                            result = String(result.dropLast())
                        }
                        result = result.trimmingCharacters(in: .whitespaces)
                        changed = true
                    }
                }
            }
        }

        return result
    }

    /// Extracts trailing commentary from the last item text.
    /// Returns (cleaned item text, commentary text or nil)
    private static func extractTrailingCommentary(_ text: String) -> (String, String?) {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Try multi-word trailing commentary phrases
        for phrase in trailingCommentaryPhrases {
            if lower.hasSuffix(phrase) {
                let commentary = String(text.suffix(phrase.count))
                let cleaned = String(text.dropLast(phrase.count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    return (cleaned, capitalizeFirst(commentary.trimmingCharacters(in: .whitespaces)))
                }
            }
        }

        // Try short phrases (2 words)
        for phrase in trailingCommentaryShortPhrases {
            if lower.hasSuffix(phrase) {
                let commentary = String(text.suffix(phrase.count))
                let cleaned = String(text.dropLast(phrase.count))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    return (cleaned, capitalizeFirst(commentary.trimmingCharacters(in: .whitespaces)))
                }
            }
        }

        // Try single-word trailing commentary (after a sentence boundary)
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        if words.count >= 2 {
            let lastWord = String(words.last!).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                .lowercased()
            if trailingCommentaryWords.contains(lastWord) {
                let prevWord = String(words[words.count - 2])
                let prevLastChar = prevWord.last
                if prevLastChar == "." || prevLastChar == "!" || prevLastChar == "?" {
                    let commentary = capitalizeFirst(String(words.last!).trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
                    var cleaned = words.dropLast().joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    // Strip trailing punctuation from cleaned text
                    while let last = cleaned.last, last == "." || last == "," || last == ";" {
                        cleaned = String(cleaned.dropLast())
                    }
                    cleaned = cleaned.trimmingCharacters(in: .whitespaces)
                    return (cleaned, commentary)
                }
            }
        }

        return (text, nil)
    }

    private static func splitByTrigger(_ text: String, trigger: String) -> [String] {
        var parts: [String] = []
        var searchRange = text.startIndex..<text.endIndex

        while let range = text.range(of: trigger, options: .caseInsensitive, range: searchRange) {
            let before = String(text[searchRange.lowerBound..<range.lowerBound])
            parts.append(before)
            searchRange = range.upperBound..<text.endIndex
        }
        parts.append(String(text[searchRange]))

        return parts
    }

    private static func splitByWordBoundaryTrigger(_ text: String, trigger: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b", options: .caseInsensitive) else {
            return [text]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return [text] }

        var parts: [String] = []
        var lastEnd = 0

        for match in matches {
            let before = nsText.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            parts.append(before)
            lastEnd = NSMaxRange(match.range)
        }
        parts.append(nsText.substring(from: lastEnd))

        return parts
    }
}
