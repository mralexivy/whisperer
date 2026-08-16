//
//  EagerStreamEngine.swift
//  Whisperer
//
//  Backend-agnostic LocalAgreement-2 streaming algorithm.
//  Extracted from the WhisperKit-specific consumeWhisperKitStreamingResult path so that
//  whisper.cpp can drive the same state machine with its own word-level decode output.
//
//  Design constraints:
//  - Pure: no locks, no SwiftUI, no async, no Logger, no #if canImport.
//    The caller (StreamingTranscriber) holds all locks and owns all side effects.
//  - Owned by StreamingTranscriber on its serial operation queue — never call from multiple threads.
//  - EagerOutcome carries everything the caller needs to apply; the engine mutates no
//    shared state itself.

import Foundation

// MARK: - EagerStreamWord

/// One word with absolute sample-index positions and decoder probability.
/// Matches the shape of both WhisperKitStreamingWord (converted by the adapter) and
/// WhisperStreamWord (produced by WhisperBridge.transcribeStreamingAsync).
struct EagerStreamWord: Sendable {
    let text: String
    let tokens: [Int]
    let startIndex: Int     // absolute sample index in the ring
    let endIndex: Int       // absolute sample index in the ring
    let probability: Float
}

// MARK: - EagerOutcome

/// Everything the caller must apply after one `EagerStreamEngine.consume` call.
struct EagerSoftCommit {
    let text: String
    let startIndex: Int     // was lastTranscribedSampleIndex before this commit
    let endIndex: Int       // new lastTranscribedSampleIndex (the agreement boundary)
}

/// Why a pass was held. Only meaningful when `EagerOutcome.wasHeld` is true.
///
/// Held passes are not free: the decode already ran, and because the agreement boundary advances
/// only inside `consume`, a hold also means the next pass re-decodes nearly the same window. At
/// 35% of all passes (measured over a full profile run) that is the single largest cost on the
/// path, so which of the two guards is firing is worth knowing rather than inferring.
enum EagerHoldReason: String {
    /// Anchor lost, and the window started at the same sample index as the previous pass. Same
    /// audio at the front, different words out — this is the transient decoder collapse the guard
    /// was written for.
    case unanchoredSameStart
    /// Anchor lost, but the window start moved since the previous pass because a confirmation
    /// advanced the agreement boundary. The new window is cut at the boundary word's `startIndex`,
    /// so its first word is decoded from a different (and clipped) span of audio than the word it
    /// is being compared against. Disagreement here is expected, not a collapse — the same
    /// like-with-like error the retraction guard used to make.
    case unanchoredAfterBoundaryMove
    /// The new hypothesis dropped more than `maxRetraction` words that the previous one had over
    /// the same audio.
    case largeRetraction
}

struct EagerOutcome {
    /// Text to show in the live overlay. `nil` = suppress this pass (unstable revision).
    ///
    /// This is `confirmedText` plus the speculative hypothesis tail, so it is the more responsive
    /// of the two and the less stable: the tail is a fresh decode of a growing window and the
    /// decoder rewrites it freely between passes.
    let displayText: String?
    /// The same text with the speculative tail removed — only words that cleared
    /// LocalAgreement-2 or the entropy gate, and so can never be revised.
    ///
    /// Offered alongside `displayText` because which one belongs on screen is an empirical
    /// question, not a design one: the tail buys roughly one pass of latency and costs an
    /// unknown amount of flicker. `StreamingTranscriber.eagerPublishesSpeculativeTail` selects
    /// between them and the profile sweeps both.
    let confirmedText: String?
    /// Present when 6+ seconds of agreed audio has accumulated — caller must append to
    /// completedChunkTexts, fire onChunkCompleted, advance lastTranscribedSampleIndex,
    /// and prune the ring.
    let softCommit: EagerSoftCommit?
    /// `true` when this pass is a large retraction that was held for one more window
    /// before the caller sees a nil displayText.
    let wasHeld: Bool
    /// Which guard held it. `nil` unless `wasHeld`.
    let holdReason: EagerHoldReason?
    /// Diagnostic: the leading hypothesis word repeated the last already-confirmed word over the
    /// same audio. Changes no behaviour; see `leadingWordRepeatsConfirmedTail`.
    let repeatedConfirmedTail: Bool
}

// MARK: - EagerStreamEngine

struct EagerStreamEngine {

    // MARK: - Config

    struct Config {
        /// Words kept "provisional" at the tail of every confirmed prefix (clip boundary).
        let boundaryWordCount: Int
        /// Words confirmed in a single pass without cross-window agreement (p ≥ threshold).
        let singlePassThreshold: Float
        /// How many samples of cross-window-agreed audio triggers a soft-commit.
        let softCommitSamples: Int
        /// Minimum common prefix before any confirmation is safe.
        let requiredAnchor: Int
        /// Retraction larger than this is held for one more window before being shown.
        let maxRetraction: Int
        /// Skip the anchor check on the one pass that immediately follows a boundary advance.
        ///
        /// The anchor check asks whether the decoder produced something wildly different from
        /// last time over the same audio. Right after a confirmation it is not the same audio:
        /// the window is re-cut at the boundary word's `startIndex`, so that word is decoded from
        /// a clipped span with no left context and often comes back different. The guard reads
        /// that as a collapse and throws away a completed decode — and since the boundary only
        /// moves inside `consume`, the next pass then re-decodes nearly the same window.
        ///
        /// A boolean rather than a decision because the cost is measurable on both sides:
        /// skipping the check trades a small window of unguarded output for the passes it saves.
        /// `EagerStreamProfileTests` runs it both ways over the same recordings.
        let skipsAnchorCheckAfterBoundaryMove: Bool
        /// Refuse to confirm a run of words that has already been confirmed twice back-to-back.
        /// See `EagerStreamEngine.confirm(_:)` for what this catches and why it is a count rather
        /// than a similarity test. A flag so the profile can measure the cost of being wrong
        /// about genuinely repetitive speech against the loops it prevents.
        let suppressesRepetitionLoops: Bool

        static let `default` = Config(
            boundaryWordCount: 2,
            singlePassThreshold: 0.95,
            softCommitSamples: Int(6.0 * 16000),
            requiredAnchor: 2,
            maxRetraction: 3,
            skipsAnchorCheckAfterBoundaryMove: false,
            suppressesRepetitionLoops: true
        )

        func with(skipsAnchorCheckAfterBoundaryMove: Bool? = nil,
                  suppressesRepetitionLoops: Bool? = nil) -> Config {
            Config(boundaryWordCount: boundaryWordCount, singlePassThreshold: singlePassThreshold,
                   softCommitSamples: softCommitSamples, requiredAnchor: requiredAnchor,
                   maxRetraction: maxRetraction,
                   skipsAnchorCheckAfterBoundaryMove:
                       skipsAnchorCheckAfterBoundaryMove ?? self.skipsAnchorCheckAfterBoundaryMove,
                   suppressesRepetitionLoops:
                       suppressesRepetitionLoops ?? self.suppressesRepetitionLoops)
        }
    }

    private let config: Config

    // MARK: - Mutable state (owned by caller's serial queue)

    /// Words confirmed across two or more windows but not yet soft-committed.
    private(set) var confirmedWords: [EagerStreamWord] = []
    /// Last window's hypothesis for the anchor check.
    private(set) var previousHypothesis: [EagerStreamWord] = []
    /// Sample index of the oldest unconfirmed word (= clip boundary for the next pass).
    private(set) var agreementStartIndex: Int?
    /// Tokens of the boundary words; used by the stop-path tail reconciliation.
    private(set) var prefixTokens: [Int] = []
    /// The agreement boundary as it stood when the previous `consume` started.
    ///
    /// Only used to classify anchor failures. The two classes need opposite treatment — a failure
    /// at an unchanged window start is real instability; a failure right after the boundary moved
    /// is the comparison being unfair — and telling them apart from the outside is impossible.
    private var previousConsumeStart: Int?

    /// Words the repetition guard refused to confirm this session. Diagnostic; see `confirm(_:)`.
    private(set) var suppressedRepeatWords = 0

    /// The last few confirmed words carried across a soft-commit, so the repetition guard can
    /// still see the tail of the text it just handed off. Without it a loop that straddles a
    /// commit boundary restarts its count from zero and gets a fresh licence to repeat.
    private var committedTail: [EagerStreamWord] = []

    /// How many times a run of words may be confirmed back-to-back before the next identical run
    /// is treated as a decoder loop rather than speech. See `confirm(_:)`.
    private let maximumConsecutiveRepeats = 2
    /// Longest run the guard looks for. The observed loops repeat 1–4 word phrases; beyond that,
    /// three consecutive identical runs is more plausibly a person listing something.
    private let maximumRepeatRunLength = 5

    init(config: Config = .default) {
        self.config = config
    }

    mutating func reset(at sampleIndex: Int) {
        confirmedWords.removeAll()
        previousHypothesis.removeAll()
        agreementStartIndex = sampleIndex
        prefixTokens.removeAll()
        previousConsumeStart = nil
        committedTail.removeAll()
        suppressedRepeatWords = 0
    }

    /// Move the agreement boundary forward over audio that will never be decoded.
    ///
    /// The boundary normally advances only as a *result* of a decode, which is correct while
    /// every span of audio eventually reaches the decoder. It does not once the caller caps the
    /// window: the window is then `[agreementStartIndex, +cap]` and does not move on its own, so
    /// a caller that declines to decode it — because the whole span is silence — would present
    /// the identical window on every subsequent pass and never transcribe another word.
    ///
    /// Only call this for audio proven to contain no speech. It discards the hypothesis chain
    /// because a skipped span breaks continuity: the next window's first words have no
    /// predecessor to agree with, and keeping the stale hypothesis would fail the anchor check
    /// and hold that window for no reason. `confirmedWords` is deliberately kept — those words
    /// are still awaiting their soft-commit.
    mutating func seek(past sampleIndex: Int) {
        guard sampleIndex > agreementStartIndex ?? Int.min else { return }
        agreementStartIndex = sampleIndex
        previousHypothesis.removeAll()
        prefixTokens.removeAll()
    }

    // MARK: - consume

    /// Run one pass of the agreement algorithm.
    ///
    /// - Parameters:
    ///   - hypothesis: Words from the current decode window (absolute sample indices).
    ///   - audioBaseIndex: The absolute sample index the window started at (ring start
    ///     passed to the decoder, used to filter hypothesis to the unconfirmed region).
    ///   - languageIsLocked: Whether the language router has settled on a language.
    ///     Confirmation and entropy-gate are gated on this; preview text still displays.
    ///   - lastCommittedIndex: `lastTranscribedSampleIndex` — for the soft-commit test.
    ///   - windowEndIndex: Absolute sample index the decoded window ended at. Used to tell a
    ///     retraction apart from a window that simply got shorter; see the guard below.
    mutating func consume(
        hypothesis: [EagerStreamWord],
        audioBaseIndex: Int,
        languageIsLocked: Bool,
        lastCommittedIndex: Int,
        windowEndIndex: Int
    ) -> EagerOutcome {
        let agreementStart = agreementStartIndex ?? audioBaseIndex
        let boundaryMoved = previousConsumeStart != nil && previousConsumeStart != agreementStart
        previousConsumeStart = agreementStart

        // Filter hypothesis to the unconfirmed region (past the agreement boundary)
        var hyp = hypothesis.filter { $0.startIndex >= agreementStart }
        guard !hyp.isEmpty else {
            return EagerOutcome(displayText: nil, confirmedText: nil, softCommit: nil,
                                wasHeld: false, holdReason: nil, repeatedConfirmedTail: false)
        }
        let repeatedConfirmedTail = leadingWordRepeatsConfirmedTail(hyp)

        // ── Anchor / retraction guard ──────────────────────────────────────────────
        // A genuine correction aligns with the previous window on at least requiredAnchor
        // words. A transient decoder collapse does not — hold it for one more window.
        if !previousHypothesis.isEmpty {
            let commonCount = commonPrefixCount(previousHypothesis, hyp)
            let requiredAnchor = min(config.requiredAnchor, min(previousHypothesis.count, hyp.count))

            // Compare like with like: only the previous words whose audio this window actually
            // covered. Comparing raw counts treats a *shorter window* as a retraction, and the
            // caller shortens the window routinely — the window is `[agreementStart, +cap]`, so
            // every soft-commit that jumps the boundary forward leaves less than a cap's worth of
            // unconfirmed audio behind it and the next hypothesis is legitimately smaller. Those
            // words were not taken back; they were never in scope. Measured cost of getting this
            // wrong: 35% of all passes held over a full profile run, each one a completed GPU
            // decode thrown away *and* a boundary that did not move, so the next pass re-decodes
            // nearly the same audio.
            let comparablePrevious = previousHypothesis.filter { $0.endIndex <= windowEndIndex }
            let lostWordCount = comparablePrevious.count - hyp.count
            // A boundary move re-cuts the window, so the leading word is not comparable — see
            // `Config.skipsAnchorCheckAfterBoundaryMove`. The retraction check still applies:
            // it is already span-corrected, and it is what catches a genuine collapse here.
            let anchorApplies = !(boundaryMoved && config.skipsAnchorCheckAfterBoundaryMove)
            let isUnanchored = anchorApplies && commonCount < requiredAnchor
            let isLargeRetraction = lostWordCount > config.maxRetraction
            if isUnanchored || isLargeRetraction {
                // Hold — update previousHypothesis so the next window sees the new baseline.
                previousHypothesis = hyp
                let reason: EagerHoldReason = isUnanchored
                    ? (boundaryMoved ? .unanchoredAfterBoundaryMove : .unanchoredSameStart)
                    : .largeRetraction
                return EagerOutcome(displayText: nil, confirmedText: nil, softCommit: nil,
                                    wasHeld: true, holdReason: reason,
                                    repeatedConfirmedTail: repeatedConfirmedTail)
            }
        }

        // ── LocalAgreement-2 confirmation ─────────────────────────────────────────
        if languageIsLocked {
            let commonCount = commonPrefixCount(previousHypothesis, hyp)
            let boundary = config.boundaryWordCount

            if commonCount > boundary {
                // Normal case: confirm everything except the last `boundary` agreed words.
                let newlyConfirmed = Array(hyp.prefix(commonCount - boundary))
                confirm(newlyConfirmed)
                let boundarySlice = Array(hyp[(commonCount - boundary)..<commonCount])
                agreementStartIndex = boundarySlice.first?.startIndex
                prefixTokens = boundarySlice.flatMap(\.tokens)
                let nextStart = agreementStartIndex ?? agreementStart
                hyp = hyp.filter { $0.startIndex >= nextStart }
            } else if commonCount == hyp.count, !hyp.isEmpty, hyp.count <= boundary {
                // Short-tail: full agreement on a prefix smaller than boundaryWordCount.
                // Confirm all but the last word to avoid stagnation at the recording tail.
                let confirmCount = hyp.count - 1
                if confirmCount > 0 {
                    confirm(Array(hyp.prefix(confirmCount)))
                }
                let boundaryWord = hyp.last!
                agreementStartIndex = boundaryWord.startIndex
                prefixTokens = boundaryWord.tokens
                hyp = hyp.filter { $0.startIndex >= boundaryWord.startIndex }
            }

            // ── Entropy gate ───────────────────────────────────────────────────────
            // Words with p ≥ singlePassThreshold need no cross-window confirmation.
            if hyp.count > boundary {
                var eagerCount = 0
                for word in hyp.prefix(hyp.count - boundary) {
                    guard word.probability >= config.singlePassThreshold else { break }
                    eagerCount += 1
                }
                if eagerCount > 0 {
                    confirm(Array(hyp.prefix(eagerCount)))
                    let newStart = hyp[eagerCount].startIndex
                    agreementStartIndex = newStart
                    prefixTokens = Array(hyp.prefix(eagerCount)).suffix(2).flatMap(\.tokens)
                    hyp = hyp.filter { $0.startIndex >= newStart }
                }
            }
        }

        // Must be AFTER the entropy gate — setting it before would cause stale prevHypothesis
        // words to mismatch on the next clip, cascading into anchor=0 every pass.
        previousHypothesis = hyp

        // ── Soft-commit ────────────────────────────────────────────────────────────
        // Once the agreement boundary is 6+ seconds past the last committed chunk,
        // promote confirmedWords to a completed chunk so the ring can be pruned.
        var softCommit: EagerSoftCommit?
        if let nextStart = agreementStartIndex,
           nextStart - lastCommittedIndex >= config.softCommitSamples,
           !confirmedWords.isEmpty {
            let text = confirmedWords.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                softCommit = EagerSoftCommit(
                    text: text,
                    startIndex: lastCommittedIndex,
                    endIndex: nextStart
                )
            }
            // Keep a short tail so the repetition guard's count survives the handoff.
            committedTail = Array((committedTail + confirmedWords).suffix(maximumRepeatRunLength * maximumConsecutiveRepeats))
            confirmedWords.removeAll()
        }

        // ── Display text ───────────────────────────────────────────────────────────
        let confirmed = confirmedWords.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let display = (confirmedWords + hyp).map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return EagerOutcome(displayText: display.isEmpty ? nil : display,
                            confirmedText: confirmed.isEmpty ? nil : confirmed,
                            softCommit: softCommit,
                            wasHeld: false,
                            holdReason: nil,
                            repeatedConfirmedTail: repeatedConfirmedTail)
    }

    // MARK: - Helpers

    /// Confirm words, refusing the ones that would extend a decoder repetition loop.
    ///
    /// Whisper occasionally falls into a loop and emits the same short phrase over and over. On
    /// the VAD path that stayed inside one chunk and was bounded by `max_tokens`. On the eager
    /// path it compounds, because LocalAgreement-2 cannot tell a stuck decoder from a person
    /// repeating themselves: two consecutive windows both emit the phrase, so it *agrees*, so it
    /// gets confirmed — and once confirmed it enters `initial_prompt` for the next pass, which
    /// primes the model to say it again. The corpus caught this on one recording where "я не
    /// знаю, что" was confirmed nine times in a row, scoring WER 0.929 against a reference that
    /// contains it once.
    ///
    /// The rule is a count, not a similarity score: a run of up to `maximumRepeatRunLength` words
    /// may be confirmed `maximumConsecutiveRepeats` times back-to-back, and an immediately
    /// following identical run is dropped. Two is deliberately permissive — real speech does say
    /// "no no" and "very very much" — while a decoder loop overshoots it on the third pass and
    /// every pass after.
    ///
    /// Only *adjacent* repeats count. The same phrase said again later in the recording has other
    /// words between, which resets the run.
    ///
    /// **Measured on two paired corpus runs (8 real recordings, guard off vs on, same audio):**
    ///
    /// | | raw mean / median WER | guarded mean / median | duplicate runs |
    /// |---|---|---|---|
    /// | run 1 — loops fired on 2 fixtures | 1.081 / 0.350 | 0.360 / 0.198 | 31.2 → 3.2 |
    /// | run 2 — no loops fired | 0.330 / 0.185 | 0.334 / 0.198 | 3.5 → 3.1 |
    ///
    /// Read the two rows together, because either alone is misleading. Run 1 says what the guard
    /// is *for*: `07642168` went 3.210 → 0.155 WER (96 duplicate runs → 4) and `5f64f423` went
    /// 3.400 → 0.682 (143 → 13). Run 2 says what it *costs*: nothing. The same eight recordings
    /// re-run produced no spiral in either arm, and the two arms tied (0.330 vs 0.334 mean, 0.185
    /// vs 0.198 median — both inside the ±0.1 single-run noise floor on this corpus), with three
    /// fixtures nominally worse by 0.013–0.033 and two nominally better by 0.018–0.021.
    ///
    /// So the spiral is **intermittent**, and a mean over one paired run cannot value this guard:
    /// on a run where it does not fire it looks like a tie, and on a run where it does it is worth
    /// three whole WER points. It is insurance against a low-frequency catastrophic mode, priced
    /// at zero in the common case. That is why it ships on.
    private mutating func confirm(_ words: [EagerStreamWord]) {
        for word in words {
            confirmedWords.append(word)
            guard config.suppressesRepetitionLoops else { continue }
            if let runLength = trailingLoopRunLength() {
                confirmedWords.removeLast(runLength)
                suppressedRepeatWords += runLength
            }
        }
    }

    /// Length of the run to drop when the confirmed tail has just become one repeat too many,
    /// or nil when it has not.
    ///
    /// Reads across `committedTail` as well as `confirmedWords`, so a soft-commit in the middle
    /// of a loop does not hide the earlier copies.
    private func trailingLoopRunLength() -> Int? {
        let tail = committedTail + confirmedWords
        let copies = maximumConsecutiveRepeats + 1
        for run in 1...maximumRepeatRunLength where tail.count >= run * copies {
            let last = tail.suffix(run).map { normalizedText($0.text) }
            guard !last.contains(where: \.isEmpty) else { continue }
            var isLoop = true
            for copy in 1..<copies {
                let start = tail.count - run * (copy + 1)
                let previous = tail[start..<(start + run)].map { normalizedText($0.text) }
                if previous != last { isLoop = false; break }
            }
            if isLoop { return run }
        }
        return nil
    }

    /// Whether the first unconfirmed word is the last confirmed word coming back a second time.
    ///
    /// Candidate mechanism for the adjacent duplicates users keep reporting ("so I won't be so I
    /// won't be able"). Hypothesis words are excluded from the unconfirmed region by
    /// `startIndex >= agreementStart`, an index test — but every pass re-cuts the window, and the
    /// decoder's word timestamps for the same audio move between cuts. A confirmed word whose new
    /// timestamp lands a few milliseconds later than the boundary passes the filter, gets
    /// confirmed again, and appears twice.
    ///
    /// The proximity test is what separates that from genuinely repeated speech: a real "very
    /// very" has two onsets a word apart, whereas the same word re-decoded sits within a few tens
    /// of milliseconds of where it already was. 0.3s is one short word.
    ///
    /// Diagnostic only — this reports, it does not filter. Whether to act on it is a question for
    /// the profile, not for a guess here.
    func leadingWordRepeatsConfirmedTail(_ hyp: [EagerStreamWord]) -> Bool {
        guard let last = confirmedWords.last, let first = hyp.first else { return false }
        let text = normalizedText(last.text)
        guard !text.isEmpty, text == normalizedText(first.text) else { return false }
        return abs(first.startIndex - last.startIndex) < Int(0.30 * 16000)
    }

    /// Number of words from the start of `prev` that agree with `curr`, compared
    /// after normalising to lowercase alphanumerics (strips punctuation and accents).
    func commonPrefixCount(_ prev: [EagerStreamWord], _ curr: [EagerStreamWord]) -> Int {
        var count = 0
        while count < prev.count, count < curr.count {
            guard !normalizedText(prev[count].text).isEmpty,
                  normalizedText(prev[count].text) == normalizedText(curr[count].text) else { break }
            count += 1
        }
        return count
    }

    private func normalizedText(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
