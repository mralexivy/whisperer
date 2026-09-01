//
//  CorrectionLearningService.swift
//  Whisperer
//
//  The one place an observed correction becomes a dictionary entry.
//
//  Every learning source — a History edit, the correction popover, the post-paste AX observer —
//  funnels through `observe(original:edited:source:)`. Keeping the pipeline single means the
//  gates in `CorrectionPromotion` cannot be bypassed by adding a source later.
//
//  Pipeline: mine isolated 1:1 substitutions → evaluate each against the promotion gates →
//  tier 1 becomes a dictionary entry now, tier 2 becomes a suggestion, everything else is dropped.
//

import Foundation

enum CorrectionLearningSource: String, Sendable {
    case historyEdit
    case correctionPopover
    case pastePostEdit
}

/// What a single observation produced, so the caller can show the user what happened.
struct CorrectionLearningOutcome: Sendable {
    /// Corrected forms promoted to the dictionary during this observation, in mining order.
    var learned: [DictionaryEntry] = []
    /// Pairs added to the review list instead.
    var suggested: [CorrectionLearningCandidate] = []

    var isEmpty: Bool { learned.isEmpty && suggested.isEmpty }
}

@MainActor
enum CorrectionLearningService {
    /// Ceiling on auto-learned entries. A learner with no bound eventually owns the dictionary;
    /// past this point the least recently used auto-learned entry is evicted before a new one
    /// lands. Hand-authored and built-in entries are never touched.
    static let maximumAutoLearnedEntries = 200

    @discardableResult
    static func observe(
        original: String,
        edited: String,
        source: CorrectionLearningSource
    ) async -> CorrectionLearningOutcome {
        let manager = DictionaryManager.shared
        guard manager.correctionLearningEnabled else { return CorrectionLearningOutcome() }

        let candidates = CorrectionLearningCandidateExtractor.extract(from: original, edited: edited)
        guard !candidates.isEmpty else { return CorrectionLearningOutcome() }

        let tombstones = await CorrectionTombstoneStore.shared.all()
        var outcome = CorrectionLearningOutcome()

        for candidate in candidates {
            switch CorrectionPromotion.evaluate(
                observed: candidate.observed,
                corrected: candidate.corrected,
                tombstones: tombstones
            ) {
            case .automatic:
                if let entry = await promote(candidate, source: source, manager: manager) {
                    outcome.learned.append(entry)
                }
            case .suggestion:
                await CorrectionSuggestionStore.shared.record(candidate.observed, candidate.corrected)
                outcome.suggested.append(candidate)
            case .rejected(let reason):
                Logger.debug(
                    "Correction candidate rejected (\(reason.rawValue)): \(candidate.observed) → \(candidate.corrected)",
                    subsystem: .app
                )
            }
        }

        if !outcome.isEmpty {
            Logger.event(.dictLearn, .app, [
                "source": .string(source.rawValue),
                "learned": .int(outcome.learned.count),
                "suggested": .int(outcome.suggested.count)
            ])
        }
        return outcome
    }

    /// Removes an auto-learned entry and tombstones it so it is never relearned.
    static func undo(_ entry: DictionaryEntry) async {
        guard let observed = entry.observedSource else { return }
        await CorrectionTombstoneStore.shared.add(observed)
        do {
            try await DictionaryManager.shared.deleteEntry(entry)
        } catch {
            Logger.error("Failed to undo auto-learned entry: \(error.localizedDescription)", subsystem: .app)
        }
    }

    /// Confirms an auto-learned entry: clears its provenance so it behaves as a hand-authored
    /// entry and joins the fuzzy indexes.
    static func confirm(_ entry: DictionaryEntry) async {
        guard entry.isAutoLearned else { return }
        do {
            try await DictionaryManager.shared.clearAutoLearnedProvenance(entry)
        } catch {
            Logger.error("Failed to confirm auto-learned entry: \(error.localizedDescription)", subsystem: .app)
        }
    }

    // MARK: - Private

    private static func promote(
        _ candidate: CorrectionLearningCandidate,
        source: CorrectionLearningSource,
        manager: DictionaryManager
    ) async -> DictionaryEntry? {
        // Never shadow an entry that already exists — a hand-authored rule outranks a learned one.
        let observedKey = candidate.observed.lowercased()
        guard !manager.entries.contains(where: { $0.incorrectForm == observedKey }) else { return nil }

        await evictIfNeeded(manager: manager)

        let entry = DictionaryEntry(
            incorrectForm: candidate.observed,
            correctForm: candidate.corrected,
            category: "Learned",
            notes: "Learned from \(source.rawValue)",
            observedSource: candidate.observed
        )
        do {
            try await manager.addEntry(entry)
            return entry
        } catch {
            Logger.error("Failed to promote learned correction: \(error.localizedDescription)", subsystem: .app)
            return nil
        }
    }

    private static func evictIfNeeded(manager: DictionaryManager) async {
        let autoLearned = manager.entries.filter { $0.isAutoLearned }
        guard autoLearned.count >= maximumAutoLearnedEntries else { return }
        // Least used first, oldest as the tie-break. No tombstone: eviction is our decision, not
        // the user's rejection, so the term may legitimately be learned again later.
        let victims = autoLearned
            .sorted { ($0.useCount, $0.lastModifiedAt) < ($1.useCount, $1.lastModifiedAt) }
            .prefix(autoLearned.count - maximumAutoLearnedEntries + 1)
        for victim in victims {
            try? await manager.deleteEntry(victim)
        }
    }
}
