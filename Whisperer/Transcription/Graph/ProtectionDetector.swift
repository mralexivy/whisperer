//
//  ProtectionDetector.swift
//  Whisperer
//
//  Marks the spans no automatic edit may touch — without altering a single character.
//
//  This replaces the mechanism in `TranscriptPreCleaner.protectTokens`, not its rules. The 13
//  patterns are reused verbatim; what changes is what happens to a match. Today a match is
//  *substituted* with a `__URL_1__` sentinel, which has three confirmed defects:
//
//  1. The sentinels are out-of-vocabulary strings, and nothing constrains a decoder to return
//     them intact — the protection depends on the very model it is protecting against.
//  2. The shipped `AIMode.correct` prompt contradicts the mechanism, showing raw
//     `docker run --rm -it` and `./src/utils` examples the model is asked to preserve.
//  3. All 13 patterns are ASCII character classes. They still match a Latin identifier sitting
//     inside a Hebrew sentence — but nothing else in a Hebrew or Russian transcript is
//     protected at all, because the pattern set has no rule that fires on non-Latin text.
//
//  A mask has none of these. The text is never altered, so there is nothing to restore and
//  nothing to be echoed back wrong; and protection can be assigned on properties of a token
//  (its script, its digits, its casing) rather than only on ASCII shapes.
//
//  **Over-protection is the safe direction.** A hard span merely loses the chance to be
//  corrected; an unprotected identifier can be silently rewritten. Precision over recall, as
//  the whole design requires, so borderline cases go to `hard`.
//

import Foundation

enum ProtectionDetector {

    // MARK: - Patterns

    /// The rule set from `TranscriptPreCleaner.protectTokens`, unchanged and in the same order.
    /// Order no longer matters for correctness — protection is a `max`, so an overlapping match
    /// cannot undo an earlier one — but it is preserved so the two lists stay diffable.
    private static let hardPatterns: [(pattern: String, label: String)] = [
        ("https?://\\S+", "URL"),
        ("\\S+@\\S+\\.\\S+", "EMAIL"),
        ("[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+", "REPO"),
        ("[a-zA-Z]+-\\d+(?:\\.\\d+)*(?:-[a-zA-Z0-9]+)*", "MODEL"),
        ("[a-zA-Z]+\\d+\\.\\d+(?:\\.\\d+)*(?:-[a-zA-Z0-9]+)*", "MODEL"),
        ("/[a-zA-Z0-9/_.-]+", "PATH"),
        ("--[a-z][-a-z]+", "FLAG"),
        ("v\\d+\\.\\d+(?:\\.\\d+)*", "VER"),
        ("[a-z]+[A-Z][a-zA-Z]+", "IDENT"),
        ("[a-z]+(?:_[a-z0-9]+)+", "IDENT"),
        ("[a-z]+(?:-[a-z0-9]+){2,}", "IDENT"),
        ("\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}(?::\\d+)?", "IP"),
        ("`[^`]+`", "CODE"),
    ]

    private static let compiled: [(regex: NSRegularExpression, label: String)] = {
        hardPatterns.compactMap { entry in
            (try? NSRegularExpression(pattern: entry.pattern)).map { ($0, entry.label) }
        }
    }()

    // MARK: - Entry point

    /// Annotate every token in `graph` with the protection level it has earned.
    ///
    /// Runs before any edit, which is what makes `tokenIDs(overlappingRawRange:)` valid: the
    /// ranges it maps are into `rawTranscript`, and nothing has moved yet.
    ///
    /// - Parameter dictionaryTerms: canonical spellings from the user's dictionary and the
    ///   shipped lexicon. A term the user has already told us the spelling of is not a
    ///   candidate for correction, in any script.
    static func annotate(_ graph: inout TokenGraph, dictionaryTerms: Set<String> = []) {
        annotatePatternMatches(&graph)
        annotateCommandHeads(&graph)
        annotateTokenShapes(&graph, dictionaryTerms: dictionaryTerms)
    }

    // MARK: - Command heads

    /// A flag protects the words in front of it, not just itself.
    ///
    /// The `FLAG` pattern marks `--rm` and `-it`, but leaves `docker` bare — so the alias engine
    /// sees an ordinary lowercase word it has a canonical spelling for and produces
    /// `Docker run --rm -it`. The command word is the part of a command line that most looks like
    /// prose, which is exactly why it needs the protection more than the flags do. This is also
    /// the mechanism by which the shipped prompt's own `docker run --rm -it` example survives.
    ///
    /// Bounded at four words and stopped by any clause boundary: a flag says "a command ended
    /// here", not "everything before this is code".
    private static func annotateCommandHeads(_ graph: inout TokenGraph) {
        let text = graph.rawTranscript
        guard !text.isEmpty, let regex = flagRegex else { return }

        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let flag = Range(match.range, in: text) else { continue }
            // The flag itself too: the `FLAG` pattern is `--[a-z][-a-z]+`, which misses every
            // single-dash short option — `-it`, `-la`, `-rf`.
            let head = commandHead(before: flag.lowerBound, in: text) ?? flag.lowerBound
            graph.protect(graph.tokenIDs(overlappingRawRange: head..<flag.upperBound), as: .hard)
        }
    }

    /// `(?<![\w-])` keeps this off hyphenated words and off the second dash of `--rm`; `\w` is
    /// Unicode-aware, so Hebrew `ה-server` is a hyphenated word rather than a flag.
    private static let flagRegex = try? NSRegularExpression(
        pattern: "(?<![\\w-])--?[a-zA-Z][-a-zA-Z0-9]*")

    private static let maxCommandWords = 4

    /// The start of the run of command-shaped words immediately preceding `index`, or `nil` if
    /// the flag is not preceded by one.
    private static func commandHead(before index: String.Index, in text: String) -> String.Index? {
        var cursor = index
        var start: String.Index?
        var words = 0

        while cursor > text.startIndex, words < maxCommandWords {
            // Spaces only. A newline, or any punctuation, ends the command.
            var probe = cursor
            while probe > text.startIndex, text[text.index(before: probe)] == " " {
                probe = text.index(before: probe)
            }
            // No space means the previous character is punctuation, which ends the command.
            guard probe > text.startIndex, probe != cursor else { break }

            var wordStart = probe
            while wordStart > text.startIndex {
                let previous = text.index(before: wordStart)
                let character = text[previous]
                guard character.isLetter || character.isNumber
                        || "._-/".contains(character) else { break }
                wordStart = previous
            }
            guard wordStart != probe else { break }

            start = wordStart
            cursor = wordStart
            words += 1
        }
        return start
    }

    // MARK: - Pattern spans

    private static func annotatePatternMatches(_ graph: inout TokenGraph) {
        let text = graph.rawTranscript
        guard !text.isEmpty else { return }
        let full = NSRange(text.startIndex..., in: text)

        for (regex, _) in compiled {
            for match in regex.matches(in: text, range: full) {
                guard let range = Range(match.range, in: text) else { continue }
                // The 3-character floor from the original: shorter matches are overwhelmingly
                // ordinary words that happen to fit an ASCII shape.
                guard text[range].count >= 3 else { continue }
                graph.protect(graph.tokenIDs(overlappingRawRange: range), as: .hard)
            }
        }
    }

    // MARK: - Token shapes

    /// Per-token rules, which is where the non-Latin gap is closed. None of these can be
    /// expressed as an ASCII regex over the whole string, and all of them fire regardless of
    /// which script the surrounding transcript is in.
    private static func annotateTokenShapes(_ graph: inout TokenGraph,
                                            dictionaryTerms: Set<String>) {
        let dominant = dominantFamily(of: graph)
        let normalizedTerms = Set(dictionaryTerms.map { $0.lowercased() })

        var hard: [TokenID] = []
        var soft: [TokenID] = []

        for token in graph.tokens where token.isWord {
            let text = token.rawText

            // Anything containing a digit. A misheard number is a wrong number, and there is no
            // safe partial credit — `preservation = 1.000` is a release gate, not a target.
            if text.contains(where: \.isNumber) {
                hard.append(token.id)
                continue
            }

            // Acronyms: two or more consecutive capitals. `API`, `HTTP`, `RTL`. Case-restoration
            // would otherwise happily turn these into `Api`.
            if hasConsecutiveCapitals(text) {
                hard.append(token.id)
                continue
            }

            // The user has already stated this spelling. Correcting it would be correcting them.
            if normalizedTerms.contains(text.lowercased()) {
                hard.append(token.id)
                continue
            }

            let families = ScriptAnalyzer.scriptFamilies(in: text)

            // A single word written in two scripts is not a word the ASR heard cleanly, and no
            // dictionary in either script can adjudicate it.
            if families.count > 1 {
                soft.append(token.id)
                continue
            }

            // A lone foreign-script word inside an otherwise single-script utterance: a code
            // switch, a borrowed technical term, or a name. `сегодня` in an English sentence,
            // `deployment` in a Hebrew one. Editable, but only on strong evidence.
            if let dominant, let family = families.first, family != dominant {
                soft.append(token.id)
            }
        }

        graph.protect(hard, as: .hard)
        graph.protect(soft, as: .soft)
    }

    /// The script the transcript is mostly written in, by word count rather than character
    /// count — a single long URL should not make an otherwise Hebrew utterance read as Latin.
    /// `nil` when no script is in the majority, in which case nothing is "foreign".
    private static func dominantFamily(of graph: TokenGraph) -> ScriptFamily? {
        var counts: [ScriptFamily: Int] = [:]
        for token in graph.tokens where token.isWord {
            let families = ScriptAnalyzer.scriptFamilies(in: token.rawText)
            guard families.count == 1, let family = families.first else { continue }
            counts[family, default: 0] += 1
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let (family, count) = counts.max(by: { $0.value < $1.value }) else {
            return nil
        }
        return count * 2 > total ? family : nil
    }

    private static func hasConsecutiveCapitals(_ text: String) -> Bool {
        var previousWasCapital = false
        for character in text {
            let isCapital = character.isUppercase
            if isCapital && previousWasCapital { return true }
            previousWasCapital = isCapital
        }
        return false
    }
}
