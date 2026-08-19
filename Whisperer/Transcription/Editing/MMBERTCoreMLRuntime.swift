//
//  MMBERTCoreMLRuntime.swift
//  Whisperer
//
//  The real weights behind `MMBERTEditingModel`, replacing `StubEditingRuntime`.
//
//  `jhu-clsp/mmBERT-small` fine-tuned on 7,099 steps of transcript-edit supervision, exported to
//  Core ML at fixed shapes 32 / 64 / 128, FP16 activations with int8 per-channel weights.
//
//  **The Neural Engine is excluded, and not for performance.** `export_coreml.py` measured
//  `CPU_AND_NE` at 1.27 ms p50 against `ALL`'s 7.3 ms and that is real, but
//  `MMBERTRuntimeTests.testComputeUnitFidelityAgainstPython` then measured what those numbers
//  cost: against the same `.mlpackage` run from Python, the worst per-logit error is
//
//      cpuAndGPU  0.0000      all  0.0000      cpuOnly  0.1406      cpuAndNeuralEngine  8.6455
//
//  8.6 logits is a different prediction, not a noisy one — and `thresholds.json` calibrates
//  decisions at 0.983–0.996, where it decides the outcome outright. So the compute unit here is
//  a correctness setting that happens to have a latency consequence, not the other way around.
//  `.cpuAndGPU` rather than `.all` because `.all` merely *happens* not to schedule the ANE for
//  this graph today; naming the exclusion is what keeps a future OS from silently re-enabling
//  the 8.6-logit path. On `.cpuAndGPU` the parity residual is 5e-06 across 848 logits and
//  `testEditorLatencyIsWithinBudget` measures p50 12.5 ms / p95 13.5 ms end to end for 19 words,
//  against a 100 ms budget — so correctness here costs nothing worth having.
//
//  **Four trained heads, eight declared heads.** `TextEditingModelRuntime` declares error,
//  operation, punctuation, casing, disfluency, structure, language and semanticRisk. The trained
//  model has four: `error` (2), `punct` (9 absolute targets), `case` (3 absolute targets) and
//  `disf` (2). This type synthesizes the interface from what was actually trained and emits
//  *nothing at all* for structure, language and semanticRisk — an absent head cannot veto, which
//  is the correct reading: the model has no opinion about semantic risk because it was never
//  taught one, and inventing a confident "safe" for it would be worse than silence. The
//  independent script check in `ConfidenceGate.scriptViolation` is what actually stops drift, and
//  it does not depend on a model head.
//
//  **Absolute targets, not deltas.** `punct` and `case` predict the state the word *should* be
//  in, not the change to make. An edit exists exactly when the argmax differs from the word's
//  current state — the same rule `evaluate.py` calibrated its thresholds under, so the numbers in
//  `thresholds.json` describe this code and not an approximation of it. The KEEP prior
//  (`keep_bias = 2.0`, additive on the class matching the current state) is applied here rather
//  than in the graph: `ExportWrapper` deliberately left it out so the Core ML inputs stay
//  `(input_ids, attention_mask)`, and the current state is something only this side knows.
//
//  **Two deliberate recall sacrifices**, both in the precision-preserving direction:
//
//  1. A word that *already* carries trailing punctuation gets its punctuation head zeroed.
//     `EditOperation` can insert after a token but cannot rewrite the punctuation token that
//     follows it, so `foo. → foo?` is inexpressible; proposing an insert on top of the existing
//     mark would produce `foo.?`. Suppressed rather than approximated.
//  2. One edit per token. A word needing both a recase and a comma yields whichever the
//     synthesized operation head ranks higher; the other is lost for this pass. `TranscriptEdit`
//     addresses one operation per `TokenID` and widening that is not a runtime's decision.
//

import CoreML
import Foundation
import Hub
import Tokenizers

// MARK: - Runtime

/// A `final class` with an `NSLock`, not an `actor`: `TextEditingModelRuntime.isLoaded` is a
/// synchronous property and an actor cannot supply one without `assumeIsolated` at every call
/// site. Core ML prediction is itself thread-safe, so the lock only guards the loaded handles.
final class MMBERTCoreMLRuntime: TextEditingModelRuntime, @unchecked Sendable {

    // MARK: - Label spaces

    /// The trained punctuation vocabulary, in the order `common.py` fixed. Two of its classes —
    /// the ellipsis and the em dash — have no `EditingPunctuationLabel`, so their mass is folded
    /// into "no punctuation" rather than renormalized away. Renormalizing would raise every
    /// remaining probability and quietly loosen a threshold; folding into the no-op lowers them.
    private static let trainedPunctuation: [String] = ["", ".", ",", "?", "!", ";", ":", "…", "—"]

    /// Where each trained punctuation class lands in `EditingPunctuationLabel`. Note `;` and `:`
    /// are transposed between the two orderings — the exact kind of mismatch that produces a
    /// plausible-looking wrong mark, which is why this is a table and not arithmetic.
    private static let punctuationMapping: [EditingPunctuationLabel] = [
        .none, .period, .comma, .question, .exclamation, .semicolon, .colon, .none, .none,
    ]

    /// Trained casing classes, absolute: `LOWER`, `CAP`, `UPPER`. There is no `keep` — keeping is
    /// "the argmax equals the current state".
    private enum TrainedCase: Int, CaseIterable { case lower, cap, upper }

    /// The additive KEEP prior the model was trained and calibrated under. Changing this
    /// invalidates every threshold in `thresholds.json`.
    private static let keepPrior: Float = 2.0

    private static let maximumTokens = EditingSequenceShape.long.rawValue

    // MARK: - Loaded state

    private struct Loaded {
        let tokenizer: any Tokenizer
        let models: [EditingSequenceShape: MLModel]
        let bos: Int
        let eos: Int
        let pad: Int
    }

    private let directory: URL
    private let computeUnits: MLComputeUnits
    private let lock = NSLock()
    private var loaded: Loaded?
    /// The load in flight, if any. Guarded by `lock`; see `load()`.
    private var loadTask: Task<Void, any Error>?

    /// - Parameters:
    ///   - directory: folder holding `MMBERTEditing_{32,64,128}.mlpackage` and the tokenizer.
    ///   - computeUnits: which backend Core ML may use. Exposed rather than hard-coded because
    ///     it is not a performance knob here — it changes the *numbers*. See the header, and
    ///     `MMBERTRuntimeTests.testComputeUnitFidelityAgainstPython` for the measured deltas.
    init(directory: URL, computeUnits: MLComputeUnits = .cpuAndGPU) {
        self.directory = directory
        self.computeUnits = computeUnits
    }

    var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded != nil
    }

    // MARK: - Locating the weights

    /// App bundle first, then the training tree.
    ///
    /// The artifacts are 142 MB per shape and are **not** bundled today — shipping 427 MB of
    /// weights is a decision that belongs after the precision gate is met, not before it. The
    /// `#filePath` fallback is what lets the benchmark measure real weights on this machine
    /// without that decision having been made, and it resolves to nothing in a shipped build.
    static func locate() -> URL? {
        if let bundled = Bundle.main.url(forResource: "MMBERTEditing_32", withExtension: "mlmodelc") {
            return bundled.deletingLastPathComponent()
        }
        let development = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Editing
            .deletingLastPathComponent()      // Transcription
            .deletingLastPathComponent()      // Whisperer
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("Tools/mmbert/artifacts")
        let probe = development.appendingPathComponent("MMBERTEditing_32.mlpackage")
        return FileManager.default.fileExists(atPath: probe.path) ? development : nil
    }

    /// `nil` when no weights are on disk. Callers keep `StubEditingRuntime` in that case rather
    /// than failing: an app with no tagger polishes deterministically, which is the M2 behaviour.
    static func makeIfAvailable(
        computeUnits: MLComputeUnits = .cpuAndGPU) -> MMBERTCoreMLRuntime? {
        locate().map { MMBERTCoreMLRuntime(directory: $0, computeUnits: computeUnits) }
    }

    // MARK: - Loading

    /// Idempotent and safe to call concurrently.
    ///
    /// A bare check-then-act would release the lock between "is it loaded?" and the store at the
    /// end, so two callers arriving together both compiled and both instantiated three MLModels
    /// — 427 MB of duplicated work, one copy of which is then thrown away. The in-flight task is
    /// published under the lock instead, so the second caller awaits the first one's load.
    func load() async throws {
        lock.lock()
        if loaded != nil {
            lock.unlock()
            return
        }
        if let inFlight = loadTask {
            lock.unlock()
            return try await inFlight.value
        }
        let task = Task { [weak self] in
            guard let self else { throw EditingRuntimeError.weightsUnavailable }
            try await self.performLoad()
        }
        loadTask = task
        lock.unlock()

        defer {
            lock.lock()
            if loadTask == task { loadTask = nil }
            lock.unlock()
        }
        try await task.value
    }

    private func performLoad() async throws {
        let tokenizer = try Self.loadTokenizer(from: directory)
        var models: [EditingSequenceShape: MLModel] = [:]
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        for shape in EditingSequenceShape.allCases {
            let compiled = directory.appendingPathComponent("MMBERTEditing_\(shape.rawValue).mlmodelc")
            let package = directory.appendingPathComponent("MMBERTEditing_\(shape.rawValue).mlpackage")
            let source: URL
            if FileManager.default.fileExists(atPath: compiled.path) {
                source = compiled
            } else if FileManager.default.fileExists(atPath: package.path) {
                // Compiling takes seconds and lands in a temporary directory the system reaps.
                // Acceptable here because loading happens once per process, off the audio path.
                source = try await MLModel.compileModel(at: package)
            } else {
                throw EditingRuntimeError.weightsUnavailable
            }
            models[shape] = try MLModel(contentsOf: source, configuration: configuration)
        }

        // `common.py` uses cls/sep with a bos/eos fallback; this tokenizer maps cls→<bos> and
        // sep→<eos>, so reading bos/eos here produces the identical pair.
        let bos = tokenizer.bosTokenId ?? 2
        let eos = tokenizer.eosTokenId ?? 1

        lock.lock()
        loaded = Loaded(tokenizer: tokenizer, models: models, bos: bos, eos: eos, pad: 0)
        lock.unlock()
        Logger.info("mmBERT editing runtime loaded from \(directory.lastPathComponent)",
                    subsystem: .transcription)
    }

    func unload() async {
        lock.lock()
        loaded = nil
        lock.unlock()
    }

    private static func loadTokenizer(from directory: URL) throws -> any Tokenizer {
        // `export_coreml.py` writes the packages to `artifacts/` and `tok.save_pretrained` writes
        // the tokenizer to `artifacts/model/`. Accept either layout so a bundled build — where
        // everything is flattened into `Resources/` — resolves without a second search path.
        let nested = directory.appendingPathComponent("model")
        let root = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("tokenizer.json").path) ? directory : nested

        func config(_ name: String) throws -> Config {
            let data = try Data(contentsOf: root.appendingPathComponent(name))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [NSString: Any] else {
                throw EditingRuntimeError.weightsUnavailable
            }
            return Config(object)
        }
        // `strict: false` because `tokenizer_config.json` names `TokenizersBackend`, which is not
        // a class swift-transformers knows; the fallback to the generic BPE path is correct here
        // and `MMBERTTokenizerParityTests` is what proves it rather than assumption.
        return try AutoTokenizer.from(tokenizerConfig: try config("tokenizer_config.json"),
                                      tokenizerData: try config("tokenizer.json"),
                                      strict: false)
    }

    // MARK: - Encoding

    func encode(_ pieces: [String]) async throws -> EditingRuntimeOutput {
        lock.lock()
        let state = loaded
        lock.unlock()
        guard let state else { throw EditingRuntimeError.notLoaded }

        // One group per trained "word": a word piece plus whatever trailing punctuation pieces
        // followed it. Training saw `deploy.` as one unit with a punctuation *state*; feeding the
        // period as its own position would put the model outside its training distribution at
        // exactly the position the punctuation head is judged on.
        let groups = Self.group(pieces)
        guard !groups.isEmpty else {
            return EditingRuntimeOutput(shape: .short, tokens: [])
        }

        var perGroup = [EditingTokenLogits](repeating: .neutral, count: groups.count)
        var largest = EditingSequenceShape.short

        // Sub-word count, not word count, decides the split. `MMBERTEditingModel` windows by 128
        // *tokens*, and Hebrew and Russian run well over one sub-word per word, so a 128-word
        // window routinely exceeds the longest compiled shape. Overflowing is the runtime's
        // problem to solve, not the caller's to know about.
        var batchStart = 0
        while batchStart < groups.count {
            let batch = try Self.batch(groups, from: batchStart, tokenizer: state.tokenizer)
            guard batch.count > 0 else {
                // A single word longer than the window. Nothing to say about it; leave it neutral
                // and move on rather than stalling the pass.
                batchStart += 1
                continue
            }
            let shape = try Self.shape(forTokenCount: batch.ids.count + 2)
            largest = max(largest, shape)
            guard let model = state.models[shape] else { throw EditingRuntimeError.notLoaded }

            let raw = try Self.predict(model: model, shape: shape, batch: batch, state: state)
            for (offset, heads) in raw.enumerated() {
                perGroup[batchStart + offset] = Self.synthesize(
                    raw: heads,
                    punctuationState: batch.punctuationState[offset],
                    caseState: batch.caseState[offset],
                    hasTrail: batch.hasTrail[offset])
            }
            batchStart += batch.count
        }

        // Back from groups to pieces: the group's logits land on its word piece, and every
        // punctuation piece it absorbed is neutral. A punctuation token is not something the
        // tagger has an opinion about — its opinion is expressed as the preceding word's state.
        var perPiece = [EditingTokenLogits](repeating: .neutral, count: pieces.count)
        for (index, group) in groups.enumerated() where group.pieceIndex >= 0 {
            perPiece[group.pieceIndex] = perGroup[index]
        }
        return EditingRuntimeOutput(shape: largest, tokens: perPiece)
    }

    // MARK: - Grouping

    /// A trained "word": its core text, the punctuation that trails it, and where its logits go.
    private struct Group {
        let core: String
        let trail: String
        /// Index in the caller's `pieces` that receives this group's logits, or `-1` for a group
        /// that owns no word (leading punctuation), which never produces an edit.
        let pieceIndex: Int

        var raw: String { core + trail }
    }

    private static func group(_ pieces: [String]) -> [Group] {
        var groups: [Group] = []
        for (index, piece) in pieces.enumerated() {
            let isWord = piece.contains { $0.isLetter || $0.isNumber }
            if isWord || groups.isEmpty {
                groups.append(Group(core: piece, trail: "", pieceIndex: isWord ? index : -1))
            } else if isTrailing(piece), let last = groups.popLast() {
                groups.append(Group(core: last.core, trail: last.trail + piece,
                                    pieceIndex: last.pieceIndex))
            } else {
                groups.append(Group(core: piece, trail: "", pieceIndex: -1))
            }
        }
        return groups
    }

    /// The trailing set from `common.py`, verbatim. An opening bracket or quote is *not* here:
    /// it belongs to the next word, and absorbing it would shift every subsequent alignment.
    private static func isTrailing(_ piece: String) -> Bool {
        let trailing = Set(".,?!;:…—-–\"'“”’»«)]}")
        return !piece.isEmpty && piece.allSatisfy { trailing.contains($0) }
    }

    // MARK: - Tokenization

    private struct Batch {
        /// Sub-word IDs for the words in this batch, without `bos` / `eos`.
        var ids: [Int] = []
        /// Position of each word's first sub-word, offset by one for the leading `bos`.
        var firstSubword: [Int] = []
        /// Current punctuation state per word, indexed into `trainedPunctuation`.
        var punctuationState: [Int] = []
        /// Current casing state per word, `nil` for a word with no cased characters.
        var caseState: [TrainedCase?] = []
        /// Whether the word already carries trailing punctuation.
        var hasTrail: [Bool] = []

        var count: Int { firstSubword.count }
    }

    private static func batch(_ groups: [Group], from start: Int,
                              tokenizer: any Tokenizer) throws -> Batch {
        var batch = Batch()
        var index = start
        while index < groups.count {
            let group = groups[index]
            // The leading space is not decoration: with a Metaspace pre-tokenizer, `" run"` and
            // `"run"` are different sub-word sequences, and `common.py` prefixes every word after
            // the first. Batch boundaries reproduce that — the first word of a *continuation*
            // batch is still mid-sentence, so it keeps its space.
            let text = (index == 0 ? group.raw : " " + group.raw)
            let pieces = tokenizer.encode(text: text, addSpecialTokens: false)
            guard !pieces.isEmpty else { index += 1; continue }
            // +2 for bos and eos.
            guard batch.ids.count + pieces.count + 2 <= maximumTokens else { break }

            batch.firstSubword.append(batch.ids.count + 1)
            batch.ids.append(contentsOf: pieces)
            batch.punctuationState.append(punctuationState(of: group.trail))
            batch.caseState.append(caseState(of: group.core))
            batch.hasTrail.append(!normalizedTrail(group.trail).isEmpty)
            index += 1
        }
        return batch
    }

    /// `common.py.normalise_punct`, reproduced: quotes stripped, ellipsis first, then the
    /// strongest mark in a fixed precedence, then dashes.
    private static func normalizedTrail(_ trail: String) -> String {
        let quotes = Set("\"'“”’»«)]}")
        let stripped = trail.filter { !quotes.contains($0) }
        guard !stripped.isEmpty else { return "" }
        if stripped.contains("...") || stripped.contains("…") { return "…" }
        for mark in "?!.;:," where stripped.contains(mark) { return String(mark) }
        if stripped.contains(where: { $0 == "—" || $0 == "–" || $0 == "-" }) { return "—" }
        return ""
    }

    private static func punctuationState(of trail: String) -> Int {
        trainedPunctuation.firstIndex(of: normalizedTrail(trail)) ?? 0
    }

    /// `nil` when no character of the word has a case pair — all of Hebrew, every number, every
    /// symbol. That is how the casing head is made a structural no-op for Hebrew rather than a
    /// source of noise, and it matches `common.py.has_case` exactly.
    private static func caseState(of core: String) -> TrainedCase? {
        let cased = core.filter { $0.lowercased() != $0.uppercased() }
        guard let first = cased.first else { return nil }
        if cased.count > 1, cased.allSatisfy({ $0.isUppercase }) { return .upper }
        return first.isUppercase ? .cap : .lower
    }

    private static func shape(forTokenCount count: Int) throws -> EditingSequenceShape {
        guard let shape = EditingSequenceShape.fitting(count) else {
            throw EditingRuntimeError.sequenceTooLong(count)
        }
        return shape
    }

    // MARK: - Prediction

    /// The four heads the model actually has, before any of this file's reinterpretation. Split
    /// out so `MMBERTRuntimeTests` can compare these against Core ML run from Python: the
    /// tokenisation, the first-sub-word alignment and the padding are reimplemented here and each
    /// fails *plausibly* rather than loudly — a one-position alignment shift returns the previous
    /// word's punctuation, which reads as a mediocre model and not as a bug.
    struct RawWordHeads: Sendable {
        let error: [Float]
        let punctuation: [Float]
        let casing: [Float]
        let disfluency: [Float]
    }

    /// Raw four-head logits per word, keyed to the words `group(_:)` derives from `pieces`.
    /// Test-facing; production goes through `encode`.
    func rawHeads(for pieces: [String]) async throws
        -> [(word: String, ids: [Int], heads: RawWordHeads)] {
        lock.lock()
        let state = loaded
        lock.unlock()
        guard let state else { throw EditingRuntimeError.notLoaded }

        let groups = Self.group(pieces)
        var result: [(String, [Int], RawWordHeads)] = []
        var start = 0
        while start < groups.count {
            let batch = try Self.batch(groups, from: start, tokenizer: state.tokenizer)
            guard batch.count > 0 else { start += 1; continue }
            let shape = try Self.shape(forTokenCount: batch.ids.count + 2)
            guard let model = state.models[shape] else { throw EditingRuntimeError.notLoaded }
            let raw = try Self.predict(model: model, shape: shape, batch: batch, state: state)
            for (offset, heads) in raw.enumerated() {
                // Sub-word span of this word, recovered from the first-sub-word offsets. Reported
                // so a parity failure says *which* word tokenised differently instead of only
                // that some logit moved.
                let from = batch.firstSubword[offset] - 1
                let to = offset + 1 < batch.count ? batch.firstSubword[offset + 1] - 1 : batch.ids.count
                result.append((groups[start + offset].raw, Array(batch.ids[from..<to]), heads))
            }
            start += batch.count
        }
        return result
    }

    private static func predict(model: MLModel, shape: EditingSequenceShape,
                                batch: Batch, state: Loaded) throws -> [RawWordHeads] {
        let length = shape.rawValue
        let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)

        let sequence = [state.bos] + batch.ids + [state.eos]
        for position in 0..<length {
            let inside = position < sequence.count
            ids[position] = NSNumber(value: Int32(inside ? sequence[position] : state.pad))
            mask[position] = NSNumber(value: Int32(inside ? 1 : 0))
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        let prediction = try model.prediction(from: input)

        guard let error = prediction.featureValue(for: "error_logits")?.multiArrayValue,
              let punct = prediction.featureValue(for: "punct_logits")?.multiArrayValue,
              let casing = prediction.featureValue(for: "case_logits")?.multiArrayValue,
              let disfluency = prediction.featureValue(for: "disf_logits")?.multiArrayValue else {
            throw EditingRuntimeError.notLoaded
        }

        return (0..<batch.count).map { word in
            let position = batch.firstSubword[word]
            return RawWordHeads(
                error: row(error, at: position, width: 2),
                punctuation: row(punct, at: position, width: trainedPunctuation.count),
                casing: row(casing, at: position, width: TrainedCase.allCases.count),
                disfluency: row(disfluency, at: position, width: 2))
        }
    }

    /// One `(1, L, C)` row.
    ///
    /// Read through `NSNumber` rather than `dataPointer`: the graph is FP16, and whether Core ML
    /// hands back `.float16` or `.float32` depends on the compute unit it actually chose. A raw
    /// `assumingMemoryBound(to: Float32.self)` would read half-precision bytes as single and
    /// return convincing garbage. Nine values per token per head is nothing against a 1.3 ms
    /// prediction; a silently wrong logit is not.
    private static func row(_ array: MLMultiArray, at position: Int, width: Int) -> [Float] {
        let base = position * width
        guard base + width <= array.count else { return [Float](repeating: 0, count: width) }
        return (0..<width).map { array[base + $0].floatValue }
    }

    // MARK: - Head synthesis

    /// Turn four trained heads into the interface's heads.
    ///
    /// Everything is computed in probability space and returned as log-probabilities. The policy
    /// softmaxes what it is handed, and `softmax(log p) == p`, so this is exact rather than an
    /// approximation — while letting the folding, suppression and independence assumptions below
    /// be written as the probability statements they actually are.
    private static func synthesize(raw: RawWordHeads,
                                   punctuationState: Int,
                                   caseState: TrainedCase?,
                                   hasTrail: Bool) -> EditingTokenLogits {
        let errorProbabilities = MMBERTEditingModel.softmax(raw.error)
        let disfluencyProbabilities = MMBERTEditingModel.softmax(raw.disfluency)

        // --- punctuation: absolute target, folded into the interface's label space ---
        var punctuationLogits = raw.punctuation
        if punctuationState < punctuationLogits.count { punctuationLogits[punctuationState] += keepPrior }
        let trained = MMBERTEditingModel.softmax(punctuationLogits)
        var punctuationProbabilities = [Float](repeating: 0, count: EditingPunctuationLabel.allCases.count)
        if hasTrail {
            // Sacrifice 1 from the header: the mark is already there and `insertAfter` cannot
            // replace it.
            punctuationProbabilities[EditingPunctuationLabel.none.rawValue] = 1
        } else {
            for (index, probability) in trained.enumerated() where index < punctuationMapping.count {
                punctuationProbabilities[punctuationMapping[index].rawValue] += probability
            }
        }

        // --- casing: absolute target, re-expressed as keep / lower / capitalize / upper ---
        var casingProbabilities = [Float](repeating: 0, count: EditingCasingLabel.allCases.count)
        if let caseState {
            var casingLogits = raw.casing
            casingLogits[caseState.rawValue] += keepPrior
            let trainedCase = MMBERTEditingModel.softmax(casingLogits)
            let slots: [EditingCasingLabel] = [.lower, .capitalize, .upper]
            for (index, probability) in trainedCase.enumerated() {
                let slot = index == caseState.rawValue ? EditingCasingLabel.keep : slots[index]
                casingProbabilities[slot.rawValue] += probability
            }
        } else {
            casingProbabilities[EditingCasingLabel.keep.rawValue] = 1
        }

        // --- operation: the three action heads treated as independent ---
        //
        // Independence is an assumption and it is the conservative one here: it makes P(keep) the
        // product of three no-change probabilities, so any one head being unsure pulls the whole
        // token toward KEEP. A joint operation head would need joint supervision, which this
        // corpus does not carry.
        let deletion = disfluencyProbabilities[EditingDisfluencyLabel.drop.rawValue]
        let insertion = 1 - punctuationProbabilities[EditingPunctuationLabel.none.rawValue]
        let replacement = 1 - casingProbabilities[EditingCasingLabel.keep.rawValue]
        let keep = punctuationProbabilities[EditingPunctuationLabel.none.rawValue]
            * casingProbabilities[EditingCasingLabel.keep.rawValue]
            * (1 - deletion)
        let operation = normalized([keep, replacement, deletion, insertion])

        return EditingTokenLogits(logits: [
            .error: logs(errorProbabilities),
            .operation: logs(operation),
            .punctuation: logs(punctuationProbabilities),
            .casing: logs(casingProbabilities),
            .disfluency: logs(disfluencyProbabilities),
            // structure / language / semanticRisk: not trained, therefore not emitted. See header.
        ])
    }

    private static func normalized(_ values: [Float]) -> [Float] {
        let total = values.reduce(0, +)
        guard total > 0 else {
            var uniform = [Float](repeating: 0, count: values.count)
            uniform[0] = 1
            return uniform
        }
        return values.map { $0 / total }
    }

    /// Log-probabilities with a floor. A hard zero would become `-inf`, and `-inf` minus `-inf`
    /// in the policy's max-subtracted softmax is `NaN`, which compares false against every
    /// threshold — silently, and in the direction of doing nothing only by luck.
    private static func logs(_ probabilities: [Float]) -> [Float] {
        probabilities.map { logf(max($0, 1e-9)) }
    }
}
