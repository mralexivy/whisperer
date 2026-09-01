//
//  CorrectionPromotion.swift
//  Whisperer
//
//  Decides whether an observed correction may become a dictionary entry, and at what tier.
//
//  Calibrated against the real corpus, not invented. Replaying the candidate miner over 1,779
//  dictations produced both the pairs worth learning (`Glyn → Glean`, used 105 times) and pairs
//  that would be destructive to apply (`backend → firebase`, `teams → Antti`, `the → our` — the
//  user rewriting a thought, not the recogniser mishearing a word). The same replay also showed
//  that counting repeats is useless: across the whole corpus, *zero* candidate pairs recur even
//  twice. Evidence has to come from the shape of the pair itself, not from its frequency.
//
//  Three gates separate them, and all three must hold to auto-apply:
//
//    1. The observed form is at least 4 characters. Below that the spell checker cannot judge it
//       (NSSpellChecker is only consulted for words of 4+), and a short rewrite does the most
//       collateral damage — `fan → FN` would fire on every "fan" ever dictated.
//    2. The observed form is not a valid English word. This is what stops `the → our`.
//    3. The pair is phonetically equal. This is what stops `backend → firebase`: a mishearing
//       sounds like what was said, a rewrite does not.
//
//  Anything that fails a gate but is otherwise well-formed becomes a *suggestion* — one click in
//  a list, still far less work than authoring the entry by hand. Anything malformed is rejected
//  outright and never shown.
//

import Foundation

enum CorrectionPromotionTier: Equatable, Sendable {
    /// Promote now, tell the user, offer Undo.
    case automatic
    /// Offer in the review list; never applied until the user confirms.
    case suggestion
    /// Not learnable at all. `reason` is for logging, not for the user.
    case rejected(CorrectionPromotionRejection)
}

enum CorrectionPromotionRejection: String, Equatable, Sendable {
    case identical
    case tooShort
    case notASingleWord
    case scriptMismatch
    case tombstoned
}

enum CorrectionPromotion {
    /// Shortest observed form we will auto-apply. `SpellValidator.isValidEnglishWord` returns
    /// false for anything shorter without consulting the spell checker, so gate 2 would be
    /// vacuously true and ordinary short words like "fan" and "SI" would auto-promote.
    static let minimumObservedLengthForAutomatic = 4
    /// Shortest form we will store at all, in either direction.
    static let minimumLength = 2

    /// Held for the process lifetime. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` gives
    /// `PhoneticMatcher` a synthesized isolated deinit, which aborts the host if it is
    /// deallocated from a synchronous test method. A `static let` is never released.
    private static let phonetics = PhoneticMatcher()
    private static let spelling = SpellValidator.shared

    /// - Parameter tombstones: observed forms the user has already rejected. A tombstoned pair is
    ///   never relearned — re-adding what the user just deleted is the most infuriating possible
    ///   failure of a learner.
    static func evaluate(
        observed: String,
        corrected: String,
        tombstones: Set<String> = []
    ) -> CorrectionPromotionTier {
        let observedKey = observed.lowercased()
        let correctedKey = corrected.lowercased()

        guard observedKey != correctedKey else { return .rejected(.identical) }
        guard observed.count >= minimumLength, corrected.count >= minimumLength else {
            return .rejected(.tooShort)
        }
        guard isSingleWord(observed), isSingleWord(corrected) else {
            return .rejected(.notASingleWord)
        }
        guard !isPurelyNumeric(observed), !isPurelyNumeric(corrected) else {
            return .rejected(.notASingleWord)
        }
        guard scriptFamilies(in: observed) == scriptFamilies(in: corrected) else {
            return .rejected(.scriptMismatch)
        }
        guard !tombstones.contains(observedKey) else { return .rejected(.tombstoned) }

        guard observed.count >= minimumObservedLengthForAutomatic else { return .suggestion }
        guard !spelling.isValidEnglishWord(observedKey) else { return .suggestion }
        guard soundsAlike(observedKey, correctedKey) else { return .suggestion }

        return .automatic
    }

    /// Soundex equality. Chosen over metaphone because it is what the measured pairs agree on:
    /// `Glyn`/`Glean` and `ORCID`/`Orkit` match, while `backend`/`firebase`, `teams`/`Antti`,
    /// `KVEN`/`QwEN` and `YouTube`/`YT` do not.
    private static func soundsAlike(_ lhs: String, _ rhs: String) -> Bool {
        let lhsCode = phonetics.soundex(lhs)
        let rhsCode = phonetics.soundex(rhs)
        guard !lhsCode.isEmpty, !rhsCode.isEmpty else { return false }
        return lhsCode == rhsCode
    }

    private static func isSingleWord(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" || $0 == "-" }
    }

    private static func isPurelyNumeric(_ text: String) -> Bool {
        text.allSatisfy { $0.isNumber }
    }

    private static func scriptFamilies(in text: String) -> Set<String> {
        Set(text.unicodeScalars.compactMap { scalar in
            guard CharacterSet.letters.contains(scalar) else { return nil }
            switch scalar.value {
            case 0x0590...0x05FF: return "hebrew"
            case 0x0400...0x052F: return "cyrillic"
            case 0x0600...0x06FF: return "arabic"
            case 0x4E00...0x9FFF: return "han"
            default: return "latin-other"
            }
        })
    }
}

// MARK: - Tombstones

/// Observed forms the user has rejected, so the learner never proposes them again.
///
/// Deliberately keyed on the observed form alone, not the pair. If the user deleted
/// `glyn → Glean`, re-proposing `glyn → Gleen` next week is the same annoyance wearing a hat.
actor CorrectionTombstoneStore {
    static let shared = CorrectionTombstoneStore()

    private let fileURL: URL
    private var loaded = false
    private var observedForms: Set<String> = []

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Whisperer", isDirectory: true)
            self.fileURL = base.appendingPathComponent("correction-tombstones.json")
        }
    }

    func all() -> Set<String> {
        loadIfNeeded()
        return observedForms
    }

    func contains(_ observed: String) -> Bool {
        loadIfNeeded()
        return observedForms.contains(observed.lowercased())
    }

    func add(_ observed: String) {
        loadIfNeeded()
        guard observedForms.insert(observed.lowercased()).inserted else { return }
        persist()
    }

    func removeAll() {
        loaded = true
        observedForms = []
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            Logger.error("Failed to clear correction tombstones: \(error.localizedDescription)", subsystem: .app)
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) else { return }
        observedForms = decoded
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(observedForms).write(to: fileURL, options: .atomic)
        } catch {
            Logger.error("Failed to persist correction tombstones: \(error.localizedDescription)", subsystem: .app)
        }
    }
}
