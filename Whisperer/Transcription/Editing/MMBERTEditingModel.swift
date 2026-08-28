//
//  MMBERTEditingModel.swift
//  Whisperer
//
//  GECToR-style token-level edit tagging: one encoder pass, one edit per token at most.
//
//  A discriminative tagger instead of a generative model for the reason the whole plan exists
//  — it *cannot* rewrite, reorder, translate or invent. Its entire output vocabulary is
//  "which of these operations applies to this token", so the catastrophic failure of a 4B
//  correction pass (fluent, confident, and about a different sentence) is not in its range.
//
//  Three things here are load-bearing and are not stylistic choices:
//
//  1. **A separate error-detection head, consulted first.** In a corrected-transcript corpus
//     the overwhelming majority of tokens are KEEP, so a single tagging head trained on that
//     distribution learns to say KEEP and nothing else. Detection first, tagging second, is
//     what keeps the tagging heads sharp.
//  2. **An explicit KEEP bias, added in logit space.** Precision is the only metric that
//     matters here — a missed correction costs nothing the user notices, a wrong one costs the
//     user's own words — so the decision threshold is deliberately not the argmax.
//  3. **The vetoes are vetoes.** Language drift and semantic risk cannot be traded against a
//     high operation score. `ConfidenceGate` enforces the script rule again independently;
//     doing it in both places means neither is the single point of failure.
//
//  **Weights exist; what applies is decided per language and per class, from a file.**
//  `MMBERTCoreMLRuntime` carries the fine-tuned `mmBERT-small`, so this type proposes real
//  edits. Which of them can *reach* the gate is `MMBERTCalibrationTable`, the measured
//  precision of every (language, head, action) cell from `Tools/mmbert/CALIBRATION.md`. Three
//  states, and the difference between them is the whole design:
//
//  - **certified** — the cell was measured and cleared the bar. Its measured threshold is the
//    action floor, and the confidence reported to the gate is uncapped so it can clear its
//    tier.
//  - **forbidden** — the cell was measured and refused. **No proposal at all** for that
//    (language, class). An unmeasured class must be unreachable, not merely unlikely, and a
//    low-confidence proposal is only the latter.
//  - **unmeasured** — the cell is absent (unknown language, or an action the calibration run
//    never saw). The proposal is still produced, so the benchmark can count it, with its
//    confidence capped below every floor `ConfidenceGate` can apply. Absence never means
//    permitted.
//
//  Against `StubEditingRuntime` the count is still exactly zero, and that is still a test.
//

import Foundation

struct MMBERTEditingModel: EditingModel {

    // MARK: - Calibration

    /// Thresholds, all of them calibration slots. The defaults are chosen so that an
    /// uncalibrated deployment is silent rather than enthusiastic.
    struct Calibration: Sendable {
        /// Added to the KEEP logit of the operation head before softmax. Two logits is roughly
        /// "the model must be about 7× more confident in the edit than in leaving it alone".
        let keepBias: Float
        /// Minimum P(incorrect) from the detection head.
        let errorFloor: Float
        /// Minimum probability for the chosen operation, and for the action head that supplies
        /// its content.
        let actionFloor: Float
        /// Maximum tolerated P(drifted) / P(risky). Above this the edit is dropped whatever it
        /// scored elsewhere.
        let vetoCeiling: Float
        /// Cap on the confidence reported to the gate for an **uncertified** edit — one whose
        /// (language, class) cell is not in the table at all.
        ///
        /// Strictly below the lowest floor `ConfidenceGate` can produce (0.95, the cosmetic
        /// tier), so an unmeasured cell cannot auto-apply by falling into a relaxed tier. That
        /// relationship is the invariant, not the number:
        /// `EditingModelTests.testUncertifiedCeilingSitsBelowEveryFloor` asserts it, and it is
        /// what makes "absence never means permitted" true rather than merely intended.
        let uncertifiedCeiling: Float
        /// Measured precision per (language, head, action). The only thing that can make a
        /// model-sourced edit reachable.
        let table: MMBERTCalibrationTable

        static let uncalibrated = Calibration(keepBias: 2.0,
                                              errorFloor: 0.90,
                                              actionFloor: 0.95,
                                              vetoCeiling: 0.10,
                                              uncertifiedCeiling: 0.94,
                                              table: .measured)
    }

    // MARK: - State

    let runtime: any TextEditingModelRuntime
    let calibration: Calibration

    init(runtime: any TextEditingModelRuntime,
         calibration: Calibration = .uncalibrated) {
        self.runtime = runtime
        self.calibration = calibration
    }

    // MARK: - EditingModel

    func propose(_ tokens: [TranscriptToken], context: EditContext) async -> [TranscriptEdit] {
        guard runtime.isLoaded else { return [] }

        // Whitespace never reaches the encoder: a sub-word vocabulary has no representation for
        // it, and every operation the heads can express targets a word or a mark. Deleting a
        // disfluency therefore leaves two adjacent whitespace tokens, which `TranscriptNormalizer`
        // collapses later in the pipeline — the tagger does not try to do that job itself.
        let candidates = tokens.filter { $0.kind != .whitespace }
        guard !candidates.isEmpty else { return [] }

        var allEdits: [TranscriptEdit] = []
        var editedTexts: [TokenID: String] = [:]  // tracks tokens modified in pass 1

        for pass in 0..<2 {
            let passEdits = try? await singlePass(candidates, editedTexts: editedTexts, context: context)
            guard let passEdits, !passEdits.isEmpty else { break }
            // On pass 2, skip tokens already edited (append/repl only fire once per token).
            let newEdits = pass == 0 ? passEdits : passEdits.filter { !editedTexts.keys.contains($0.target) }
            guard !newEdits.isEmpty else { break }
            allEdits.append(contentsOf: newEdits)
            // Track what was edited for next pass.
            for edit in newEdits {
                if case .replace(let text) = edit.operation { editedTexts[edit.target] = text }
                if case .insertAfter(_) = edit.operation { editedTexts[edit.target] = "" }
            }
            // Para/structural edits don't need a second pass.
            if pass == 0 && newEdits.allSatisfy({ isPunct($0) || isPara($0) }) { break }
        }

        if !allEdits.isEmpty {
            Logger.debug("Editor model: \(allEdits.count) edits over \(candidates.count) tokens",
                         subsystem: .transcription)
        }
        return allEdits
    }

    private func singlePass(_ candidates: [TranscriptToken],
                             editedTexts: [TokenID: String],
                             context: EditContext) async throws -> [TranscriptEdit] {
        var edits: [TranscriptEdit] = []
        let window = EditingSequenceShape.long.rawValue
        var start = 0

        while start < candidates.count {
            let slice = Array(candidates[start..<min(start + window, candidates.count)])
            let output = try await runtime.encode(slice.map(\.effectiveText))
            guard output.tokens.count == slice.count else {
                // A runtime that returns a different number of positions than it was given
                // has lost the alignment, and an edit applied to the wrong token is worse
                // than no edit. Abandon the whole pass rather than the current window.
                Logger.error("Editing runtime returned \(output.tokens.count) positions for "
                             + "\(slice.count) tokens", subsystem: .transcription)
                return []
            }
            for (token, logits) in zip(slice, output.tokens) {
                if let edit = proposal(for: token,
                                       logits: logits,
                                       language: context.language?.rawValue) {
                    edits.append(edit)
                }
            }
            start += window
        }
        return edits
    }

    private func isPunct(_ edit: TranscriptEdit) -> Bool {
        if case .insertAfter(let s) = edit.operation { return ".,?!;:".contains(s) }
        return false
    }

    private func isPara(_ edit: TranscriptEdit) -> Bool {
        if case .insertAfter(let s) = edit.operation { return s.hasPrefix("\n") }
        return false
    }

    // MARK: - Tagging policy

    private func proposal(for token: TranscriptToken,
                          logits: EditingTokenLogits,
                          language: String?) -> TranscriptEdit? {
        guard let errorLogits = logits.values(for: .error),
              let operationLogits = logits.values(for: .operation) else { return nil }

        // The detection head's cell supplies a *threshold*, never permission. `error` is not an
        // edit class — it is the "is anything wrong with this token" aggregate, and its precision
        // is dominated by whichever class is most common rather than by the class being proposed,
        // so `enabled` on it would say nothing about the edit at hand. Taking the maximum keeps a
        // cell measured at a low operating point (he/error, 0.54) from *loosening* the default.
        let errorCell = calibration.table.cell(language: language, head: .error, action: "ERROR")
        let errorFloor = max(calibration.errorFloor, errorCell?.threshold ?? 0)
        let errorProbability = Self.softmax(errorLogits)[EditingErrorLabel.incorrect.rawValue]
        guard errorProbability >= errorFloor else { return nil }

        var biased = operationLogits
        biased[EditingOperationLabel.keep.rawValue] += calibration.keepBias
        let operationProbabilities = Self.softmax(biased)
        guard let choice = Self.argmax(operationProbabilities),
              choice != EditingOperationLabel.keep.rawValue,
              operationProbabilities[choice] >= calibration.actionFloor,
              let label = EditingOperationLabel(rawValue: choice) else { return nil }

        if vetoed(logits, head: .language, label: EditingLanguageLabel.drifted.rawValue) { return nil }
        if vetoed(logits, head: .semanticRisk, label: EditingRiskLabel.risky.rawValue) { return nil }

        guard let action = self.action(for: label,
                                       token: token,
                                       logits: logits,
                                       language: language) else { return nil }

        let raw = errorProbability * operationProbabilities[choice] * action.probability
        let confidence = action.certified ? raw : min(calibration.uncertifiedCeiling, raw)

        return TranscriptEdit(target: token.id,
                              operation: action.operation,
                              source: .editorModel,
                              confidence: confidence,
                              reason: "editor model: \(action.description)")
    }

    private struct Action {
        let operation: EditOperation
        let probability: Float
        let description: String
        /// Whether the (language, class) cell behind this action was measured *and* enabled.
        /// An uncertified action still reaches the gate — capped below every floor — so the
        /// benchmark can count what calibration would buy.
        let certified: Bool
    }

    /// The floor this action's probability must clear, and whether clearing it certifies
    /// anything. `nil` means the class is forbidden in this language and no proposal exists.
    private func requirement(_ head: MMBERTCalibrationTable.Head,
                             _ action: String,
                             _ language: String?) -> (floor: Float, certified: Bool)? {
        switch calibration.table.verdict(language: language, head: head, action: action) {
        case .forbidden:
            return nil
        case .certified(let threshold):
            // The measured operating point itself, not a maximum against `actionFloor`: the
            // precision claim is attached to *that* threshold, and raising it would discard
            // certified recall on the strength of a number nobody measured.
            return (threshold, true)
        case .unmeasured:
            return (calibration.actionFloor, false)
        }
    }

    /// Turn an operation label into the operation's actual content, from the head that owns it.
    ///
    /// The operation head says *that* something changes; it never says *what to*. Splitting it
    /// this way is what makes "sentence-final periods are certified in English, commas are not"
    /// expressible as a table lookup rather than as a retrained model.
    private func action(for label: EditingOperationLabel,
                        token: TranscriptToken,
                        logits: EditingTokenLogits,
                        language: String?) -> Action? {
        switch label {
        case .keep:
            return nil

        case .delete:
            // A delete is only ever a disfluency here. Deleting a token for an unstated reason
            // is the edit class that silently drops content, so the disfluency head has to
            // assert it independently.
            guard let head = logits.values(for: .disfluency),
                  let rule = requirement(.disf, "DISF", language) else { return nil }
            let probabilities = Self.softmax(head)
            let drop = probabilities[EditingDisfluencyLabel.drop.rawValue]
            guard drop >= rule.floor else { return nil }
            return Action(operation: .delete,
                          probability: drop,
                          description: "drop disfluency '\(token.effectiveText)'",
                          certified: rule.certified)

        case .insertAfter:
            // First try the punctuation head.
            if let head = logits.values(for: .punctuation) {
                let probabilities = Self.softmax(head)
                if let index = Self.argmax(probabilities),
                   let mark = EditingPunctuationLabel(rawValue: index)?.mark,
                   let rule = requirement(.punct, mark, language),
                   probabilities[index] >= rule.floor {
                    return Action(operation: .insertAfter(mark),
                                  probability: probabilities[index],
                                  description: "insert '\(mark)' after '\(token.effectiveText)'",
                                  certified: rule.certified)
                }
            }
            // Try the para head (surfaced via the .structure slot) for paragraph breaks.
            if let structureVals = logits.values(for: .structure) {
                let structureProbs = Self.softmax(structureVals)
                let breakProb = structureProbs.count > 1 ? structureProbs[1] : 0
                if let rule = requirement(.para, "PARA_BREAK", language), breakProb >= rule.floor {
                    return Action(operation: .insertAfter("\n\n"),
                                  probability: breakProb,
                                  description: "paragraph break after '\(token.effectiveText)'",
                                  certified: rule.certified)
                }
            }
            // TODO: word-level append (selecting WHICH word to insert) requires the raw
            // append logits to be carried through synthesis. For v1, when the punctuation
            // head says NONE and there is no para break, punt.
            return nil

        case .replace:
            // The only replacement a tagger without an output vocabulary can make is a case
            // transform. In a caseless script the transform is the identity, so Hebrew falls
            // out as "no edit" here rather than needing a language check.
            guard let head = logits.values(for: .casing) else { return nil }
            let probabilities = Self.softmax(head)
            guard let index = Self.argmax(probabilities),
                  index != EditingCasingLabel.keep.rawValue,
                  let casing = EditingCasingLabel(rawValue: index),
                  let rule = requirement(.casing, casing.calibrationAction, language),
                  probabilities[index] >= rule.floor else { return nil }
            let text = Self.applyCasing(casing, to: token.effectiveText)
            guard text != token.effectiveText else { return nil }
            return Action(operation: .replace(text),
                          probability: probabilities[index],
                          description: "recase '\(token.effectiveText)' → '\(text)'",
                          certified: rule.certified)
        }
    }

    /// A veto head is read against a ceiling, not an argmax, so an *undecided* head blocks: a
    /// flat distribution puts 0.5 on "risky", which is far above the ceiling. That asymmetry is
    /// intentional — "the model has no opinion about whether this changes the meaning" is not a
    /// licence to change it. A head the runtime does not emit at all cannot veto, because that
    /// is a contract mismatch rather than a model opinion, and it is already caught by the
    /// width check in `EditingTokenLogits.values(for:)` failing the heads that do propose.
    private func vetoed(_ logits: EditingTokenLogits, head: EditingHead, label: Int) -> Bool {
        guard let values = logits.values(for: head) else { return false }
        return Self.softmax(values)[label] > calibration.vetoCeiling
    }

    // MARK: - Transforms

    /// `capitalize` upper-cases the first character and leaves the rest alone, rather than
    /// using `capitalized`, which lower-cases the remainder and would turn `API` into `Api` and
    /// `GitHub` into `Github` — silent damage to exactly the terms this app is dictated at.
    private static func applyCasing(_ casing: EditingCasingLabel, to text: String) -> String {
        switch casing {
        case .keep:
            return text
        case .lower:
            return text.lowercased()
        case .upper:
            return text.uppercased()
        case .capitalize:
            guard let first = text.first else { return text }
            return String(first).uppercased() + text.dropFirst()
        }
    }

    // MARK: - Numerics

    /// Max-subtracted softmax. The runtime returns logits from an FP16 graph, where an
    /// un-shifted exponential overflows well inside the range the model actually produces.
    static func softmax(_ logits: [Float]) -> [Float] {
        guard let maximum = logits.max() else { return [] }
        let exponentials = logits.map { expf($0 - maximum) }
        let total = exponentials.reduce(0, +)
        guard total > 0 else {
            return [Float](repeating: 1 / Float(max(1, logits.count)), count: logits.count)
        }
        return exponentials.map { $0 / total }
    }

    /// Index of the largest value, ties going to the lowest index — which is the KEEP label in
    /// every head, so a perfectly undecided model does nothing.
    static func argmax(_ values: [Float]) -> Int? {
        guard !values.isEmpty else { return nil }
        var best = 0
        for index in 1..<values.count where values[index] > values[best] { best = index }
        return best
    }
}

// MARK: - Calibration action names

private extension EditingCasingLabel {
    /// The name `calibrate.py` gives this class. The Swift label space and the Python one are
    /// two spellings of the same thing, and a lookup that silently missed would read as
    /// "unmeasured" — which is safe but wrong, so the mapping is explicit and total.
    var calibrationAction: String {
        switch self {
        case .keep:       return "NONE"
        case .lower:      return "LOWER"
        case .capitalize: return "CAP"
        case .upper:      return "UPPER"
        }
    }
}

// MARK: - Measured precision

/// Per-(language, head, action) precision, as measured by `Tools/mmbert/calibrate.py` and
/// written to `Tools/mmbert/thresholds-calibrated.json`.
///
/// **Baked into the binary as a Swift literal rather than shipped as a bundle resource**, for
/// two reasons. A new `.swift` file under `Whisperer/` is picked up automatically by the
/// project's `PBXFileSystemSynchronizedRootGroup`; a new non-Swift resource needs a pbxproj
/// edit, and a resource that was added to the repo but not to the target is missing only at
/// runtime, on a user's machine. And the failure mode of a missing table is exactly the state
/// this type calls `unmeasured` — proposals capped, nothing applied — which is *safe* but
/// indistinguishable from "calibration ran and found nothing", i.e. a silent regression from an
/// enabled cell back to a disabled one. A literal cannot go missing.
///
/// The cost of that choice is that the literal has to be regenerated when the JSON changes.
/// `decode(from:)` is the schema-faithful loader that makes regeneration mechanical and lets a
/// test read the JSON directly, and `EditingModelTests.testBakedTableIsNoLooserThanTheJSON`
/// fails if the literal is ever more permissive than the file it claims to mirror.
struct MMBERTCalibrationTable: Sendable {

    /// The heads `calibrate.py` reports. Spelled as the JSON spells them.
    /// The first four (error, punct, casing, disf) are measured; the remaining four
    /// (append, repl, merge, para) are new and unmeasured — absent from the table,
    /// so proposals from them are capped below every gate floor.
    enum Head: String, Sendable, CaseIterable {
        case error
        case punct
        case casing = "case"
        case disf
        case append      // word insertion from APPEND_VOCAB
        case repl        // word replacement (g-transform or literal)
        case merge       // compound merge or split
        case para        // paragraph break / list item
    }

    struct Cell: Sendable, Equatable {
        /// The operating point the cell was measured at. `nil` when the calibration run had no
        /// data at all for the cell.
        let threshold: Float?
        /// Whether the cell cleared the release rule: point precision ≥ 0.99, support ≥ 30, and
        /// a Clopper-Pearson 95% lower bound ≥ 0.99. Rule 3 is the one that does the work.
        let enabled: Bool
        let precision: Float?
        let support: Int?
        let precisionLCB95: Float?
    }

    /// What the table says about one (language, class).
    enum Verdict: Sendable, Equatable {
        /// Measured and cleared. `threshold` is the action floor for this class.
        case certified(threshold: Float)
        /// Measured and refused. No proposal of this class in this language, at any confidence.
        case forbidden
        /// Not in the table: unknown language, or an action the calibration run never saw.
        case unmeasured
    }

    /// Keyed `"<language>/<head>/<action>"`, e.g. `"en/punct/."`.
    let cells: [String: Cell]

    init(cells: [String: Cell]) {
        self.cells = cells
    }

    static func key(language: String, head: Head, action: String) -> String {
        "\(language)/\(head.rawValue)/\(action)"
    }

    func cell(language: String?, head: Head, action: String) -> Cell? {
        guard let language else { return nil }
        return cells[Self.key(language: language, head: head, action: action)]
    }

    /// A missing cell is `unmeasured`, never `certified`. An `enabled` cell with no threshold is
    /// `forbidden`, not certified-at-zero: a cell that claims to be open without naming an
    /// operating point is a broken file, and a broken file must not open a class.
    func verdict(language: String?, head: Head, action: String) -> Verdict {
        guard let cell = cell(language: language, head: head, action: action) else {
            return .unmeasured
        }
        guard cell.enabled, let threshold = cell.threshold else { return .forbidden }
        return .certified(threshold: threshold)
    }

    // MARK: - Loading

    enum LoadFailure: Error, LocalizedError {
        case unsupportedSchema(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "thresholds-calibrated.json is schema \(version); this build reads 2"
            }
        }
    }

    private struct Document: Decodable {
        struct Cell: Decodable {
            let language: String
            let head: String
            let action: String
            let threshold: Float?
            let precision: Float?
            let support: Int?
            let precisionLCB95: Float?
            let enabled: Bool

            enum CodingKeys: String, CodingKey {
                case language, head, action, threshold, precision, support, enabled
                case precisionLCB95 = "precision_lcb95"
            }
        }

        let schema: Int
        let cells: [String: Cell]
    }

    /// Decode `thresholds-calibrated.json`.
    ///
    /// The key is rebuilt from each cell's own `language`/`head`/`action` rather than trusted
    /// from the dictionary key, so a file whose key and body disagree resolves to the body — the
    /// side `calibrate.py` computes from.
    static func decode(from data: Data) throws -> MMBERTCalibrationTable {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schema == 2 else { throw LoadFailure.unsupportedSchema(document.schema) }

        var cells: [String: Cell] = [:]
        for entry in document.cells.values {
            guard let head = Head(rawValue: entry.head) else { continue }
            cells[key(language: entry.language, head: head, action: entry.action)] =
                Cell(threshold: entry.threshold,
                     enabled: entry.enabled,
                     precision: entry.precision,
                     support: entry.support,
                     precisionLCB95: entry.precisionLCB95)
        }
        return MMBERTCalibrationTable(cells: cells)
    }

    /// No cells at all. Every class reads `unmeasured`: proposals are produced and capped, and
    /// nothing applies. The behaviour a build with no calibration file would have.
    static let empty = MMBERTCalibrationTable(cells: [:])

    // MARK: - The measured table

    /// Generated from `Tools/mmbert/thresholds-calibrated-history.json` (schema 2, risk-tiered
    /// gates 0.99 meaning / 0.97 disfluency / 0.95 cosmetic, Clopper-Pearson one-sided 95% lower
    /// bound), calibrated on `eval_real_large.jsonl` — **783 held-out real ASR → teacher pairs,
    /// nothing synthetic**. The previous generation of this table came from `pooled_indomain`,
    /// which mixes synthetically-corrupted text into the denominator and reads ~10 points high on
    /// every cell; `Tools/mmbert/CALIBRATION.md` §2a explains why only the real split may enable.
    ///
    /// 8 cells enabled as of 2026-08-28 (retrain on Wispr dictation + meeting corpus, en/he/ru).
    /// en: error, punct/. punct/? case/LOWER case/CAP. ru: error, punct/. case/CAP.
    /// Flip a cell's `enabled` to `true` here and that class becomes reachable in that language.
    static let measured = MMBERTCalibrationTable(cells: [
        "en/error/ERROR": Cell(threshold: 0.89, enabled: true, precision: 0.7289073305670816, support: 723, precisionLCB95: 0.7003575569761824),
        "en/punct/ALL": Cell(threshold: 0.9992, enabled: false, precision: 0.8770491803278688, support: 122, precisionLCB95: 0.8170062716380074),
        "en/punct/NONE": Cell(threshold: 0.88, enabled: false, precision: 0.42857142857142855, support: 7, precisionLCB95: 0.1287563928042427),
        "en/punct/.": Cell(threshold: 0.42, enabled: true, precision: 0.7067510548523207, support: 474, precisionLCB95: 0.6704001069387046),
        "en/punct/,": Cell(threshold: 0.76, enabled: false, precision: 0.35, support: 200, precisionLCB95: 0.2939763936794282),
        "en/punct/?": Cell(threshold: 0.95, enabled: true, precision: 1.0, support: 5, precisionLCB95: 0.5492802716530588),
        "en/punct/!": Cell(threshold: 0.64, enabled: false, precision: 0.2, support: 5, precisionLCB95: 0.010206218313011496),
        "en/punct/;": Cell(threshold: 0.7, enabled: false, precision: 0.5, support: 2, precisionLCB95: 0.025320565519103607),
        "en/punct/:": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 5, precisionLCB95: 0.0),
        "en/punct/…": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 2, precisionLCB95: 0.0),
        "en/punct/—": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/case/ALL": Cell(threshold: 0.9995, enabled: false, precision: 1.0, support: 7, precisionLCB95: 0.6518363448688391),
        "en/case/LOWER": Cell(threshold: 0.3, enabled: true, precision: 0.7441860465116279, support: 43, precisionLCB95: 0.6122847921535253),
        "en/case/CAP": Cell(threshold: 0.3, enabled: true, precision: 0.517948717948718, support: 195, precisionLCB95: 0.45662794398462714),
        "en/case/UPPER": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 3, precisionLCB95: 0.0),
        "en/disf/DISF": Cell(threshold: 0.95, enabled: false, precision: 0.40540540540540543, support: 37, precisionLCB95: 0.2690551870775714),
        "en/append/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/the": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/a": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/is": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/are": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/an": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/to": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/in": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/of": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/that": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/it": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/not": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/for": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/on": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/you": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/was": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/with": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/at": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/this": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/have": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/we": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/they": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/or": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/be": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/as": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/but": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/by": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/can": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/had": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/his": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/from": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/she": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/what": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/their": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/do": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/which": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/one": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/would": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/all": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/there": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/some": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/been": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/also": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/its": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/so": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/my": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/when": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/more": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/up": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/no": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/if": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/out": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/about": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/who": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/get": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/your": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/said": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/could": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/them": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/into": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/just": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/then": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/our": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/will": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/has": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/like": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/than": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/other": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/how": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/may": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/two": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/these": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/should": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/her": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/him": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/any": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/were": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/now": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/here": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/over": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/time": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/first": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/very": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/need": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/make": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/see": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/way": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/use": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/does": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/only": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/new": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/because": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/going": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/back": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/people": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/well": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/know": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/append/want": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/PLURAL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/SINGULAR": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/VERB_3SG": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/VERB_PAST": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/VERB_ING": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/CONTRACT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/repl/EXPAND": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/merge/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/merge/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/merge/MERGE_SPACE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/merge/MERGE_HYPHEN": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/merge/SPLIT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/LIST_ITEM": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/error/ERROR": Cell(threshold: 0.983, enabled: false, precision: 0.35714285714285715, support: 14, precisionLCB95: 0.1527176223846631),
        "he/punct/ALL": Cell(threshold: 0.9965, enabled: false, precision: 0.5, support: 4, precisionLCB95: 0.09761146288641434),
        "he/punct/NONE": Cell(threshold: 0.3, enabled: false, precision: 1.0, support: 1, precisionLCB95: 0.05),
        "he/punct/.": Cell(threshold: 0.91, enabled: false, precision: 0.25, support: 16, precisionLCB95: 0.0902524330304275),
        "he/punct/,": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 10, precisionLCB95: 0.0),
        "he/punct/?": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 1, precisionLCB95: 0.0),
        "he/punct/!": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/punct/;": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/punct/:": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/punct/…": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 1, precisionLCB95: 0.0),
        "he/punct/—": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/case/ALL": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 2, precisionLCB95: 0.0),
        "he/case/LOWER": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 2, precisionLCB95: 0.0),
        "he/case/CAP": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/case/UPPER": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/disf/DISF": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 2, precisionLCB95: 0.0),
        "he/append/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/the": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/a": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/is": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/are": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/an": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/to": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/in": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/of": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/that": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/it": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/not": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/for": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/on": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/you": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/was": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/with": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/at": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/this": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/have": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/we": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/they": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/or": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/be": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/as": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/but": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/by": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/can": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/had": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/his": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/from": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/she": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/what": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/their": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/do": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/which": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/one": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/would": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/all": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/there": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/some": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/been": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/also": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/its": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/so": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/my": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/when": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/more": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/up": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/no": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/if": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/out": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/about": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/who": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/get": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/your": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/said": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/could": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/them": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/into": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/just": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/then": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/our": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/will": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/has": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/like": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/than": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/other": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/how": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/may": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/two": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/these": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/should": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/her": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/him": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/any": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/were": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/now": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/here": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/over": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/time": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/first": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/very": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/need": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/make": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/see": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/way": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/use": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/does": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/only": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/new": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/because": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/going": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/back": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/people": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/well": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/know": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/append/want": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/PLURAL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/SINGULAR": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/VERB_3SG": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/VERB_PAST": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/VERB_ING": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/CONTRACT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/repl/EXPAND": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/merge/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/merge/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/merge/MERGE_SPACE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/merge/MERGE_HYPHEN": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/merge/SPLIT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/LIST_ITEM": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/error/ERROR": Cell(threshold: 0.81, enabled: true, precision: 0.8, support: 70, precisionLCB95: 0.7051410953403354),
        "ru/punct/ALL": Cell(threshold: 0.9985, enabled: false, precision: 1.0, support: 23, precisionLCB95: 0.8778766110934769),
        "ru/punct/NONE": Cell(threshold: 0.3, enabled: false, precision: 0.3333333333333333, support: 6, precisionLCB95: 0.06284989170835438),
        "ru/punct/.": Cell(threshold: 0.48, enabled: true, precision: 0.8421052631578947, support: 38, precisionLCB95: 0.7119602039732773),
        "ru/punct/,": Cell(threshold: 0.9635, enabled: false, precision: 1.0, support: 7, precisionLCB95: 0.6518363448688391),
        "ru/punct/?": Cell(threshold: 0.3, enabled: false, precision: 0.0, support: 1, precisionLCB95: 0.0),
        "ru/punct/!": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/punct/;": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/punct/:": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/punct/…": Cell(threshold: 0.3, enabled: false, precision: 1.0, support: 1, precisionLCB95: 0.05),
        "ru/punct/—": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/case/ALL": Cell(threshold: 0.959, enabled: false, precision: 0.68, support: 25, precisionLCB95: 0.4963584376204965),
        "ru/case/LOWER": Cell(threshold: 0.3, enabled: false, precision: 0.3333333333333333, support: 3, precisionLCB95: 0.016952427508441496),
        "ru/case/CAP": Cell(threshold: 0.3, enabled: true, precision: 0.6666666666666666, support: 27, precisionLCB95: 0.49052175879598586),
        "ru/case/UPPER": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/disf/DISF": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/the": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/a": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/is": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/are": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/an": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/to": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/in": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/of": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/that": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/it": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/not": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/for": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/on": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/you": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/was": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/with": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/at": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/this": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/have": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/we": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/they": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/or": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/be": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/as": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/but": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/by": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/can": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/had": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/his": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/from": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/she": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/what": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/their": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/do": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/which": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/one": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/would": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/all": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/there": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/some": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/been": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/also": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/its": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/so": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/my": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/when": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/more": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/up": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/no": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/if": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/out": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/about": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/who": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/get": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/your": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/said": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/could": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/them": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/into": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/just": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/then": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/our": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/will": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/has": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/like": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/than": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/other": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/how": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/may": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/two": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/these": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/should": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/her": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/him": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/any": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/were": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/now": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/here": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/over": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/time": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/first": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/very": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/need": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/make": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/see": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/way": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/use": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/does": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/only": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/new": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/because": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/going": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/back": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/people": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/well": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/know": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/append/want": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/PLURAL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/SINGULAR": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/VERB_3SG": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/VERB_PAST": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/VERB_ING": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/CONTRACT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/repl/EXPAND": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/merge/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/merge/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/merge/MERGE_SPACE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/merge/MERGE_HYPHEN": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/merge/SPLIT": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/ALL": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/NONE": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/LIST_ITEM": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK/unknown": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK/editor": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK/chat": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK/browser": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "en/para/PARA_BREAK/messaging": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK/unknown": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK/editor": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK/chat": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK/browser": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "he/para/PARA_BREAK/messaging": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK/unknown": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK/editor": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK/chat": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK/browser": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
        "ru/para/PARA_BREAK/messaging": Cell(threshold: nil, enabled: false, precision: nil, support: 0, precisionLCB95: nil),
    ])
}
