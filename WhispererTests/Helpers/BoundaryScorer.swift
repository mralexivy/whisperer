//
//  BoundaryScorer.swift
//  WhispererTests
//
//  Position-aligned scoring for punctuation and casing edits — the one ruler every polish
//  benchmark uses, so that two of them cannot quietly disagree about what "correct" means.
//
//  The alignment machinery here was written for `PolishBenchmarkTests`'s sentence-boundary F1
//  (verdict rule 3b) and lived inside that class. It is extracted because rule 5 — per-class edit
//  precision — needs the same thing and was using something else: a word-level proxy that asked
//  *"does this word end a sentence at every occurrence in the reference?"* and never looked at
//  **where** the period was inserted. That proxy scored the identical set of insertions at 0.8646
//  while this one scored them at 0.9938, and the gap is entirely the question being asked. A
//  bag-of-words test cannot score a positional edit; one ruler, used by both rules, is the fix.
//
//  Everything is expressed in **reference-word index space**: hypothesis words are aligned to
//  reference words by LCS over folded forms, and a boundary is reported as the reference position
//  it lands after. That keeps the two sides comparable when the arms disagree about the words
//  themselves, which on this corpus they routinely do.
//
//  What this is not: it is not a judgement about whether a reference is right. Both references in
//  use here — the whole-file `goldenTranscript` decode and the LLM-authored gold — have known
//  limits recorded at their own call sites. This file only says whether two strings agree about
//  where sentences end.
//

import Foundation
@testable import whisperer

enum BoundaryScorer {

    // MARK: - Counts

    /// One comparison's boundary tally, kept as counts rather than as a ratio.
    ///
    /// Per-row F1 is meaningless on a 20-second utterance holding two sentences — it takes three
    /// values and its mean is noise — so rows carry counts and each language group divides once,
    /// over its own summed denominators.
    struct Counts {
        var reference = 0
        var hypothesis = 0
        var matched = 0

        static func + (lhs: Counts, rhs: Counts) -> Counts {
            Counts(reference: lhs.reference + rhs.reference,
                   hypothesis: lhs.hypothesis + rhs.hypothesis,
                   matched: lhs.matched + rhs.matched)
        }

        /// `nil`, never zero, on an empty denominator. An arm that emitted no terminators has no
        /// measured precision at all, and a 0.0000 in that cell would be read as a total failure
        /// by anyone scanning the table — a different and much worse claim.
        var precision: Double? {
            hypothesis > 0 ? Double(matched) / Double(hypothesis) : nil
        }

        var recall: Double? {
            reference > 0 ? Double(matched) / Double(reference) : nil
        }

        /// `nil` only when the *reference* has no boundaries — then there is nothing to be right
        /// or wrong about. When the reference has boundaries and the arm emitted none, this is
        /// **0**, not `unmeasured`: precision is undefined but recall is exactly zero, and
        /// F1 = 2PR/(P+R) → 0 as R → 0 for any P. Reporting that cell as `unmeasured` would hide
        /// the single regression this whole column was added to catch — an arm that stopped
        /// punctuating and returned one unbroken run-on, which the folded WER cannot see either.
        var f1: Double? {
            guard reference > 0 else { return nil }
            guard let precision, let recall, precision + recall > 0 else { return 0 }
            return 2 * precision * recall / (precision + recall)
        }
    }

    /// A precision tally for edits the pipeline *made*, as opposed to boundaries it emitted.
    ///
    /// Separate from `Counts` because the denominators are different questions. `Counts.precision`
    /// judges every boundary in the output, including the ones whisper.cpp already put there;
    /// this judges only the ones the polisher added. Rule 5 is about the edits, so crediting the
    /// pass with punctuation it inherited would be scoring the decoder.
    struct EditCounts {
        var truePositives = 0
        var falsePositives = 0

        var total: Int { truePositives + falsePositives }

        static func + (lhs: EditCounts, rhs: EditCounts) -> EditCounts {
            EditCounts(truePositives: lhs.truePositives + rhs.truePositives,
                       falsePositives: lhs.falsePositives + rhs.falsePositives)
        }

        /// `nil` on an empty denominator, for the same reason `Counts.precision` is.
        var precision: Double? {
            total > 0 ? Double(truePositives) / Double(total) : nil
        }
    }

    // MARK: - Boundary F1

    /// Sentence-boundary counts — does the output end its sentences where the reference does?
    ///
    /// This exists because `wordErrorRate` cannot answer that question and must not be changed to.
    /// Its case- and punctuation-folding is what makes it an honest measure of *word damage*, and
    /// the same fold makes it structurally blind to punctuation: an arm that returned one
    /// unbroken run-on sentence scores exactly the WER of an arm that segmented perfectly.
    ///
    /// A boundary is the position immediately after a word whose trailing character is in
    /// `SentenceStructure.terminators`.
    static func counts(reference: String, hypothesis: String) -> Counts {
        let referenceWords = words(reference)
        let hypothesisWords = words(hypothesis)

        let referenceBoundaries = boundaries(of: referenceWords)
        let hypothesisBoundaries = projectedBoundaries(of: hypothesisWords, onto: referenceWords)

        return Counts(reference: referenceBoundaries.count,
                      hypothesis: hypothesisBoundaries.count,
                      matched: referenceBoundaries.intersection(hypothesisBoundaries).count)
    }

    // MARK: - Edit precision

    /// Precision of the sentence terminators the polisher **added**, by position.
    ///
    /// The inserted set is the polished output's boundaries minus the input's, both projected into
    /// reference-word index space so they are subtractable at all — the polisher deletes fillers
    /// and rewrites aliases, so the two strings do not share a word index. A boundary that survives
    /// that subtraction is one the pass is responsible for; it is a true positive when the
    /// reference also ends a sentence at that position.
    ///
    /// Set semantics throughout, so two terminators the alignment cannot separate (both inside one
    /// run of inserted words, owning no reference position of their own) collapse to one. That
    /// undercounts a rare case rather than crediting a position twice.
    static func insertionCounts(reference: String, input: String, hypothesis: String) -> EditCounts {
        let referenceWords = words(reference)
        let referenceBoundaries = boundaries(of: referenceWords)

        let inserted = projectedBoundaries(of: words(hypothesis), onto: referenceWords)
            .subtracting(projectedBoundaries(of: words(input), onto: referenceWords))

        return EditCounts(truePositives: inserted.intersection(referenceBoundaries).count,
                          falsePositives: inserted.subtracting(referenceBoundaries).count)
    }

    /// The inserted boundaries the reference disagrees with, as reference-word positions with a
    /// window of reference words around each. For the diagnostic report — a bare count of false
    /// positives cannot be argued with, and a position with its context can.
    static func insertionDisagreements(reference: String,
                                       input: String,
                                       hypothesis: String,
                                       context: Int = 4) -> [(position: Int, window: String)] {
        let referenceWords = words(reference)
        let referenceBoundaries = boundaries(of: referenceWords)
        let inserted = projectedBoundaries(of: words(hypothesis), onto: referenceWords)
            .subtracting(projectedBoundaries(of: words(input), onto: referenceWords))

        return inserted.subtracting(referenceBoundaries).sorted().map { position in
            let low = max(0, position - context)
            let high = min(referenceWords.count, position + context)
            let before = referenceWords[low..<min(position, high)].map(\.raw).joined(separator: " ")
            let after = referenceWords[min(position, high)..<high].map(\.raw).joined(separator: " ")
            return (position, "\(before) ⟦.⟧ \(after)")
        }
    }

    /// Precision of the sentence-initial capitals the polisher **added**, by position.
    ///
    /// A recased word is one the polisher changed in case only; it is a true positive when its
    /// aligned reference partner carries the same case. A word with no partner is not scored —
    /// the reference has no opinion about a word it does not contain, and counting that as wrong
    /// would let a sparse reference manufacture a bad score.
    static func casingCounts(reference: String, input: String, hypothesis: String) -> EditCounts {
        let referenceWords = words(reference)
        let inputWords = words(input)
        let hypothesisWords = words(hypothesis)

        // Which hypothesis words are recasings: paired with an input word whose folded form is
        // identical and whose leading character differs. Case-only, so an alias rewrite or a
        // spoken-number expansion — different folded form — cannot be mistaken for one.
        let fromInput = alignment(reference: inputWords.map(\.folded),
                                  hypothesis: hypothesisWords.map(\.folded))
        let toReference = alignment(reference: referenceWords.map(\.folded),
                                    hypothesis: hypothesisWords.map(\.folded))

        var counts = EditCounts()
        for (index, word) in hypothesisWords.enumerated() {
            guard let inputIndex = fromInput[index],
                  let before = inputWords[inputIndex].first,
                  let after = word.first,
                  before != after else { continue }
            guard let referenceIndex = toReference[index],
                  let expected = referenceWords[referenceIndex].first else { continue }
            if expected == after { counts.truePositives += 1 } else { counts.falsePositives += 1 }
        }
        return counts
    }

    // MARK: - Words and alignment

    /// A word carrying the folded form the alignment matches on, the terminator flag the metric
    /// counts, and the leading character the casing comparison reads.
    struct Word {
        let raw: String
        let folded: String
        let terminated: Bool
        /// First character of the alphanumeric core, so a leading quote cannot hide the capital.
        let first: Character?
    }

    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]

    /// Splits on whitespace, folding each word exactly as `PolishBenchmarkTests.normalizedWords`
    /// does so the alignment sees the same word identity WER does.
    ///
    /// A token that folds to nothing — a bare `.` or `…` the decoder emitted as its own word —
    /// would take its terminator out of the sequence with it, so the terminator is handed back to
    /// the preceding word instead of being dropped.
    static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            let folded = String(token.lowercased().filter { $0.isLetter || $0.isNumber })
            // Past any closing quote or bracket to reach the mark: `said."` and `(done.)` end
            // sentences, and reading only the final character would score them as run-ons.
            let mark = token.reversed().drop { closers.contains($0) }.first
            // `Dr.` and `e.g.` are not sentence ends. Scored on both sides this is symmetric, but
            // it is symmetric *noise*: it credits both arms with a boundary neither produced by
            // judgement, and `SentenceTerminator` refuses these positions by design — so counting
            // them would compare the arms on the one thing the pass declines to decide.
            let abbreviation = !folded.isEmpty && SentenceStructure.abbreviates(folded)
            let terminated = (mark.map(SentenceStructure.terminators.contains) ?? false)
                             && !abbreviation
            guard !folded.isEmpty else {
                if terminated, let previous = result.popLast() {
                    result.append(Word(raw: previous.raw, folded: previous.folded,
                                       terminated: true, first: previous.first))
                }
                continue
            }
            result.append(Word(raw: String(token), folded: folded, terminated: terminated,
                               first: token.first { $0.isLetter || $0.isNumber }))
        }
        return result
    }

    /// The positions a word sequence ends sentences at, as indices one past the terminated word.
    static func boundaries(of words: [Word]) -> Set<Int> {
        Set(words.indices.filter { words[$0].terminated }.map { $0 + 1 })
    }

    /// The hypothesis's boundaries, restated as reference-word positions.
    ///
    /// An aligned hypothesis word contributes the position after its reference partner. A word
    /// with no partner — an insertion — owns no reference position, so its boundary falls at the
    /// cursor: immediately after the last reference word that did align. Two terminators inside
    /// one insertion run therefore collapse onto a single position, which is why this returns a
    /// set and the hypothesis denominator is that set's size.
    static func projectedBoundaries(of hypothesis: [Word], onto reference: [Word]) -> Set<Int> {
        let partners = alignment(reference: reference.map(\.folded),
                                 hypothesis: hypothesis.map(\.folded))
        var boundaries: Set<Int> = []
        var cursor = 0
        for (index, word) in hypothesis.enumerated() {
            if let referenceIndex = partners[index] { cursor = referenceIndex + 1 }
            if word.terminated { boundaries.insert(cursor) }
        }
        return boundaries
    }

    /// Hypothesis word index → reference word index, for the words the two sequences share.
    ///
    /// `CollectionDifference` is an LCS diff, so the words it reports as neither removed from the
    /// reference nor inserted into the hypothesis are the common subsequence, in order on both
    /// sides — a parallel walk pairs the survivors one to one. Substitutions pair with nothing,
    /// which is the conservative reading: a boundary after a word neither arm agrees on is not
    /// credited to a reference position it might not belong to.
    static func alignment(reference: [String], hypothesis: [String]) -> [Int: Int] {
        var removedFromReference: Set<Int> = []
        var insertedIntoHypothesis: Set<Int> = []
        for change in hypothesis.difference(from: reference) {
            switch change {
            case let .remove(offset, _, _): removedFromReference.insert(offset)
            case let .insert(offset, _, _): insertedIntoHypothesis.insert(offset)
            }
        }

        var survivingReference = reference.indices
            .filter { !removedFromReference.contains($0) }
            .makeIterator()
        var partners: [Int: Int] = [:]
        for index in hypothesis.indices where !insertedIntoHypothesis.contains(index) {
            guard let referenceIndex = survivingReference.next() else { break }
            partners[index] = referenceIndex
        }
        return partners
    }
}
