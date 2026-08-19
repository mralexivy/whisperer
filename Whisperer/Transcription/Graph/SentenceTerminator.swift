//
//  SentenceTerminator.swift
//  Whisperer
//
//  Where a sentence ends, from silence rather than from prose.
//
//  Every other structural pass in this pipeline *reads* sentence boundaries —
//  `SentenceStructure.openings(in:)` finds them only where a terminator already sits, and
//  `SentenceCaser` and `ParagraphSplitter` build on what it finds. Nothing *supplies* them. On a
//  streaming transcript that is the dominant gap: measured over the 400-recording corpus, 38.2% of
//  utterances have both no terminal mark and an interior run of more than twenty unpunctuated
//  words, and a further 15.2% have the interior run alone. That is what keeps
//  `DeterministicPolisher.needsGenerativePass` true, and therefore what keeps the 4B on the
//  latency path.
//
//  **A model cannot close it.** At its precision-optimal threshold the retrained mmBERT `en/punct
//  .` cell has recall 0.2895 — 207 of 715 gold periods (`Tools/mmbert/CALIBRATION.md` §2a). A
//  precision-gated tagger leaves seven boundaries in ten unmarked by construction, so the interior
//  run survives however good the cell gets. Completeness has to come from a source that is
//  high-precision *by construction*, and that source is the pause: the speaker stopped talking.
//
//  **The signal is ours, not the ASR's** — the same property `ParagraphSplitter` documents. Pauses
//  are derived from `TranscriptChunk` sample counts (`sampleIndex / sampleRate`), not from ASR word
//  timings, so this pass behaves identically at `ASRCapabilities = []` and works behind Nemotron
//  and in meetings. Nothing here reads `TranscriptToken.audioStart`.
//
//  Deliberately narrow. It inserts `.` and nothing else: never a comma, colon or semicolon (those
//  are refused outright by `ConfidenceGate.deniedInsertions`, and the measurement behind that
//  refusal has not changed), never `?` or `!` — question and exclamation are prosody, and this pass
//  has silence, not pitch. A wrong period is one mark on screen; a wrong question mark asserts
//  something about what the speaker meant.
//

import Foundation

enum SentenceTerminator {

    // MARK: - Thresholds

    /// Shortest inter-chunk silence that ends a sentence.
    ///
    /// Below `ParagraphSplitter.pauseAfterSentence` (1.5 s) by design: the same gap that is too
    /// short to be a paragraph is comfortably long enough to be a full stop. The floor is above
    /// ordinary within-sentence hesitation, which sits around 0.2–0.4 s in this corpus.
    static let minimumPause: TimeInterval = 0.7

    /// A pause at least this long is treated as certain. Between the two the confidence ramps, so
    /// a marginal gap is judged by `ConfidenceGate` rather than by this file.
    static let confidentPause: TimeInterval = 1.2

    /// Fewest words an utterance may have and still get a terminating mark at its end.
    ///
    /// Two words is a label, a filename, a search query — text the user is about to paste into a
    /// field, where a trailing period is noise. Sentences start at three.
    static let minimumWordsToTerminate = 3

    // MARK: - Entry point

    /// Period insertions for `graph`.
    ///
    /// - Parameter pauses: inter-chunk silence keyed by the whitespace token at each join, exactly
    ///   the map `ParagraphSplitter` consumes. Empty for a caller holding only a string, in which
    ///   case only the end-of-utterance rule can fire — there is no interior evidence to use, and
    ///   guessing interior boundaries from text alone is the job this pass exists *not* to do.
    /// - Parameter terminatesEnd: whether the final sentence may be closed. False for a mid-stream
    ///   fragment, whose end is wherever the VAD cut rather than where the speaker stopped.
    static func proposals(for graph: TokenGraph,
                          pauses: ParagraphSplitter.Pauses = [:],
                          terminatesEnd: Bool = true) -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []

        // Interior boundaries, in token order so the log reads left to right.
        for (gapID, pause) in pauses.sorted(by: { $0.key < $1.key }) {
            guard pause >= minimumPause,
                  let gapIndex = graph.index(of: gapID),
                  let wordIndex = lastWordIndex(in: graph, before: gapIndex),
                  isTerminatable(graph, wordIndex: wordIndex, upTo: gapIndex) else { continue }

            edits.append(TranscriptEdit(
                target: graph.tokens[wordIndex].id,
                operation: .insertAfter("."),
                source: .acousticBoundary,
                confidence: confidence(for: pause),
                reason: String(format: "sentence end: %.2fs pause after '%@'",
                               pause, graph.tokens[wordIndex].effectiveText)))
        }

        // The end of the utterance. No pause to measure — the recording stopped, which is the
        // strongest endpoint evidence there is, so this is scored on the text alone.
        if terminatesEnd, let edit = endOfUtterance(graph) { edits.append(edit) }

        return edits
    }

    // MARK: - Rules

    private static func confidence(for pause: TimeInterval) -> Float {
        guard pause < confidentPause else { return 0.99 }
        let span = confidentPause - minimumPause
        let position = Float((pause - minimumPause) / span)
        // 0.95 at the floor rising to 0.99: a gap barely over the threshold sits exactly on the
        // gate's cosmetic bar, so a future threshold change moves the boundary rather than
        // silently admitting a class of marginal edits.
        return 0.95 + 0.04 * position
    }

    private static func endOfUtterance(_ graph: TokenGraph) -> TranscriptEdit? {
        let words = graph.tokens.reduce(into: 0) { $0 += $1.isWord ? 1 : 0 }
        guard words >= minimumWordsToTerminate,
              let wordIndex = lastWordIndex(in: graph, before: graph.tokens.count),
              isTerminatable(graph, wordIndex: wordIndex, upTo: graph.tokens.count) else { return nil }

        return TranscriptEdit(
            target: graph.tokens[wordIndex].id,
            operation: .insertAfter("."),
            source: .acousticBoundary,
            // Below the pause tiers on purpose. The endpoint is certain; that the *sentence*
            // finished there is not — the speaker may have released the key mid-thought.
            confidence: 0.96,
            reason: "sentence end: utterance ends at '\(graph.tokens[wordIndex].effectiveText)'")
    }

    /// The last word token strictly before `limit`, or `nil` if there is none.
    private static func lastWordIndex(in graph: TokenGraph, before limit: Int) -> Int? {
        var index = min(limit, graph.tokens.count) - 1
        while index >= 0 {
            if graph.tokens[index].isWord { return index }
            index -= 1
        }
        return nil
    }

    /// Whether a period may be inserted directly after `wordIndex`.
    ///
    /// Refuses five cases, each for a different reason: a mark already stands there (nothing to
    /// add, and stacking `,.` is worse than either); the word is an abbreviation, so the period
    /// would read as part of it; the token is hard-protected, which is a URL or an identifier
    /// whose trailing dot changes what it is; the word carries digits, where `3` followed by
    /// `.` reads as a decimal point; and the word cannot end a sentence at all.
    ///
    /// That last one used to be checked only in `endOfUtterance`, so the same word was refused a
    /// period at the end of an utterance and handed one at a chunk join four words earlier. A
    /// guard applied at one boundary has to be applied at every boundary of the same kind — the
    /// question "can a sentence end after this word?" does not depend on what put the boundary
    /// there. This has no effect on dictation, where the interior rule turns out never to fire
    /// (`PolishInteriorBoundaryTests`: 0 of 439 joins carry a gap, because the eager soft-commit
    /// path stamps `next.start == prev.end`), and a real one on meetings, which reach the pause
    /// map through the VAD chunker whose spans are voiced-only.
    private static func isTerminatable(_ graph: TokenGraph, wordIndex: Int, upTo limit: Int) -> Bool {
        let token = graph.tokens[wordIndex]
        guard token.protection != .hard, token.lifecycle != .userFinal else { return false }
        guard !token.effectiveText.contains(where: \.isNumber) else { return false }
        guard !SentenceStructure.abbreviates(token.effectiveText) else { return false }
        guard !danglesAfter(token.effectiveText) else { return false }

        // Anything between the word and the boundary that is not whitespace is already punctuation.
        for index in (wordIndex + 1)..<min(limit, graph.tokens.count)
        where graph.tokens[index].kind == .punctuation {
            return false
        }
        return true
    }

    /// Words that cannot end a sentence, so an utterance ending in one was cut off rather than
    /// finished.
    ///
    /// Curated for precision in the three languages the app polishes, the same standard as
    /// `ParagraphSplitter.discourseOpeners`: a missing entry costs one period, a wrong entry costs
    /// a period on a sentence that genuinely ended. Conjunctions, prepositions and articles only —
    /// no verbs, which can legitimately close a clause in all three.
    ///
    /// **This set is incomplete and the gap is measured.** At B9 the end-of-utterance rule inserts
    /// a period the authored gold refuses 0 times in 130 English cases, 3 in 48 Hebrew and 1 in 37
    /// Russian — `הוא` twice, `בעצם`, `Моя`, all function words that need a complement and are not
    /// listed here. That is why rule 5 of `PolishVerdictTests` fails while the other nine pass, and
    /// the failure is disclosed in `PolishFeatureFlags` rather than gated away.
    ///
    /// **Do not close it by adding those four words.** They are the entire observed evidence; a
    /// guard fitted on its own failures has measured nothing.
    /// `Tools/llm-eval/calibrate_danglers.py` exists to fit the set from data and returns a
    /// negative against both available references — the whole-file decode disagrees with the gold
    /// 51-to-5 in one direction at this position, and the gold's held-out half holds three
    /// unterminated endings in total. A per-script gate was also tried and reverted: it cost
    /// Hebrew boundary F1 0.742 → 0.412 to remove those three periods, because it removes the
    /// right ones with them. Reopen this with a human-labelled set of utterance-final endings,
    /// roughly 300 per language.
    private static let danglers: Set<String> = [
        // English
        "and", "or", "but", "so", "because", "that", "which", "the", "a", "an", "of", "to", "in",
        "on", "for", "with", "at", "by", "from", "as", "if", "when", "while", "than", "then",
        // Hebrew — "and/that/which", "because", "if", "when", "to", "from", "with", "on", "the"
        "ו", "ש", "כי", "אם", "כאשר", "של", "אל", "מן", "עם", "על", "את", "כדי", "אבל", "או",
        // Russian
        "и", "или", "но", "что", "чтобы", "потому", "если", "когда", "для", "про", "над", "под",
        "при", "без", "через", "как", "чем", "то",
    ]

    private static func danglesAfter(_ word: String) -> Bool {
        danglers.contains(word.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                       locale: nil))
    }
}
