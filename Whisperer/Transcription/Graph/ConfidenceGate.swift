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
//    script changes, and a threshold high enough that in practice nothing auto-applies until it
//    has been measured at ≥99% precision per language.
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
    /// These are calibration slots, not measurements. The plan calibrates per language × edit
    /// type × candidate source × quantized model version × capability tier; until that data
    /// exists the model-sourced floors sit at 0.99, which is another way of saying nothing from a
    /// model auto-applies yet.
    static func floor(for source: EditSource) -> Float {
        switch source {
        case .alias:          return 0.75   // admits a learned alias (0.80); a shipped one is 0.95
        case .filler:         return 0.85
        case .normalization:  return 0.90
        case .listFormatting: return 0.90
        case .editorModel:    return 0.99
        case .llm:            return 0.99
        }
    }

    /// Whether a source asserts a rule someone wrote down, or guesses.
    static func isStated(_ source: EditSource) -> Bool {
        switch source {
        case .alias, .filler, .normalization, .listFormatting: return true
        case .editorModel, .llm: return false
        }
    }

    /// Reserved for M3+. Off here so that this gate is provably evidence-blind.
    let requireAcousticSupport: Bool

    init(requireAcousticSupport: Bool = false) {
        self.requireAcousticSupport = requireAcousticSupport
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

        if edit.confidence < Self.floor(for: edit.source) {
            return .keep(reason: String(format: "confidence %.2f below %.2f floor for %@",
                                        edit.confidence, Self.floor(for: edit.source),
                                        edit.source.rawValue))
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
