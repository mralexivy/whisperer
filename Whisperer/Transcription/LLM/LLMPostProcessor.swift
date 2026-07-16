//
//  LLMPostProcessor.swift
//  Whisperer
//
//  Local LLM post-processor using MLXLLM (Qwen3) for transcription refinement
//

import Foundation
import Combine
import MLX
import MLXLLM
import MLXLMCommon
import Hub
import Tokenizers

enum LLMLoadPhase: Equatable {
    case idle
    case downloading(progress: Double)
    case loading
    case ready
    case error(String)
}

@MainActor
class LLMPostProcessor: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isLoading = false
    @Published var isProcessing = false
    @Published var loadPhase: LLMLoadPhase = .idle
    @Published var errorMessage: String?

    private var modelContainer: ModelContainer?
    private var loadedVariant: LLMModelVariant?

    // Per-instructions KV caches — keyed on the full instructions string (system prompt + language).
    // Capped at 4 entries with FIFO eviction. Each value is a warmed prompt prefix ready to copy().
    private var cachedPrompts: [String: [any KVCache]] = [:]
    private var cachedPromptOrder: [String] = []
    private static let maxCachedPrompts = 4

    // Deduplicates concurrent warmup requests. Tracks which instructions are currently warming.
    private var warmupTask: Task<Void, Never>?
    private var warmingUpInstructions: String?

    // Download progress — promoted from local var to avoid @Sendable capture hazard.
    private var didReceiveDownloadProgress = false

    // MARK: - Model Management

    func loadModel(_ variant: LLMModelVariant) async throws {
        guard !isLoading else {
            Logger.debug("LLM load already in progress, skipping", subsystem: .model)
            return
        }
        guard loadedVariant != variant else {
            Logger.info("LLM \(variant.displayName) already loaded", subsystem: .model)
            return
        }

        Logger.info("Loading LLM \(variant.displayName)...", subsystem: .model)
        isModelLoaded = false
        isLoading = true
        errorMessage = nil
        loadPhase = .loading
        didReceiveDownloadProgress = false

        let configuration = ModelConfiguration(id: variant.huggingFaceId)
        let container = try await loadModelContainer(
            hub: HubApi(),
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    let fraction = progress.fractionCompleted
                    if fraction > 0 {
                        self?.didReceiveDownloadProgress = true
                        self?.loadPhase = .downloading(progress: fraction)
                    }
                }
            }
        )

        // Download done (if it happened) — now loading into memory.
        if didReceiveDownloadProgress {
            loadPhase = .loading
            Logger.info("LLM \(variant.displayName) downloaded, loading into memory...", subsystem: .model)
        }

        modelContainer = container
        loadedVariant = variant
        isModelLoaded = true
        isLoading = false
        loadPhase = .ready
        errorMessage = nil

        // Scale buffer pool cap by model size. Model weights are "active memory" and unaffected;
        // only intermediate/KV-cache buffers from inference are constrained.
        let cacheMB: Int = switch variant {
            case .qwen3_0_6B:     128
            case .qwen3_5_2B:     256
            case .qwen3_5_4B:     256
            case .qwen3_5_4B_mtp: 256
            case .qwen3_5_9B:     512
        }
        Memory.cacheLimit = cacheMB * 1024 * 1024
        Logger.info("LLM \(variant.displayName) loaded (MLX cache limit: \(cacheMB) MB, active: \(Memory.activeMemory / (1024 * 1024)) MB)", subsystem: .model)
    }

    func unloadModel() async {
        // 1. Stop new work — process() guards on modelContainer.
        modelContainer = nil
        loadedVariant = nil
        isModelLoaded = false
        isLoading = false
        loadPhase = .idle
        errorMessage = nil
        warmupTask?.cancel()
        warmupTask = nil
        warmingUpInstructions = nil
        cachedPrompts.removeAll()
        cachedPromptOrder.removeAll()

        // 2. Drain in-flight generation before touching GPU buffers.
        while isProcessing {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        // 3. Fence GPU and free pool. Safe now — no MLX ops are in flight.
        await Task.detached { Stream.gpu.synchronize() }.value
        Memory.clearCache()
        Logger.info("LLM unloaded", subsystem: .model)
    }

    // MARK: - Prompt KV Cache Warmup

    /// Pre-fill the system prompt KV cache once so subsequent process() calls skip prefill.
    /// Called after model load and when the AI mode changes. The 897ms-24s prefill is absorbed
    /// here rather than blocking the first user transcription.
    func warmupPrompt(_ instructions: String) async {
        guard let container = modelContainer else { return }
        guard !instructions.isEmpty else { return }
        if cachedPrompts[instructions] != nil { return }

        // Dedup: if already warming up for this exact prompt, join the in-flight task.
        if warmingUpInstructions == instructions {
            await warmupTask?.value
            return
        }

        // Different instructions — cancel existing warmup and start fresh.
        warmupTask?.cancel()
        warmingUpInstructions = instructions

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runWarmup(container: container, instructions: instructions)
        }
        warmupTask = task
        await task.value

        // Clear on completion (success or cancellation) so next call can restart if needed.
        if warmingUpInstructions == instructions {
            warmingUpInstructions = nil
        }
    }

    private func runWarmup(container: ModelContainer, instructions: String) async {
        guard !Task.isCancelled else { return }
        Logger.debug("LLM warmup: pre-filling system prompt KV cache (\(instructions.count) chars)...", subsystem: .model)

        let warmupSession = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: 1,
                // Match inference quantization so the round-tripped cache is QuantizedKVCache.
                // process() then copies QuantizedKVCache layers consistently on the hot path.
                kvBits: 8,
                kvGroupSize: 64,
                temperature: 0.0,
                topP: 1.0,
                topK: 0,
                repetitionPenalty: 1.0,
                prefillStepSize: 512
            ),
            additionalContext: ["enable_thinking": false]
        )

        let t0 = Date()
        _ = try? await warmupSession.respond(to: ".", images: [], videos: [])
        // GPU barrier off main thread — ensures KV state is committed before saveCache.
        await Task.detached { Stream.gpu.synchronize() }.value
        Logger.debug("LLM warmup: prefill took \(Int(-t0.timeIntervalSinceNow * 1000))ms", subsystem: .model)

        guard !Task.isCancelled else { return }

        // UUID-keyed tmpURL: avoids file collision if warmup is ever restarted mid-flight.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperer_kvcache_\(UUID().uuidString).safetensors")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await warmupSession.saveCache(to: tmpURL)
            guard !Task.isCancelled else { return }

            // ~15-20 MB safetensors read + parse — off main thread to avoid UI stall.
            let caches: [any KVCache] = try await Task.detached {
                let (loaded, _) = try loadPromptCache(url: tmpURL)
                return loaded
            }.value

            guard !Task.isCancelled else { return }

            // Assign into dict atomically — never nil mid-build, so a concurrent process()
            // sees either the previous (valid) cache or the new one, never nil.
            cachedPrompts[instructions] = caches
            cachedPromptOrder.append(instructions)

            // FIFO eviction: cap to maxCachedPrompts entries.
            while cachedPromptOrder.count > Self.maxCachedPrompts {
                let oldest = cachedPromptOrder.removeFirst()
                cachedPrompts.removeValue(forKey: oldest)
            }

            Logger.info("LLM warmup complete: \(caches.count) KV layers cached (active: \(Memory.activeMemory / (1024 * 1024)) MB)", subsystem: .model)
        } catch {
            Logger.warning("LLM warmup failed (fresh sessions will be used): \(error.localizedDescription)", subsystem: .model)
        }
    }

    // MARK: - Processing

    func process(
        text: String,
        systemPrompt: String,
        userMessage: String,
        targetLanguage: String? = nil,
        temperature: Float = 0.0,
        topP: Float = 1.0,
        topK: Int = 0,
        repetitionPenalty: Float = 1.05,
        maxTokensCap: Int = 256
    ) async throws -> String {
        guard let container = modelContainer else {
            Logger.warning("LLM not loaded, returning original text", subsystem: .transcription)
            return text
        }

        guard !systemPrompt.isEmpty else {
            return text
        }

        isProcessing = true
        defer { isProcessing = false }

        var instructions = systemPrompt
        if let lang = targetLanguage, !lang.isEmpty {
            instructions += " Translate to \(lang)."
        }

        // Script-aware token estimation. English heuristic (charCount/4) underestimates
        // for Hebrew/Arabic (~2 chars/token) and CJK (~1 char/token), causing truncated output.
        let charCount = text.count
        let isNonLatin = containsNonLatinScript(text)
        let charsPerToken: Int = isNonLatin ? 2 : 4
        let estimatedTokens = max(4, charCount / charsPerToken)
        let maxTokens: Int
        if charCount < 30 {
            maxTokens = min(maxTokensCap, estimatedTokens + 8)
        } else if charCount < 200 {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)) + 4)
        } else {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)))
        }

        Logger.debug("LLM gen: inputChars=\(charCount) nonLatin=\(isNonLatin) estTokens=\(estimatedTokens) maxTokens=\(maxTokens) cap=\(maxTokensCap) temp=\(temperature) topP=\(topP) topK=\(topK) repPenalty=\(repetitionPenalty)", subsystem: .transcription)

        // MTP fast path — bypasses ChatSession entirely, uses generateMTPTokens() directly.
        if loadedVariant?.isMTPCapable == true {
            let mtpResult = try await processMTP(
                container: container,
                instructions: instructions,
                userMessage: userMessage,
                maxTokens: maxTokens,
                charCount: charCount,
                isNonLatin: isNonLatin,
                maxTokensCap: maxTokensCap,
                targetLanguage: targetLanguage,
                originalText: text
            )
            return mtpResult
        }

        let genParams = GenerateParameters(
            maxTokens: maxTokens,
            // oMLX TurboQuant: 8-bit KV cache — 2x memory reduction, faster attention.
            // Matches kvBits used in warmupPrompt so cached prefix dtype is consistent.
            kvBits: 8,
            kvGroupSize: 64,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            prefillStepSize: 512
        )

        // Use cached prompt KV if available for this exact instructions string.
        // copy() creates an independent deep copy of each KV layer — fast GPU memory copy.
        let cachedKV = cachedPrompts[instructions]
        let usingCache = cachedKV != nil

        let session: ChatSession
        if let cachedKV {
            let freshCache = cachedKV.map { $0.copy() }
            session = ChatSession(
                container,
                instructions: nil,  // Already encoded in the pre-built cache
                cache: freshCache,
                generateParameters: genParams,
                additionalContext: ["enable_thinking": false]
            )
            Logger.debug("LLM gen: cache hit (\(freshCache.count) KV layers)", subsystem: .transcription)
        } else {
            session = ChatSession(
                container,
                instructions: instructions,
                generateParameters: genParams,
                additionalContext: ["enable_thinking": false]
            )
            // Trigger background warmup for next call if not already building.
            if cachedPrompts[instructions] == nil {
                Task { [weak self] in
                    await self?.warmupPrompt(instructions)
                }
            }
        }

        // Output length guard: stop generation when output chars exceed expected length.
        // Disabled for translation (char counts diverge across scripts) and non-Latin input.
        let outputCharLimit: Int? = (maxTokensCap <= 256 && targetLanguage == nil && !isNonLatin)
            ? Int(Float(charCount) * 1.5) + 20
            : nil

        let timeoutSeconds: Double = charCount < 30 ? 5 : charCount < 200 ? 10 : 15

        var result = ""
        var completionInfo: GenerateCompletionInfo?

        let genTask = Task {
            var r = ""
            var info: GenerateCompletionInfo?
            generation: for try await token in session.streamDetails(
                to: userMessage, images: [], videos: []
            ) {
                switch token {
                case .chunk(let chunk):
                    r += chunk
                    if let limit = outputCharLimit, r.count > limit {
                        Logger.debug("LLM length guard: \(r.count) > \(limit) chars", subsystem: .transcription)
                        break generation
                    }
                case .info(let i):
                    info = i
                case .toolCall:
                    break
                }
            }
            return (r, info)
        }

        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            genTask.cancel()
        }

        do {
            let (r, info) = try await genTask.value
            timeoutTask.cancel()
            result = r
            completionInfo = info
        } catch {
            timeoutTask.cancel()
            Logger.warning("LLM gen failed (\(type(of: error)): \(error)) after \(Int(timeoutSeconds))s timeout (\(charCount) chars), returning original", subsystem: .transcription)
            return text
        }

        if let info = completionInfo {
            Logger.debug("LLM gen: promptTokens=\(info.promptTokenCount) genTokens=\(info.generationTokenCount) stopReason=\(info.stopReason) cacheHit=\(usingCache) promptTime=\(String(format: "%.1f", info.promptTime * 1000))ms genTime=\(String(format: "%.1f", info.generateTime * 1000))ms", subsystem: .transcription)
        } else {
            Logger.warning("LLM gen: stream ended without completion info", subsystem: .transcription)
        }

        // Conditional cache clear — cacheLimit already evicts on allocation; unconditional
        // clearCache would force unnecessary buffer reallocation on the next call.
        if Memory.cacheMemory > Memory.cacheLimit {
            Memory.clearCache()
        }
        Logger.debug("MLX memory: active=\(Memory.activeMemory / (1024 * 1024)) MB cache=\(Memory.cacheMemory / (1024 * 1024)) MB", subsystem: .model)

        // Strip <think>...</think> tags from Qwen3 models.
        var strResult = result
        if let thinkRange = strResult.range(of: Self.thinkTagPattern, options: .regularExpression) {
            strResult.removeSubrange(thinkRange)
        }

        // Strip [INPUT]...[/INPUT] wrapper — model sometimes echoes the prompt delimiter.
        strResult = strResult.trimmingCharacters(in: .whitespacesAndNewlines)
        if strResult.hasPrefix("[INPUT]") {
            strResult = String(strResult.dropFirst("[INPUT]".count))
        }
        if strResult.hasSuffix("[/INPUT]") {
            strResult = String(strResult.dropLast("[/INPUT]".count))
        }

        return strResult.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MTP Processing

    /// Mutable accumulator shared between the generateMTPTokens onToken callback and the timeout task.
    /// @unchecked Sendable: accessed from a single serial queue (container.perform) + one flag write from timeout.
    private final class MTPOutput: @unchecked Sendable {
        var text: String = ""
        var stop: Bool = false
    }

    private func processMTP(
        container: ModelContainer,
        instructions: String,
        userMessage: String,
        maxTokens: Int,
        charCount: Int,
        isNonLatin: Bool,
        maxTokensCap: Int,
        targetLanguage: String?,
        originalText: String
    ) async throws -> String {
        let timeoutSeconds: Double = charCount < 30 ? 5 : charCount < 200 ? 10 : 15
        let mtpOutput = MTPOutput()

        // Timeout: sets stop flag so onToken returns false, ending generation early.
        let timeoutTask = Task { [mtpOutput] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if !mtpOutput.stop {
                Logger.warning("MTP gen: timeout after \(Int(timeoutSeconds))s, stopping", subsystem: .transcription)
                mtpOutput.stop = true
            }
        }
        defer { timeoutTask.cancel() }

        // Build full prompt tokens + run MTP inside the container's serial lock.
        try await container.perform { [mtpOutput] context in
            let tokenizer = context.tokenizer
            let messages: [Message] = [
                ["role": "system", "content": instructions],
                ["role": "user",   "content": userMessage]
            ]
            let promptTokens = try tokenizer.applyChatTemplate(
                messages: messages,
                tools: nil,
                additionalContext: ["enable_thinking": false]
            )

            // Build complete EOS set: generation_config eos_token_id array + tokenizer EOS
            // + extra string tokens (e.g. <|im_end|> for Qwen). Mirrors buildStopTokenIDs in Evaluate.swift.
            var eosIds = context.configuration.eosTokenIds          // from generation_config.json
            if let eos = tokenizer.eosTokenId { eosIds.insert(eos) }
            for token in context.configuration.extraEOSTokens {
                if let id = tokenizer.convertTokenToId(token) { eosIds.insert(id) }
            }
            // Safety net: add im_end / endoftext by name in case generation_config is absent.
            for name in ["<|im_end|>", "<|endoftext|>"] {
                if let id = tokenizer.convertTokenToId(name) { eosIds.insert(id) }
            }
            Logger.debug("MTP eosIds=\(eosIds) promptLen=\(promptTokens.count) firstTokens=\(Array(promptTokens.prefix(5)))", subsystem: .transcription)

            guard let mtpModel = context.model as? any MTPCapableModel else {
                Logger.warning("MTP: model does not conform to MTPCapableModel", subsystem: .transcription)
                return
            }

            let cache = mtpModel.newCache(parameters: nil)

            // Output char limit mirrors the ChatSession path.
            let outputCharLimit: Int? = (maxTokensCap <= 256 && targetLanguage == nil && !isNonLatin)
                ? Int(Float(charCount) * 1.5) + 20
                : nil

            let stats = generateMTPTokens(
                model: mtpModel,
                tokenizer: tokenizer,
                cache: cache,
                promptTokens: promptTokens,
                maxTokens: maxTokens,
                eosTokenIds: eosIds,
                onToken: { tokenId in
                    if mtpOutput.stop { return false }
                    let piece = tokenizer.decode(tokens: [tokenId])
                    mtpOutput.text += piece
                    if let limit = outputCharLimit, mtpOutput.text.count > limit { return false }
                    return true
                }
            )
            Logger.debug(
                "MTP gen: tokens=\(stats.tokenCount) accepted=\(stats.acceptedCount) rollbacks=\(stats.rollbackCount) " +
                "acceptRate=\(String(format: "%.0f", stats.acceptanceRate * 100))% " +
                "prefill=\(Int(stats.prefillTime * 1000))ms gen=\(Int(stats.generateTime * 1000))ms",
                subsystem: .transcription
            )
        }

        // Stop flag in case timeout fires after perform returns (no-op if already done).
        mtpOutput.stop = true

        if Memory.cacheMemory > Memory.cacheLimit { Memory.clearCache() }

        var result = mtpOutput.text
        Logger.debug("MTP raw output (\(result.count) chars): \(result.prefix(200))", subsystem: .transcription)
        // Strip <think>...</think> (Qwen3 chain-of-thought tokens).
        if let thinkRange = result.range(of: Self.thinkTagPattern, options: .regularExpression) {
            result.removeSubrange(thinkRange)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("[INPUT]") { result = String(result.dropFirst("[INPUT]".count)) }
        if result.hasSuffix("[/INPUT]") { result = String(result.dropLast("[/INPUT]".count)) }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Fall back to original if MTP produced nothing (model refused, EOS on first token, etc.)
        guard !result.isEmpty else {
            Logger.warning("MTP gen: empty output, returning original text", subsystem: .transcription)
            return originalText
        }
        return result
    }

    // MARK: - Helpers

    // Compiled once — avoids per-call NSRegularExpression construction.
    private static let thinkTagPattern = "<think>[\\s\\S]*?</think>"

    /// Returns true if text contains Hebrew, Arabic, or CJK script characters.
    /// Used to select a tighter chars-per-token ratio for token budget estimation.
    private func containsNonLatinScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v >= 0x0590 && v <= 0x05FF { return true }  // Hebrew
            if v >= 0x0600 && v <= 0x06FF { return true }  // Arabic
            if v >= 0x0750 && v <= 0x077F { return true }  // Arabic Supplement
            if v >= 0x3040 && v <= 0x30FF { return true }  // Hiragana + Katakana
            if v >= 0x3400 && v <= 0x4DBF { return true }  // CJK Extension A
            if v >= 0x4E00 && v <= 0x9FFF { return true }  // CJK Unified Ideographs
            if v >= 0xAC00 && v <= 0xD7AF { return true }  // Hangul
        }
        return false
    }
}

