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
    /// The leading hypothesis words repeated the already-accounted-for tail over the same audio
    /// and were dropped before anything else ran. See `confirmedTailOverlap`.
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
        /// How far the *persisted* agreement boundary is held back behind the point the text
        /// accounts for. See `advanceAgreement(to:)` — this is the margin that keeps a word whose
        /// offset was reported late from being cut out of every subsequent window.
        let boundaryTrailSamples: Int

        static let `default` = Config(
            boundaryWordCount: 2,
            singlePassThreshold: 0.95,
            softCommitSamples: Int(6.0 * 16000),
            requiredAnchor: 2,
            maxRetraction: 3,
            skipsAnchorCheckAfterBoundaryMove: false,
            suppressesRepetitionLoops: true,
            // Off. Tried at 0.25s (≈ one short word) to fix the late-offset word loss described in
            // `advanceAgreement(to:)`, and measured on the three-repeat golden-set gate: it fixed
            // the fixture it was designed for — `B6250001` 0.140 → 0.060, the hole that motivated
            // it — and cost four others, `13B50271` 0.050 → 0.200, `8C0D8940` 0.143 → 0.314,
            // `77D9DA6A` 0.070 → 0.116, `4237CC4A` 0.200 → 0.250. Corpus mean 0.109 → 0.193.
            //
            // That is a real result, not this gate's noise: the per-fixture spreads *fell* over
            // the same run (mean eager spread 0.151 → 0.072), so the deltas clear their own error
            // bars in a way almost nothing else measured here does.
            //
            // Reading: re-presenting seam audio to the decoder is not free. The words come back,
            // but so does an unstable prefix, and re-agreeing on it costs more than the occasional
            // dropped word it rescues. Recovering those words needs a mechanism that does not
            // re-decode the seam — see the note in `advanceAgreement(to:)`. Kept as a knob rather
            // than deleted so the next attempt starts from the measurement instead of the idea.
            boundaryTrailSamples: 0
        )

        func with(skipsAnchorCheckAfterBoundaryMove: Bool? = nil,
                  suppressesRepetitionLoops: Bool? = nil) -> Config {
            Config(boundaryWordCount: boundaryWordCount, singlePassThreshold: singlePassThreshold,
                   softCommitSamples: softCommitSamples, requiredAnchor: requiredAnchor,
                   maxRetraction: maxRetraction,
                   skipsAnchorCheckAfterBoundaryMove:
                       skipsAnchorCheckAfterBoundaryMove ?? self.skipsAnchorCheckAfterBoundaryMove,
                   suppressesRepetitionLoops:
                       suppressesRepetitionLoops ?? self.suppressesRepetitionLoops,
                   boundaryTrailSamples: boundaryTrailSamples)
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

    /// Consecutive `consume` calls that moved neither the agreement boundary nor the accounted-for
    /// index. Reset by any progress, and by `seek(past:)`.
    ///
    /// The engine cannot break a stall on its own — the boundary only advances as a *result* of a
    /// decode, and whether re-presenting the window would help depends on whether the caller
    /// capped it, which only the caller knows. But the engine is the only party that can see the
    /// boundary has stopped moving, so it has to be the one to say so.
    ///
    /// What this catches, measured in production on 2026-08-20: `boundaryWordCount` is 2, so a
    /// one-word hypothesis takes the short-tail branch with `confirmCount = hyp.count - 1 = 0`.
    /// Nothing is confirmed, `confirmedThroughIndex` does not move, and `advanceAgreement(to:)`
    /// clamps the boundary to where it already was. With the window capped at `[boundary, +cap]`
    /// the same audio is presented forever: 2,429 identical 12s decodes over 40 minutes, no
    /// commit, and — because `dropFront` only runs on commit — a ring buffer that grew to the
    /// entire 41-minute meeting and became a single blocking tail decode at stop.
    ///
    /// The silent-window case has its own escape in `seek(past:)`. This covers the other half:
    /// a window that *has* speech but yields nothing the agreement algorithm will accept.
    private(set) var consecutiveStalledPasses = 0

    /// Audio index through which the text is accounted for: the end of the last word this engine
    /// either confirmed or deliberately suppressed as a repeat. The agreement boundary may never
    /// advance past it — see `advanceAgreement(to:)`.
    private var confirmedThroughIndex: Int?

    /// The agreement boundary before the trailing margin is applied: the point the text genuinely
    /// accounts for. `agreementStartIndex` is this minus `Config.boundaryTrailSamples`, and the
    /// difference is audio deliberately re-decoded to survive imprecise word offsets. Kept
    /// separately because within a pass the strict value is the correct filter — see
    /// `advanceAgreement(to:)`.
    private var strictBoundaryIndex: Int?

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
        confirmedThroughIndex = nil
        strictBoundaryIndex = sampleIndex
        suppressedRepeatWords = 0
        consecutiveStalledPasses = 0
    }

    /// Move the agreement boundary forward, refusing to step over audio no word accounts for.
    ///
    /// Every caller derives the new boundary from a *word's* `startIndex`, and that index comes
    /// from whisper's token timestamps, which are approximate — `max_len = 1` splits a segment per
    /// word and the onset it reports for the boundary word can land well after the offset of the
    /// word before it. The boundary is also the start of the next decode window, so a late
    /// timestamp does not merely mislabel a word: the span between the last accounted-for word and
    /// the boundary is cut out of every future window and is never decoded by anything.
    ///
    /// Measured on the golden-set gate: `confirmed: "with"` at base 191680 followed by base 214400
    /// — a 1.42s hole — and the words spoken in it ("the speech") are absent from the final text.
    /// Same shape on two other regressing fixtures. Clamping to `confirmedThroughIndex` costs at
    /// most a fraction of a second of re-decoded audio per pass, which the hypothesis filter and
    /// the repetition guard already handle; the alternative loses words outright.
    ///
    /// Never moves backwards: a boundary word whose timestamp lands *before* the previous boundary
    /// would otherwise re-present the same window forever.
    ///
    /// **Why clamping to the confirmed word's *end* is not enough on its own.** That end is also a
    /// whisper timestamp, and it overshoots as readily as an onset undershoots. Measured on
    /// `B6250001`, identically in all three repetitions of the gate: one pass confirmed
    /// `…why Meta is` and reported `is` ending at ~6.02s; the next decode of the same audio placed
    /// `and you extracting` at 5.82s. The words actually spoken in between — `not meeting. And` —
    /// end before 6.02s, so the entry filter (`startIndex >= agreementStart`) discarded them
    /// from that window and every window after it. They are absent from the final text while the
    /// baseline arm keeps them, and that single hole is the whole +0.080 WER regression on the one
    /// fixture whose delta exceeded its own spread.
    ///
    /// `boundaryTrailSamples` holds the persisted boundary back behind the accounted-for point so
    /// those words stay inside the next window. **It is 0 by default — the idea was measured and
    /// it lost.** It recovers the dropped words and costs more elsewhere than it saves; the
    /// numbers are on `Config.default`. Read them before turning it back on.
    ///
    /// What the measurement says about a future fix: the loss is real and worth about 0.08 WER on
    /// an affected fixture, but re-decoding the seam is the wrong way to buy it back, because the
    /// re-presented prefix has to be re-agreed and that is less stable than the hole. A mechanism
    /// that recovers the words *without* moving the decode window — carrying the previous pass's
    /// unconfirmed tail forward as text rather than re-deriving it from audio — has not been tried.
    ///
    /// Returns the **strict** (untrailed) boundary. Callers filter *this pass's* hypothesis with
    /// the return value, never with `agreementStartIndex`: the trailing boundary sits behind words
    /// just confirmed, so filtering by it would leave them in `hyp` for the entropy gate to confirm
    /// a second time — a duplicate manufactured inside a single pass.
    @discardableResult
    private mutating func advanceAgreement(to index: Int) -> Int {
        let clamped = confirmedThroughIndex.map { min(index, $0) } ?? index
        let strict = max(clamped, strictBoundaryIndex ?? clamped)
        strictBoundaryIndex = strict
        let trailed = max(strict - config.boundaryTrailSamples, 0)
        agreementStartIndex = max(trailed, agreementStartIndex ?? trailed)
        return strict
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
        // No trailing margin here, unlike `advanceAgreement(to:)`: the margin exists to re-decode
        // audio whose word offsets may be wrong, and this span was proven to contain no words.
        strictBoundaryIndex = max(strictBoundaryIndex ?? sampleIndex, sampleIndex)
        // The skipped span is accounted for — it was proven silent. Without this the clamp in
        // `advanceAgreement(to:)` would keep measuring from a word before the skip and pin the
        // boundary here for the rest of the recording.
        confirmedThroughIndex = max(confirmedThroughIndex ?? sampleIndex, sampleIndex)
        previousHypothesis.removeAll()
        prefixTokens.removeAll()
        // The caller took the escape hatch: the next window is audio this engine has never seen,
        // so whatever pinned the boundary is behind us.
        consecutiveStalledPasses = 0
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

        // Liveness accounting, on every exit path including the early returns — a pass that bailed
        // on an empty hypothesis or an anchor hold made no progress either, and those are exactly
        // the passes that alternate with the productive-looking ones in a stall. See
        // `consecutiveStalledPasses`. Both indices are checked because either one moving means the
        // next window will differ: `strictBoundaryIndex` re-cuts it, `confirmedThroughIndex`
        // unpins the clamp in `advanceAgreement(to:)` so a later pass can.
        let boundaryOnEntry = strictBoundaryIndex
        let accountedOnEntry = confirmedThroughIndex
        defer {
            if strictBoundaryIndex == boundaryOnEntry && confirmedThroughIndex == accountedOnEntry {
                consecutiveStalledPasses += 1
            } else {
                consecutiveStalledPasses = 0
            }
        }

        // Filter the hypothesis to the unconfirmed region — by **overlap**, not onset.
        //
        // `endIndex > agreementStart`, not `startIndex >= agreementStart`. The caller opens each
        // window `eagerSeamMarginSeconds` early, so the boundary word is re-decoded with left
        // context; a `startIndex` filter throws that word away again and the boundary stops
        // advancing. Measured on real dictation: with the `startIndex` filter, stop-time preview
        // reuse fell to 0 of 3 and the median uncovered gap went 0.64s → 1.60s, past the 0.40s
        // reuse ceiling, so every stop paid a full tail decode instead of pasting instantly.
        //
        // The cost: an overlap filter gives up the *structural* guarantee that a word whose audio
        // is already accounted for cannot re-enter, so `confirmedTailOverlap` below is the only
        // defense against a duplicate when the decoder renders the re-cut seam as different text.
        // That is the trade the seam margin buys, and it is the one the measurement says to take —
        // `confirmedTailOverlap` catches the common case, and a rare duplicated boundary word is
        // a far smaller regression than every single stop paying an 856 ms tail decode.
        var hyp = hypothesis.filter { $0.endIndex > agreementStart }
        guard !hyp.isEmpty else {
            return EagerOutcome(displayText: nil, confirmedText: nil, softCommit: nil,
                                wasHeld: false, holdReason: nil, repeatedConfirmedTail: false)
        }
        // Drop words this engine has already accounted for and is only seeing again because the
        // seam was re-decoded. Done before the anchor guard so `previousHypothesis` is stored
        // deduplicated too — otherwise the next window compares against a prefix that no longer
        // exists and reads as an unanchored collapse.
        let overlap = confirmedTailOverlap(hyp, boundary: agreementStart)
        let repeatedConfirmedTail = overlap > 0
        if overlap > 0 {
            hyp.removeFirst(overlap)
            guard !hyp.isEmpty else {
                return EagerOutcome(displayText: nil, confirmedText: nil, softCommit: nil,
                                    wasHeld: false, holdReason: nil, repeatedConfirmedTail: true)
            }
        }

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
                var strict = strictBoundaryIndex ?? agreementStart
                if let start = boundarySlice.first?.startIndex { strict = advanceAgreement(to: start) }
                prefixTokens = boundarySlice.flatMap(\.tokens)
                hyp = hyp.filter { $0.startIndex >= strict }
            } else if commonCount == hyp.count, !hyp.isEmpty, hyp.count <= boundary {
                // Short-tail: full agreement on a prefix smaller than boundaryWordCount.
                // Confirm all but the last word to avoid stagnation at the recording tail.
                let confirmCount = hyp.count - 1
                if confirmCount > 0 {
                    confirm(Array(hyp.prefix(confirmCount)))
                }
                let boundaryWord = hyp.last!
                let strict = advanceAgreement(to: boundaryWord.startIndex)
                prefixTokens = boundaryWord.tokens
                hyp = hyp.filter { $0.startIndex >= strict }
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
                    let strict = advanceAgreement(to: hyp[eagerCount].startIndex)
                    prefixTokens = Array(hyp.prefix(eagerCount)).suffix(2).flatMap(\.tokens)
                    hyp = hyp.filter { $0.startIndex >= strict }
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
            // Advanced for suppressed words too: a dropped repeat is a decision about that audio,
            // not a reason to decode it again. Leaving it behind would pin the boundary — see
            // `advanceAgreement(to:)`.
            confirmedThroughIndex = max(confirmedThroughIndex ?? word.endIndex, word.endIndex)
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
    /// The profile has since answered that question, so `consume` now drops the overlap rather
    /// than only counting it. `advanceAgreement(to:)` clamps the boundary back to the end of the
    /// last accounted-for word, which means the next window *deliberately* re-decodes the audio
    /// around the seam — re-emitting the boundary words is no longer an occasional timestamp
    /// accident but the expected case. Six of eight golden-set fixtures showed it in one run:
    /// "Yes, but now ⟨Now⟩ you're targeting", "Let's do ⟨Let's do⟩ this", "because and like
    /// writing ⟨writing⟩ it down".
    ///
    /// Returns how many leading hypothesis words repeat the accounted-for tail, 0 for none.
    ///
    /// Matching runs up to four words because the observed repeats are phrases, not single words —
    /// a one-word test misses "Let's do | Let's do this" entirely, since the last confirmed word
    /// ("do") and the first hypothesis word ("Let's") differ. It reads across `committedTail` so a
    /// soft-commit in the middle of the seam does not hide the copy that was just handed off.
    ///
    /// Something has to separate this from genuinely repeated speech ("no no", "very very"), and
    /// two things do. Either the repeat sits in the re-decoded run-up — it starts at or before the
    /// agreement boundary, so its audio is by definition audio already accounted for — or it sits
    /// within 0.3s of where the matching word already was, which is timestamp drift on a re-cut
    /// window rather than a second utterance. A real repeat satisfies neither: it comes after the
    /// boundary and a word-length or more later.
    ///
    /// The drift window is 0.3s and not 0.5s, which it was briefly widened to in the same change
    /// that made this function *delete* rather than count. 0.5s is roughly two short words at
    /// conversational rate, so it swallowed real speech: in "no, no, I didn't" with the second
    /// "no" 0.35s after the first, the second "no" matched run 1, passed the drift test, and was
    /// removed at the `removeFirst` below — deleted outright, ~170 lines before the repetition
    /// guard that deliberately permits two consecutive repeats ever saw it. Worse, the shortened
    /// hypothesis then failed the anchor check, so the pass was held too: one lost word *and* one
    /// discarded decode, on an utterance shape people produce constantly.
    func confirmedTailOverlap(_ hyp: [EagerStreamWord], boundary: Int) -> Int {
        let tail = committedTail + confirmedWords
        guard let first = hyp.first, !tail.isEmpty else { return 0 }
        for run in stride(from: min(4, min(tail.count, hyp.count)), through: 1, by: -1) {
            let previous = tail.suffix(run).map { normalizedText($0.text) }
            let candidate = hyp.prefix(run).map { normalizedText($0.text) }
            guard previous == candidate, !previous.contains(where: \.isEmpty) else { continue }
            let anchor = tail[tail.count - run]
            let isReDecodedRunUp = first.startIndex <= boundary
            let isDrift = abs(first.startIndex - anchor.startIndex) < Int(0.50 * 16000)
            guard isReDecodedRunUp || isDrift else { continue }
            return run
        }
        return 0
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
