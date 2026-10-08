//
//  Qwen3ASREngine.swift
//  Whisperer
//
//  Qwen3-ASR-1.7B on MLX: batched prefill of the whole audio prompt in one forward pass,
//  then greedy decoding with a KV cache. Not thread-safe — the bridge serialises every call.
//

import Foundation
import Hub
import MLX
import MLXLMCommon

nonisolated final class Qwen3ASREngine {

    // MARK: - Model location

    static let repoId = "mlx-community/Qwen3-ASR-1.7B-8bit"
    static let downloadGlobs = ["*.json", "*.safetensors", "merges.txt"]
    /// Shown on the download button.
    static let downloadSizeLabel = "2.5 GB"

    /// Snapshot directory under HubApi's default `downloadBase` (same root the LLM uses).
    static func modelDirectory() -> URL {
        HubApi().localRepoLocation(Hub.Repo(id: repoId))
    }

    static func isModelCached() -> Bool {
        let dir = modelDirectory()
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await HubApi().snapshot(from: repoId, matching: downloadGlobs) { p in
            progress(p.fractionCompleted)
        }
    }

    // MARK: - Prompt tokens (verified against the checkpoint's tokenizer)

    enum Token {
        static let asrText: Int32 = 151_704       // <asr_text>
        static let eos: Set<Int32> = [151_643, 151_645]  // <|endoftext|>, <|im_end|>
        static let specialFloor: Int32 = 151_643  // everything at/above is a control token
    }

    /// `<|im_start|>system\n<|im_end|>\n<|im_start|>user\n<|audio_start|>`
    static let promptPrefix: [Int32] = [151_644, 8_948, 198, 151_645, 198, 151_644, 872, 198, 151_669]
    /// `<|audio_end|><|im_end|>\n<|im_start|>assistant\n`
    static let promptSuffix: [Int32] = [151_670, 151_645, 198, 151_644, 77_091, 198]

    /// `language <Name>` token ids for forcing a language (the model then skips detection and
    /// starts directly after `<asr_text>`). Keyed by Whisperer's ISO code.
    static let forcedLanguageTokens: [String: [Int32]] = [
        "zh": [11528, 8453], "en": [11528, 6364], "yue": [11528, 72366, 2367],
        "ar": [11528, 34117], "de": [11528, 5938], "fr": [11528, 8585], "es": [11528, 15154],
        "pt": [11528, 42188], "id": [11528, 58829], "it": [11528, 14811], "ko": [11528, 16134],
        "ru": [11528, 8522], "th": [11528, 26392], "vi": [11528, 48477], "ja": [11528, 10769],
        "tr": [11528, 23734], "hi": [11528, 43980], "ms": [11528, 79140], "nl": [11528, 23234],
        "sv": [11528, 30109], "da": [11528, 43680], "fi": [11528, 57853], "pl": [11528, 31984],
        "cs": [11528, 33150], "tl": [11528, 62417], "fa": [11528, 49861], "el": [11528, 17860],
        "ro": [11528, 73597], "hu": [11528, 56769], "mk": [11528, 56452, 75491],
        "he": [11528, 36266],
    ]

    /// Model language names (as it prints them after `language `) → ISO code.
    static let languageCodes: [String: String] = [
        "chinese": "zh", "english": "en", "cantonese": "yue", "arabic": "ar", "german": "de",
        "french": "fr", "spanish": "es", "portuguese": "pt", "indonesian": "id", "italian": "it",
        "korean": "ko", "russian": "ru", "thai": "th", "vietnamese": "vi", "japanese": "ja",
        "turkish": "tr", "hindi": "hi", "malay": "ms", "dutch": "nl", "swedish": "sv",
        "danish": "da", "finnish": "fi", "polish": "pl", "czech": "cs", "filipino": "tl",
        "persian": "fa", "greek": "el", "romanian": "ro", "hungarian": "hu", "macedonian": "mk",
        "hebrew": "he",
    ]

    struct Result {
        let text: String
        /// ISO code the model detected (auto) or was forced to; nil for silence (`language None`).
        let languageCode: String?
        let audioTokens: Int
        let generatedTokens: Int
        let encodeMs: Double
        let prefillMs: Double
        let decodeMs: Double
    }

    // MARK: - State

    private let model: Qwen3ASRMLXModel
    private let vocabulary: [Int32: [UInt8]]
    private let prefixEmbeddings: MLXArray
    private let suffixEmbeddings: MLXArray

    private init(model: Qwen3ASRMLXModel, vocabulary: [Int32: [UInt8]]) {
        self.model = model
        self.vocabulary = vocabulary
        // The fixed prompt halves never change — embed them once.
        prefixEmbeddings = model.embed(Self.promptPrefix)
        suffixEmbeddings = model.embed(Self.promptSuffix)
        eval(prefixEmbeddings, suffixEmbeddings)
    }

    static func load(from directory: URL = modelDirectory()) throws -> Qwen3ASREngine {
        let model = try Qwen3ASRMLXModel.load(from: directory)
        let vocabulary = try Qwen3ASRVocabulary.load(
            vocab: directory.appendingPathComponent("vocab.json"),
            tokenizerConfig: directory.appendingPathComponent("tokenizer_config.json"))
        return Qwen3ASREngine(model: model, vocabulary: vocabulary)
    }

    /// Compiles the Metal kernels and specialises the MLX graphs for the shape classes the first
    /// real dictation will hit.
    ///
    /// The old warm-up ran exactly one pass: 1.0 s of zeros, forced `en`, 4 tokens. That is a
    /// single point in a shape space the live preview sweeps continuously, and MLX re-specialises
    /// per input shape, so almost every pass of the first session was still cold. Measured: the
    /// first pass of a session cost `enc ~350ms prefill ~650ms` against `enc 30ms prefill 62ms`
    /// hot, and one first pass at a large window cost `enc 3446ms prefill 11511ms`. That is
    /// 15.5 s in which an 18-second recording displayed no text at all.
    ///
    /// Three things were uncovered, not one:
    ///
    /// - **Window length.** The preview starts at ~0.3 s and grows to `previewWindowCap`, and
    ///   every distinct length is a new sequence length for the audio tower and for the prefill
    ///   attention. The sweep below spans that range instead of sampling one point in it.
    /// - **Prompt layout.** A preview pass calls `transcribe` with `languageCode: nil`, which
    ///   skips the `language X<asr_text>` tokens appended for a forced language and therefore
    ///   prefills a differently shaped prompt. The old warm-up only ever warmed the forced
    ///   layout, so the layout the preview actually uses was never touched.
    /// - **The decode step.** Warming prefill does not warm the single-token decode graph. A few
    ///   generated tokens per window are enough to build it, and they are cheap.
    ///
    /// Audio is low-amplitude noise rather than zeros. Silence drives every mel bin to the log
    /// floor, so the audio tower sees a constant input, the model emits `language None`, and it
    /// can pick EOS on its very first token — which returns before the decode graph is ever
    /// built. Noise at about -60 dBFS is still nowhere near speech, but it produces a
    /// non-degenerate mel, a real language header, and a decode that runs the whole token
    /// budget. The compiled shapes are identical either way; what differs is which code paths
    /// execute. The generator is a fixed-seed LCG so two launches warm identically.
    ///
    /// Cost: five passes over 22.5 s of synthetic audio with a 6-token budget each. The per-pass
    /// cost is dominated by the cold encode and prefill this is paying off in advance, so expect
    /// a few seconds in total; `loadFromCache` logs the exact figure as `warm-up <n>ms` and the
    /// `Logger.debug` lines below break it down per window. Nothing waits on this — it runs on
    /// the model-load path at launch — but it stays a bounded, fixed set of passes so it cannot
    /// grow into tens of seconds.
    ///
    /// - Parameter previewWindowCap: longest window to warm, in seconds. Defaults to
    ///   ``previewWindowCapSeconds``.
    func warmUp(previewWindowCap: Double = Qwen3ASREngine.previewWindowCapSeconds) {
        // Fractions of the cap rather than absolute lengths, so raising the cap moves the whole
        // sweep instead of leaving a cold gap at the top.
        let windows = [0.0625, 0.25, 0.5, 1.0].map { $0 * previewWindowCap }

        for seconds in windows {
            let t0 = CFAbsoluteTimeGetCurrent()
            // languageCode: nil — the auto-detect layout the live preview uses.
            _ = try? transcribe(samples: Self.warmUpSamples(seconds: seconds),
                                languageCode: nil, maxNewTokens: 6)
            Logger.debug(
                String(format: "Qwen3ASR warm-up auto %.1fs: %.0fms", seconds,
                       (CFAbsoluteTimeGetCurrent() - t0) * 1000),
                subsystem: .model)
        }

        // One forced-language pass at the top of the range. Committed chunks and the stop-path
        // tail run forced once the language is pinned, and the forced prompt is three tokens
        // longer, so it is its own prefill shape.
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = try? transcribe(samples: Self.warmUpSamples(seconds: previewWindowCap),
                            languageCode: "en", maxNewTokens: 6)
        Logger.debug(
            String(format: "Qwen3ASR warm-up forced %.1fs: %.0fms", previewWindowCap,
                   (CFAbsoluteTimeGetCurrent() - t0) * 1000),
            subsystem: .model)
    }

    /// Longest window the live preview will ever ask for.
    ///
    /// This mirrors `Qwen3ASRBridge.streamingPolicy.previewWindowCap`, which cannot be read from
    /// here: `streamingPolicy` is an instance property and `Qwen3ASRBridge.loadFromCache` warms
    /// the engine up *before* it constructs the bridge that owns the policy. `warmUp` therefore
    /// takes the cap as a parameter, so a caller holding a policy can pass the real value, and
    /// this constant only serves the current no-argument call. Keep the two in step: a cap above
    /// this leaves the largest preview shape cold on the first pass of the first session, which
    /// is the single most expensive pass there is.
    /// Longest preview window the warm-up sweeps to, when the caller does not say.
    ///
    /// The authority is `Qwen3ASRBridge.streamingPolicy.previewWindowCap`; this is the fallback
    /// for callers that have no bridge yet. `loadFromCache` warms the engine *before* it builds
    /// the bridge, so it passes the policy value in explicitly — see the call there. Keep the two
    /// in step: a stale value here only costs a cold shape at the top of the range, but that is
    /// exactly the 15.5 s first pass this warm-up exists to prevent.
    static let previewWindowCapSeconds: Double = 8.0

    /// Deterministic low-amplitude noise for the warm-up, in place of silence.
    ///
    /// A plain LCG rather than `SystemRandomNumberGenerator`: the sequence must not vary between
    /// launches, or a warm-up regression cannot be told apart from a different random draw.
    private static func warmUpSamples(seconds: Double) -> [Float] {
        let count = Int(seconds * Double(Qwen3ASRFeatureExtractor.sampleRate))
        var state: UInt32 = 0x2545_F491
        var samples = [Float]()
        samples.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            // 24 high bits → [0, 1), recentred to [-1, 1), then scaled to about -60 dBFS.
            let unit = Float(state >> 8) / Float(1 << 24)
            samples.append((unit - 0.5) * 2e-3)
        }
        return samples
    }

    // MARK: - Transcription

    /// - Parameters:
    ///   - languageCode: ISO code to force, or nil to let the model detect it.
    ///   - onPartial: called on the calling thread after each token with the transcript-so-far
    ///     and the language code from the `language X` header (the forced code when forced).
    ///   - shouldAbort: polled before prefill and between tokens.
    func transcribe(
        samples: [Float],
        languageCode: String?,
        maxNewTokens: Int? = nil,
        onPartial: ((String, String?) -> Void)? = nil,
        shouldAbort: () -> Bool = { false }
    ) throws -> Result {
        let seconds = Double(samples.count) / Double(Qwen3ASRFeatureExtractor.sampleRate)
        let empty = Result(text: "", languageCode: nil, audioTokens: 0, generatedTokens: 0,
                           encodeMs: 0, prefillMs: 0, decodeMs: 0)
        guard seconds >= 0.1, !shouldAbort() else { return empty }

        // 1. Audio → embeddings.
        let t0 = CFAbsoluteTimeGetCurrent()
        let (mel, frames) = Qwen3ASRFeatureExtractor.shared.extract(samples: samples)
        let features = MLXArray(mel, [Qwen3ASRFeatureExtractor.nMels, frames])
            .asType(prefixEmbeddings.dtype)
        let audio = model.audioTower(features).asType(prefixEmbeddings.dtype)
        eval(audio)
        let t1 = CFAbsoluteTimeGetCurrent()
        guard !shouldAbort() else { return empty }

        // 2. Prompt = prefix ++ audio ++ suffix [++ "language X<asr_text>"], prefilled in one pass.
        var pieces = [prefixEmbeddings, audio, suffixEmbeddings]
        let forced = languageCode.flatMap { Self.forcedLanguageTokens[$0] }
        if let forced {
            pieces.append(model.embed(forced + [Token.asrText]))
        }
        let prompt = concatenated(pieces, axis: 0).expandedDimensions(axis: 0)
        let cache = model.newCache()
        var logits = model.lastLogits(embeddings: prompt, cache: cache)
        var next = argMax(logits, axis: -1).reshaped(-1)
        eval(next)
        let t2 = CFAbsoluteTimeGetCurrent()

        // 3. Greedy decode. A generous but finite budget: speech runs ~3-5 tokens/s, so 15/s
        // plus the language header only binds on a degenerate repetition loop.
        let budget = maxNewTokens ?? min(2_048, 24 + Int(seconds * 15))
        var generated: [Int32] = []
        generated.reserveCapacity(budget)
        var inText = forced != nil
        var textStart = 0
        var headerLanguage: String? = forced != nil ? languageCode : nil
        var tokensSinceLoopCheck = 0
        for _ in 0..<budget {
            let token = next.item(Int32.self)
            if Token.eos.contains(token) { break }
            generated.append(token)
            if !inText, token == Token.asrText {
                inText = true
                textStart = generated.count
                headerLanguage = headerLanguageCode( Array(generated.dropLast()))
            }
            if shouldAbort() { break }
            // Queue the next step before touching the CPU-side partial callback.
            logits = model.lastLogits(embeddings: model.embed([token]).expandedDimensions(axis: 0),
                                      cache: cache)
            next = argMax(logits, axis: -1).reshaped(-1)
            asyncEval(next)
            if inText, let onPartial {
                onPartial(decode(Array(generated[textStart...])), headerLanguage)
            }

            // Stop a greedy decode that has started looping, rather than letting it spend the
            // whole budget on copies of the same phrase.
            //
            // Greedy decoding with no sampling has no escape from a repetition attractor: once
            // the model's argmax cycles, it cycles until the budget runs out. A 20-minute
            // session produced `в глубь, в глубь, в глубь,` — a phrase that appears in none of
            // the source recordings, so it is invented, not heard.
            //
            // `isHallucination` in `StreamingTranscriber` already rejects a looping *chunk*,
            // but a loop that emits one copy per chunk clears that guard three times over and
            // only looks degenerate once the chunks are joined. Catching it here, inside the
            // decode that creates it, is the only place it is still one object.
            //
            // Checked every `loopCheckInterval` tokens: `containsLoop` is linear in the word
            // count, and a real loop needs at least nine words to exist, so nothing is missed
            // by not checking per token.
            if inText {
                tokensSinceLoopCheck += 1
                if tokensSinceLoopCheck >= Self.loopCheckInterval,
                   generated.count - textStart >= Self.loopCheckMinimumTokens {
                    tokensSinceLoopCheck = 0
                    let soFar = decode(Array(generated[textStart...]))
                    if TranscriptRepetition.containsLoop(words: soFar.split(separator: " ")) {
                        Logger.warning(
                            "Qwen3ASR decode stopped on a repetition loop after \(generated.count) tokens",
                            subsystem: .transcription)
                        break
                    }
                }
            }
        }
        let t3 = CFAbsoluteTimeGetCurrent()

        // 4. Split "language X<asr_text>body".
        let text: String
        let detected: String?
        if forced != nil, let code = languageCode {
            text = decode(generated)
            detected = code
        } else if let sep = generated.firstIndex(of: Token.asrText) {
            detected = headerLanguageCode( Array(generated[..<sep]))
            text = decode(Array(generated[(sep + 1)...]))
        } else {
            // No header (truncated by abort/budget) — treat whatever came out as text.
            text = decode(generated)
            detected = nil
        }

        trimCacheIfNeeded()

        return Result(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            languageCode: detected,
            audioTokens: audio.dim(0),
            generatedTokens: generated.count,
            encodeMs: (t1 - t0) * 1000,
            prefillMs: (t2 - t1) * 1000,
            decodeMs: (t3 - t2) * 1000)
    }

    /// Releases MLX's buffer cache when it has grown past the ceiling. Runs after every pass, so
    /// it must stay on the ceiling only — see `releaseCachedBuffers()` for the memory-pressure arm.
    ///
    /// The free-RAM arm used to live here too, and it was the single largest source of per-pass
    /// latency variance. `cacheTrimHeadroomGB` is 3.0, and with the 2.5 GB ASR model plus an LLM
    /// resident the machine is routinely under that, so the OR-branch fired on *every* pass and
    /// the next pass re-allocated every buffer from scratch. That is the recurring
    /// `enc ~350ms prefill ~650ms` against `enc 30ms prefill 62ms` hot, repeating once per
    /// dictation — it reads like a cold model but it is a cold allocator.
    ///
    /// "Clearing early costs a re-allocation on the next pass, which is microseconds" was the
    /// original justification. Measured on the live preview it is ~900 ms, not microseconds,
    /// because the re-allocation drags Metal heap setup and graph specialisation with it.
    private func trimCacheIfNeeded() {
        let cached = Memory.cacheMemory
        guard cached > 64 * 1024 * 1024 else { return }
        if cached > Self.cacheCeilingBytes {
            Memory.clearCache()
        }
    }

    /// The memory-pressure arm of the cache trim, called once a recording has produced its final
    /// text rather than after every pass.
    ///
    /// The pressure this guards against is real but it is not per-pass: a meeting keeps this
    /// engine resident for the whole recording and the post-meeting tail loads the 3.2 GB
    /// Qwen3.5 overview model on the same MLX allocator, so half a gigabyte of cached buffers is
    /// half a gigabyte the LLM cannot have. That hand-off happens at the end of a recording,
    /// which is exactly when this runs — and nothing the user is waiting on follows it.
    ///
    /// Keyed on free memory rather than on a meeting flag so there is nothing to keep in sync —
    /// `ModelWorkQueue`'s gate is actor-isolated and cannot be read from this synchronous path
    /// anyway.
    /// - Returns: true if the cache was actually cleared, so the caller can re-warm.
    @discardableResult
    func releaseCachedBuffers() -> Bool {
        let cached = Memory.cacheMemory
        guard cached > 64 * 1024 * 1024 else { return false }
        guard cached > Self.cacheCeilingBytes
                || SystemMemory.availableGB() < Self.cacheTrimHeadroomGB else { return false }
        Memory.clearCache()
        Logger.debug(String(format: "Qwen3ASR released %.0f MB of MLX buffer cache",
                            Double(cached) / 1_048_576),
                     subsystem: .model)
        return true
    }

    /// Rebuilds the allocator state a `releaseCachedBuffers()` just threw away.
    ///
    /// Clearing the cache at the end of a dictation moved the whole re-allocation onto the
    /// *next* dictation's first preview pass, which is the worst possible place for it: measured
    /// `enc 411ms prefill 771ms` against `enc 90ms prefill 102ms` on the pass immediately after,
    /// and it reads to the user as "the first one was slow, the second was fine". The trim before
    /// this change ran after every pass and so kept the cache permanently small — less total
    /// latency per pass, but the same cost smeared across all of them.
    ///
    /// Re-warming here gets both: the cache is genuinely released for whatever needs the memory,
    /// and the allocator is hot again before the user presses the key. Nothing waits on it — it
    /// runs after the final decode, while the polished text is already being pasted.
    ///
    /// Only the two smallest windows, because re-allocation is what is being paid for here, not
    /// graph compilation — the compiled graphs survive `clearCache()`.
    func rewarmAfterCacheRelease() {
        let t0 = CFAbsoluteTimeGetCurrent()
        for seconds in [0.5, 2.0] {
            _ = try? transcribe(samples: Self.warmUpSamples(seconds: seconds),
                                languageCode: nil, maxNewTokens: 4)
        }
        Logger.debug(String(format: "Qwen3ASR re-warmed after cache release in %.0fms",
                            (CFAbsoluteTimeGetCurrent() - t0) * 1000),
                     subsystem: .model)
    }

    /// Tokens between repetition checks during decoding. A loop needs at least three copies of
    /// a three-word phrase to register, so checking this often cannot miss one it would catch.
    ///
    /// Halved from 16 because the check is cheap relative to what it saves. A degenerate greedy
    /// decode has no escape from its attractor, so every token after the loop starts is pure
    /// waste: measured `13.1s audio → 220 gen tok | decode 4556ms` and
    /// `5.3s audio → 103 gen tok | decode 1983ms`, both discarded as hallucinations afterwards.
    /// 59 passes in one day exceeded 80 generated tokens. `containsLoop` is linear in word count
    /// over a sub-250-token buffer; catching the loop 8 tokens sooner is worth that.
    private static let loopCheckInterval = 8
    /// Do not look for a loop before this many text tokens — `containsLoop` cannot fire below
    /// nine words and the decode is at its most expensive per token early on.
    private static let loopCheckMinimumTokens = 32

    /// Cached MLX buffers above this are released regardless of free memory.
    private static let cacheCeilingBytes = 512 * 1024 * 1024
    /// Below this much free RAM, trim the cache at the first opportunity.
    private static let cacheTrimHeadroomGB: Double = 3.0

    /// ISO code for a `language <Name>` header; nil for `language None` (silence) or unknown names.
    private func headerLanguageCode(_ tokens: [Int32]) -> String? {
        let header = decode(tokens).trimmingCharacters(in: .whitespaces).lowercased()
        let name = header.hasPrefix("language ") ? String(header.dropFirst(9)) : header
        return Self.languageCodes[name.trimmingCharacters(in: .whitespaces)]
    }

    /// Byte-level BPE detokenisation; control tokens are dropped.
    private func decode(_ tokens: [Int32]) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(tokens.count * 4)
        for t in tokens where t < Token.specialFloor {
            if let b = vocabulary[t] { bytes.append(contentsOf: b) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Vocabulary

nonisolated enum Qwen3ASRVocabulary {
    /// Token id → raw UTF-8 bytes, decoded from GPT-2 byte-level `vocab.json`.
    static func load(vocab: URL, tokenizerConfig: URL) throws -> [Int32: [UInt8]] {
        let data = try Data(contentsOf: vocab)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw Qwen3ASRError.invalidModel("vocab.json is not {token: id}")
        }
        let byteDecoder = gpt2ByteDecoder()
        var out: [Int32: [UInt8]] = [:]
        out.reserveCapacity(dict.count)
        for (piece, id) in dict {
            out[Int32(id)] = piece.unicodeScalars.compactMap { byteDecoder[$0.value] }
        }
        return out
    }

    /// Inverse of GPT-2 `bytes_to_unicode()`.
    private static func gpt2ByteDecoder() -> [UInt32: UInt8] {
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var codepoints = printable
        var n = 0
        for b in 0..<256 where !printable.contains(b) {
            printable.append(b)
            codepoints.append(256 + n)
            n += 1
        }
        var decoder: [UInt32: UInt8] = [:]
        for (b, c) in zip(printable, codepoints) { decoder[UInt32(c)] = UInt8(b) }
        return decoder
    }
}
