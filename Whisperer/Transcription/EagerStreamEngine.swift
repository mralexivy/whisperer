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

struct EagerOutcome {
    /// Text to show in the live overlay. `nil` = suppress this pass (unstable revision).
    let displayText: String?
    /// Present when 6+ seconds of agreed audio has accumulated — caller must append to
    /// completedChunkTexts, fire onChunkCompleted, advance lastTranscribedSampleIndex,
    /// and prune the ring.
    let softCommit: EagerSoftCommit?
    /// `true` when this pass is a large retraction that was held for one more window
    /// before the caller sees a nil displayText.
    let wasHeld: Bool
}

// MARK: - EagerStreamEngine

final class EagerStreamEngine: @unchecked Sendable {

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

        static let `default` = Config(
            boundaryWordCount: 2,
            singlePassThreshold: 0.95,
            softCommitSamples: Int(6.0 * 16000),
            requiredAnchor: 2,
            maxRetraction: 3
        )
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

    init(config: Config = .default) {
        self.config = config
    }

    // Explicit nonisolated deinit prevents Swift 6 from emitting
    // swift_task_deinitOnExecutorImpl for this class when it's released from a
    // @MainActor context (e.g., XCTestCase). The engine is pure computation on a
    // serial queue and is safe to dealloc on any thread.
    nonisolated deinit {}

    func reset(at sampleIndex: Int) {
        confirmedWords.removeAll()
        previousHypothesis.removeAll()
        agreementStartIndex = sampleIndex
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
    func consume(
        hypothesis: [EagerStreamWord],
        audioBaseIndex: Int,
        languageIsLocked: Bool,
        lastCommittedIndex: Int
    ) -> EagerOutcome {
        let agreementStart = agreementStartIndex ?? audioBaseIndex

        // Filter hypothesis to the unconfirmed region (past the agreement boundary)
        var hyp = hypothesis.filter { $0.startIndex >= agreementStart }
        guard !hyp.isEmpty else { return EagerOutcome(displayText: nil, softCommit: nil, wasHeld: false) }

        // ── Anchor / retraction guard ──────────────────────────────────────────────
        // A genuine correction aligns with the previous window on at least requiredAnchor
        // words. A transient decoder collapse does not — hold it for one more window.
        if !previousHypothesis.isEmpty {
            let commonCount = commonPrefixCount(previousHypothesis, hyp)
            let requiredAnchor = min(config.requiredAnchor, min(previousHypothesis.count, hyp.count))
            let lostWordCount = previousHypothesis.count - hyp.count
            let isUnanchored = commonCount < requiredAnchor
            let isLargeRetraction = lostWordCount > config.maxRetraction
            if isUnanchored || isLargeRetraction {
                // Hold — update previousHypothesis so the next window sees the new baseline.
                previousHypothesis = hyp
                return EagerOutcome(displayText: nil, softCommit: nil, wasHeld: true)
            }
        }

        // ── LocalAgreement-2 confirmation ─────────────────────────────────────────
        if languageIsLocked {
            let commonCount = commonPrefixCount(previousHypothesis, hyp)
            let boundary = config.boundaryWordCount

            if commonCount > boundary {
                // Normal case: confirm everything except the last `boundary` agreed words.
                let newlyConfirmed = Array(hyp.prefix(commonCount - boundary))
                confirmedWords.append(contentsOf: newlyConfirmed)
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
                    confirmedWords.append(contentsOf: hyp.prefix(confirmCount))
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
                    confirmedWords.append(contentsOf: hyp.prefix(eagerCount))
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
            confirmedWords.removeAll()
        }

        // ── Display text ───────────────────────────────────────────────────────────
        let allWords = confirmedWords + hyp
        let display = allWords.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText: String? = display.isEmpty ? nil : display

        return EagerOutcome(displayText: displayText, softCommit: softCommit, wasHeld: false)
    }

    // MARK: - Helpers

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
