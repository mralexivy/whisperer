//
//  ConfidenceGate.swift
//  Whisperer
//
//  The single place an edit is allowed to happen.
//
//  `TranscriptPostValidator` already checks script, growth, shrink and number preservation — but
//  on the whole output, after the fact, and its only verdict is accept-or-discard-everything. One
//  bad edit in forty therefore costs the other thirty-nine. This judges each edit on its own, so
//  the failure mode is a missed correction rather than a discarded transcript.
//
//  **Stated versus inferred.** The gate's organizing distinction is not how confident a source
//  is, it is whether the source is *asserting* or *guessing*:
//
//  - **Stated** — an alias the user typed, a filler in an explicit vocabulary, a whitespace run.
//    Someone wrote this rule down. It may edit a soft-protected token and it may cross scripts,
//    because `קוברנטיס → Kubernetes` is a dictionary entry, not a translation.
//  - **Inferred** — an editing model, an LLM. It faces every guard: no soft-protected tokens, no
//    script changes, no comma / semicolon / colon insertion at all, and a threshold set by what
//    the edit can do to the meaning rather than by which source proposed it.
//
//  **The floor is tiered, not flat.** A single bar for every operation an editor can emit reads
//  as caution and is really a category error: the 0.99 gate is an argument about word
//  substitution — `don't deploy` → `deploy` — and a sentence-final period cannot change meaning
//  at all. See `EditClass` and `floor(for:operation:originalText:language:)`; every number there
//  cites the cell in `Tools/mmbert/CALIBRATION.md` that licenses it, and substitution is
//  untouched at 0.99.
//
//  Hard protection and `.userFinal` are not checked here at all. `TokenGraph.apply` enforces them
//  structurally, so they hold even against a caller that never consulted this type — which is the
//  point of putting them there instead of here.
//
//  **Evidence.** Nothing in this gate reads `asrProbability`, `audioStart` or `asrTokens`. That is
//  deliberate and it is testable: it is what makes the `ASRCapabilities = []` column identical to
//  the full-evidence column, and therefore what makes the M2 pipeline behave the same behind
//  Nemotron as behind whisper.cpp. `requireAcousticSupport` is the seam where an acoustic term
//  will enter later — as an additional *conjunct*, never as a replacement for a text threshold, so
//  a token with no probability can never be edited on weaker grounds than one that has it.
//

import Foundation

struct ConfidenceGate: Sendable {

    // MARK: - Verdict

    enum Verdict: Sendable, Equatable {
        case accept
        /// The edit does not apply, and the original text stands. Uncertainty preserves the input.
        case keep(reason: String)

        var isAccepted: Bool { self == .accept }
    }

    // MARK: - Policy

    /// Minimum confidence per source, before any margin.
    ///
    /// The source-level default. `floor(for:operation:originalText:language:)` refines it for the
    /// editor model, where the risk of an edit varies by orders of magnitude *within* the source;
    /// every other source is judged on this number alone.
    static func floor(for source: EditSource) -> Float {
        switch source {
        case .alias:          return 0.75   // admits a learned alias (0.80); a shipped one is 0.95
        case .filler:         return 0.85
        case .normalization:  return 0.90
        case .listFormatting: return 0.90
        // The cosmetic tier, reached by the source rather than by `editClass`: this source emits
        // exactly one operation — inserting `.` — so what the edit can do is fixed at the source
        // and 0.95 is the same bar `floor(for:operation:originalText:language:)` sets for a
        // cosmetic edit from the model. Higher than `.normalization` because a mark the speaker
        // did not pause for is visible, and lower than an inferred source because a measured
        // silence is evidence rather than a guess.
        case .acousticBoundary: return 0.95
        case .editorModel:    return 0.99
        case .llm:            return 0.99
        }
    }

    // MARK: - Risk tiers

    /// What an edit can do to the *meaning* of the sentence — the only thing a floor should be a
    /// function of.
    ///
    /// One flat bar for every operation a model can emit is a category error. "Turning
    /// `don't deploy` into `deploy` is catastrophic" is an argument about word substitution; it is
    /// not an argument about a sentence-final period, which cannot change meaning at all. The
    /// worst case of a wrong period is a mark the user reads and ignores.
    enum EditClass: Sendable, Equatable {
        /// Rewrites a word into a different word, or removes a token that is not a disfluency.
        /// Can destroy meaning, so it keeps the full 0.99 bar.
        case substitution
        /// Removes one filler token. Bounded blast radius: one word the user did not mean to say.
        case fillerDeletion
        /// Inserts a punctuation mark, or changes the case of a token without changing its
        /// letters. Cannot change meaning; cosmetic only.
        case cosmetic
    }

    /// Which tier an operation falls in, computed from the text.
    ///
    /// Computed rather than taken from `TranscriptEdit.reason`, which is a human-readable string a
    /// model author controls. "This is only a recasing" has to be *checked* — a `.replace` that
    /// claims to be a case transform and is not is precisely the substitution this gate exists to
    /// stop. Anything unrecognized is a substitution: the strictest tier is the default.
    static func editClass(of operation: EditOperation, originalText: String) -> EditClass {
        switch operation {
        case .keep:
            return .substitution
        case .insertAfter(let text):
            return isPunctuationOnly(text) ? .cosmetic : .substitution
        case .replace(let text):
            return isCaseTransform(from: originalText, to: text) ? .cosmetic : .substitution
        case .delete:
            return fillers.contains(fold(originalText)) ? .fillerDeletion : .substitution
        }
    }

    /// Same letters, different case. `deploy → Deploy` is cosmetic; `deploy → destroy` is not.
    private static func isCaseTransform(from original: String, to replacement: String) -> Bool {
        original.lowercased() == replacement.lowercased()
    }

    private static func isPunctuationOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    /// Marks no inferred source may insert, at any confidence, ever.
    ///
    /// A deny-list rather than a threshold, because the measurement says the model is not merely
    /// under-confident here — it is wrong. On `pooled_indomain` (`Tools/mmbert/CALIBRATION.md`
    /// §2) en/punct `,` measures P = 0.6720 with **41 wrong edits out of 125**, its best operating
    /// point at any threshold. Semicolons and colons are worse than measurable: on the held-out
    /// golden-set split the model proposed 17 semicolons and 8 colons where the gold had zero of
    /// either — **25 proposals, 25 of them wrong** (§5). A future threshold change must not be
    /// able to re-enable that silently, so it is refused by construction and not by number.
    ///
    /// `ru/punct ,` does measure P = 1.0000 at n = 34 (LCB95 0.9157), and this list blocks it too.
    /// That is the intended trade: one plausible cell lost, one demonstrated failure mode closed.
    static let deniedInsertions: Set<String> = [",", ";", ":", "،", "؛"]

    /// Floor for one edit, refined by what the edit can actually do.
    ///
    /// Only `.editorModel` is tiered, and only in a language whose per-class precision has been
    /// measured. Every other source, and every unmeasured language, gets `floor(for:)` unchanged.
    ///
    /// The three numbers, each traceable to `Tools/mmbert/CALIBRATION.md` §2 (`pooled_indomain`,
    /// the primary calibration set):
    ///
    /// - **0.99, substitution.** No cell certifies this and none comes close: the best 95% lower
    ///   bound achieved by *any* cell on in-domain data is 0.9693. Unchanged from before this
    ///   tiering existed, which is the point — nothing here makes a word substitution easier to
    ///   apply than it was.
    /// - **0.97, filler deletion.** en/disf measures P = 1.0000 with 0 wrong edits out of 57
    ///   proposals, LCB95 = 0.9488 — the weakest lower bound of the three well-behaved English
    ///   cells, so it gets the stricter of the two relaxed tiers. A wrong delete costs one word.
    /// - **0.95, cosmetic.** en/punct `.` measures P = 1.0000, 0 wrong out of 88, LCB95 = 0.9665;
    ///   en/case ALL measures P = 1.0000, 0 wrong out of 96, LCB95 = 0.9693 — the highest lower
    ///   bound of any cell measured. 0.95 is the round number both lower bounds clear. These two
    ///   classes are blocked at 0.99 only because 88 and 96 perfect events cannot *statistically*
    ///   certify 0.99 (that needs ~299 consecutive correct proposals), not because a wrong one
    ///   would cost anything but a mark on screen.
    static func floor(for source: EditSource,
                      operation: EditOperation,
                      originalText: String,
                      language: TranscriptionLanguage?) -> Float {
        let base = floor(for: source)
        guard source == .editorModel,
              let language, calibratedLanguages.contains(language) else { return base }

        switch editClass(of: operation, originalText: originalText) {
        case .substitution:   return base
        case .fillerDeletion: return 0.97
        case .cosmetic:       return 0.95
        }
    }

    /// Languages whose per-class precision has actually been measured on in-domain data.
    ///
    /// English only. `CALIBRATION.md` §3 is explicit that the real-ASR split holds 2 Hebrew and 2
    /// Russian documents — 162 and 67 words — and that those languages "should be treated as
    /// unmeasured, not as measured-and-bad". An unmeasured language therefore gets no relaxation:
    /// absence of evidence is not evidence the edit is cosmetic *for that language*, and
    /// he/punct ALL measures P = 0.1364 on what little there is.
    static let calibratedLanguages: Set<TranscriptionLanguage> = [.english]

    /// Whether a source asserts a rule someone wrote down, or guesses.
    static func isStated(_ source: EditSource) -> Bool {
        switch source {
        // `.acousticBoundary` is stated, not inferred: the rule is "a measured silence ends a
        // sentence", written down in `SentenceTerminator`, and the silence is a number our own VAD
        // produced rather than a model's opinion about prosody. The practical consequence is that
        // it may close a sentence after a soft-protected token — a suspected name is a very
        // ordinary last word of a sentence, and refusing there would cost recall for no
        // corresponding risk, since the only operation this source emits is inserting `.`.
        case .alias, .filler, .normalization, .listFormatting, .acousticBoundary: return true
        case .editorModel, .llm: return false
        }
    }

    /// Tokens whose deletion is a filler deletion rather than a substitution.
    ///
    /// Deliberately a short, closed list of words that are never a content word in any language
    /// the app polishes — the same standard as `TranscriptNormalizer.hardFillers`, restated here
    /// rather than shared so that widening the normalizer's vocabulary cannot silently widen what
    /// the gate treats as low-risk. Anything not on it is a substitution-tier delete, including
    /// `like`, `типа` and `כאילו`, which are content words often enough that deleting one is a
    /// change of meaning.
    private static let fillers: Set<String> = [
        // English
        "uh", "um", "uhm", "erm", "hmm", "hm", "mmm", "er", "ah",
        // Hebrew
        "אמ", "אהה", "אממ", "אמם",
        // Russian
        "эм", "ммм", "эээ", "мм",
    ]

    /// Reserved for M3+. Off here so that this gate is provably evidence-blind.
    let requireAcousticSupport: Bool

    /// Which language the text is in, when routing has decided. `nil` means unknown, and unknown
    /// is treated as unmeasured: no tier is relaxed. Never defaulted to English.
    let language: TranscriptionLanguage?

    init(requireAcousticSupport: Bool = false, language: TranscriptionLanguage? = nil) {
        self.requireAcousticSupport = requireAcousticSupport
        self.language = language
    }

    // MARK: - Judging

    func judge(_ edit: TranscriptEdit, in graph: TokenGraph) -> Verdict {
        guard !edit.operation.isNoOp else { return .keep(reason: "no-op") }
        guard let token = graph.token(edit.target) else {
            return .keep(reason: "target no longer in graph")
        }

        // Restated rather than delegated: `TokenGraph.apply` enforces these structurally, but a
        // gate that silently accepted an edit the graph would refuse would report a decision it
        // did not make.
        if token.protection == .hard { return .keep(reason: "hard-protected span") }
        if token.lifecycle == .userFinal { return .keep(reason: "user-final token") }

        // Before any number: the marks the model is measured to get wrong are refused outright,
        // so no threshold change can re-admit them.
        if let reason = deniedInsertion(edit) { return .keep(reason: reason) }

        let floor = Self.floor(for: edit.source,
                               operation: edit.operation,
                               originalText: token.effectiveText,
                               language: language)
        if edit.confidence < floor {
            return .keep(reason: String(format: "confidence %.2f below %.2f floor for %@ (%@)",
                                        edit.confidence, floor, edit.source.rawValue,
                                        String(describing: Self.editClass(
                                            of: edit.operation,
                                            originalText: token.effectiveText))))
        }

        if let reason = negationViolation(edit, token: token) { return .keep(reason: reason) }
        if let reason = numberViolation(edit, token: token) { return .keep(reason: reason) }

        if !Self.isStated(edit.source) {
            // Soft protection is exactly the "this might be a name, or a foreign term, or
            // something I do not recognize" signal. A model is the thing it exists to stop.
            if token.protection == .soft {
                return .keep(reason: "inferred edit against a soft-protected token")
            }
            if let reason = scriptViolation(edit, token: token) { return .keep(reason: reason) }
        }

        return .accept
    }

    /// Judge every edit and apply the ones that survive, in order.
    ///
    /// Sequential rather than batch: an earlier edit can change what a later one is judged
    /// against, and judging them all up front would be judging a graph that never existed.
    @discardableResult
    func apply(_ edits: [TranscriptEdit], to graph: inout TokenGraph) -> [TranscriptEdit] {
        var accepted: [TranscriptEdit] = []
        for edit in edits {
            switch judge(edit, in: graph) {
            case .accept:
                if graph.apply(edit) { accepted.append(edit) }
            case .keep(let reason):
                Logger.debug("Edit kept: \(edit.reason) — \(reason)", subsystem: .transcription)
            }
        }
        return accepted
    }

    // MARK: - Semantic guards

    /// Negation words, in every language the app polishes.
    ///
    /// Turning `don't deploy` into `deploy` is the catastrophic edit — it inverts the meaning
    /// while looking like a clean-up. No source is trusted with it, stated or otherwise: a
    /// dictionary entry that eats a negation is a bug in the dictionary.
    private static let negations: Set<String> = [
        "no", "not", "never", "none", "cannot", "cant", "dont", "doesnt", "didnt", "wont",
        "shouldnt", "wouldnt", "couldnt", "isnt", "arent", "wasnt", "werent", "havent", "hasnt",
        "לא", "אין", "אל", "אף",
        "не", "нет", "ни", "нельзя",
    ]

    /// A mark on `deniedInsertions`, proposed by a source that is guessing.
    ///
    /// Stated sources are exempt for the same reason they are exempt from the script rule: a
    /// comma in a list the `ListFormatter` built is a rule someone wrote down, not a model's
    /// opinion about prosody.
    private func deniedInsertion(_ edit: TranscriptEdit) -> String? {
        guard !Self.isStated(edit.source), case .insertAfter(let text) = edit.operation else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard Self.deniedInsertions.contains(trimmed) else { return nil }
        return "inferred sources may never insert '\(trimmed)' — measured P = 0.672 for ',' "
             + "and 0/25 for ';' and ':' (CALIBRATION.md §2, §5)"
    }

    private func negationViolation(_ edit: TranscriptEdit, token: TranscriptToken) -> String? {
        let original = Self.fold(token.effectiveText)
        let originalIsNegation = Self.negations.contains(original)

        switch edit.operation {
        case .delete where originalIsNegation:
            return "would delete the negation \(token.effectiveText)"
        case .replace(let text) where originalIsNegation
            && !Self.negations.contains(Self.fold(text)):
            return "would replace the negation \(token.effectiveText) with \(text)"
        case .insertAfter(let text) where Self.negations.contains(Self.fold(text)):
            return "would insert the negation \(text)"
        default:
            return nil
        }
    }

    /// A digit in the original must survive into the replacement.
    ///
    /// Mostly redundant — `ProtectionDetector` marks anything containing a digit as hard, so this
    /// only fires on a path that skipped detection. That is precisely when a backstop is worth
    /// having, and it costs a scan of one token.
    private func numberViolation(_ edit: TranscriptEdit, token: TranscriptToken) -> String? {
        let digits = token.effectiveText.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }

        switch edit.operation {
        case .delete:
            return "would delete \(token.effectiveText), which carries digits"
        case .replace(let text) where text.filter(\.isNumber) != digits:
            return "would change the digits in \(token.effectiveText) to \(text)"
        default:
            return nil
        }
    }

    /// A replacement may not move a token into a different script.
    ///
    /// This is the no-translation rule made mechanical, and it is why the worked example keeps
    /// `сегодня` instead of turning it into `היום`: language drift is a flat disqualifier, not a
    /// score to trade against. Stated sources are exempt, because a typed dictionary entry
    /// mapping `קוברנטיס → Kubernetes` is a transliteration the user asked for.
    private func scriptViolation(_ edit: TranscriptEdit, token: TranscriptToken) -> String? {
        guard case .replace(let text) = edit.operation else { return nil }
        let before = ScriptAnalyzer.scriptFamilies(in: token.effectiveText)
        let after = ScriptAnalyzer.scriptFamilies(in: text)
        guard !before.isEmpty, !after.isEmpty, !after.isSubset(of: before) else { return nil }
        return "would change script from \(before.map(\.rawValue).sorted().joined(separator: "+")) "
             + "to \(after.map(\.rawValue).sorted().joined(separator: "+"))"
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
