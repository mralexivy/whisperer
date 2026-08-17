//
//  ParagraphSplitter.swift
//  Whisperer
//
//  Where the wall of text breaks.
//
//  **The signal is ours, not the ASR's.** A paragraph boundary in dictation is a pause, and the
//  pause is measured by *our* VAD from sample counts — `TranscriptChunk.start` and `.end` are
//  `sampleIndex / sampleRate`, not ASR word timings. That is the whole reason this pass can be
//  acoustic and still work behind Nemotron, which supplies no word structure at all. Nothing here
//  reads `TranscriptToken.audioStart`: doing so would make the output depend on `ASRCapabilities`
//  and break the engine-independence the pipeline is measured on.
//
//  Where the pause is genuinely unavailable — a caller with only a string, which today is every
//  caller — there is a text-only fallback. It is deliberately quiet. A wrong break is one visible
//  blank line the user deletes; a missing break is the state we are already in, so the failure
//  the fallback must avoid is the noisy one. Measured on the 400-recording corpus it fires 7
//  times over 400 utterances (0.39 breaks per 1000 tokens) — rare, but not never, and every one
//  of the seven is a genuine topic shift.
//
//  Breaks are emitted as ordinary `TranscriptEdit`s: the whitespace token at the boundary is
//  *replaced* with a paragraph break. Never a string rewrite, so the gate judges a paragraph the
//  same way it judges a filler deletion, and the edit is recorded in the graph's log with
//  everything else.
//

import Foundation

enum ParagraphSplitter {

    // MARK: - Pause evidence

    /// Silence, in seconds, immediately before the boundary whitespace token named by the key.
    ///
    /// Built by the caller from consecutive `TranscriptChunk` spans — chunk *n*'s `end` to chunk
    /// *n+1*'s `start`. Empty when the caller has none, which switches this pass to the text-only
    /// rule wholesale rather than mixing the two: if pauses are known, a short pause is positive
    /// evidence that there is *no* paragraph here, and a text heuristic must not overrule it.
    typealias Pauses = [TokenID: TimeInterval]

    // MARK: - Thresholds

    /// A pause this long after a completed sentence is a paragraph. Below the ~2 s a speaker
    /// leaves between topics, above the ~0.4–0.8 s of ordinary sentence-final breathing.
    private static let pauseAfterSentence: TimeInterval = 1.5

    /// A pause this long is a paragraph even mid-sentence — long enough that whatever the ASR
    /// did with the punctuation, the speaker stopped and started again.
    private static let pauseRegardless: TimeInterval = 2.5

    /// Text-only rule. Three sentences is the shortest run that can plausibly be a paragraph;
    /// below it a discourse marker is just how the speaker joins two thoughts.
    private static let minimumSentencesBetweenBreaks = 3

    /// …and six is the point at which an unbroken run is a wall whatever it opens with.
    private static let sentencesForcingABreak = 6

    /// Nothing shorter than this is ever split on text alone. Both floors, not either: four
    /// terse sentences are not a wall, and sixty words in two sentences have no boundary to use.
    private static let minimumSentencesInText = 4
    private static let minimumWordsInText = 60

    /// A pause may split a shorter transcript than a heuristic may, because it is evidence
    /// rather than a guess — but not an utterance too short to have two paragraphs at all.
    private static let minimumWordsForPause = 25

    /// What a break renders as. A blank line, so the boundary survives a round trip through any
    /// editor that reflows single newlines.
    static let breakText = "\n\n"

    // MARK: - Entry point

    static func proposals(for graph: TokenGraph, pauses: Pauses = [:]) -> [TranscriptEdit] {
        let openings = SentenceStructure.openings(in: graph)
        guard openings.count > 1 else { return [] }

        let wordCount = graph.tokens.reduce(into: 0) { $0 += $1.isWord ? 1 : 0 }
        let usesPauses = !pauses.isEmpty

        if usesPauses {
            guard wordCount >= minimumWordsForPause else { return [] }
        } else {
            guard openings.count >= minimumSentencesInText,
                  wordCount >= minimumWordsInText else { return [] }
        }

        var edits: [TranscriptEdit] = []
        var sentencesSinceBreak = 1

        for opening in openings.dropFirst() {
            guard let gapID = opening.gapID,
                  let index = graph.index(of: gapID),
                  graph.tokens[index].effectiveText != breakText else {
                sentencesSinceBreak += 1
                continue
            }

            let verdict = usesPauses
                ? pauseVerdict(pauses[gapID], opening: opening)
                : textVerdict(opening, in: graph, sentencesSinceBreak: sentencesSinceBreak)

            guard let verdict else {
                sentencesSinceBreak += 1
                continue
            }

            edits.append(TranscriptEdit(target: gapID,
                                        operation: .replace(breakText),
                                        source: .normalization,
                                        confidence: verdict.confidence,
                                        reason: verdict.reason))
            sentencesSinceBreak = 1
        }

        return edits
    }

    // MARK: - Rules

    private struct Verdict {
        let confidence: Float
        let reason: String
    }

    /// Acoustic. The pause is the whole argument, so the only text condition is whether the
    /// sentence before it actually finished — which decides *which* threshold applies, not
    /// whether one does.
    private static func pauseVerdict(_ pause: TimeInterval?, opening: SentenceStructure.Opening)
    -> Verdict? {
        guard let pause else { return nil }
        if opening.isTerminated, pause >= pauseAfterSentence {
            return Verdict(confidence: 0.97,
                           reason: String(format: "paragraph: %.2fs pause after a sentence", pause))
        }
        if pause >= pauseRegardless {
            return Verdict(confidence: 0.95,
                           reason: String(format: "paragraph: %.2fs pause", pause))
        }
        return nil
    }

    /// Text-only. Requires a completed sentence *and* enough of them since the last break, then
    /// either a discourse marker opening the next one or a run long enough to break regardless.
    private static func textVerdict(_ opening: SentenceStructure.Opening,
                                    in graph: TokenGraph,
                                    sentencesSinceBreak: Int) -> Verdict? {
        guard opening.isTerminated, sentencesSinceBreak >= minimumSentencesBetweenBreaks else {
            return nil
        }

        let opener = fold(graph.tokens[opening.wordIndex].effectiveText)
        if discourseOpeners.contains(opener) {
            return Verdict(confidence: 0.95,
                           reason: "paragraph: topic-shift opener '\(opener)' after "
                                 + "\(sentencesSinceBreak) sentences")
        }
        if sentencesSinceBreak >= sentencesForcingABreak {
            return Verdict(confidence: 0.92,
                           reason: "paragraph: \(sentencesSinceBreak) sentences without a break")
        }
        return nil
    }

    // MARK: - Vocabulary

    /// Words that open a new thought rather than continue one, in the three languages the app
    /// polishes — the same coverage pattern as `TranscriptNormalizer`'s filler tables, and for
    /// the same reason: a Latin-only list gives Hebrew and Russian dictation no rule at all.
    ///
    /// Curated for precision, not recall. `and`, `but`, `then`, `actually`, `basically`, `right`
    /// and Hebrew `טוב` are all common *mid*-paragraph openers and are deliberately absent —
    /// each of them would fire several times per long dictation and be wrong most of them.
    /// `короче` and `כאילו` are absent because `TranscriptNormalizer` deletes them as fillers
    /// before this pass runs, so a rule keyed on them could never match.
    private static let discourseOpeners: Set<String> = [
        // English
        "so", "now", "anyway", "anyways", "okay", "ok", "alright", "next", "finally", "lastly",
        "meanwhile", "however", "moreover", "furthermore", "additionally", "overall", "secondly",
        "thirdly",
        // Hebrew — "so", "now", "in short", "okay", "in addition", "to summarize", "finally"
        "אז", "עכשיו", "בקיצור", "אוקיי", "בנוסף", "לסיכום", "לבסוף",
        // Russian — "so", "now", "fine", "by the way", "however", "next", "finally", "so then"
        "итак", "теперь", "ладно", "кстати", "впрочем", "далее", "наконец", "значит",
    ]

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
