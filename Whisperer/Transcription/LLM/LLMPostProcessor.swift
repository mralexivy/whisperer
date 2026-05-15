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

    // Legacy — kept for backward compat with any code reading loadProgress
    var loadProgress: Double {
        if case .downloading(let p) = loadPhase { return p }
        if case .ready = loadPhase { return 1.0 }
        return 0
    }

    private var modelContainer: ModelContainer?
    private var draftModelContainer: ModelContainer?
    private var loadedVariant: LLMModelVariant?

    // KV cache of the system prompt — built once during warmup, reused per call
    // This eliminates 897ms-24s of prompt prefill on every inference call.
    private var cachedPromptKV: [any KVCache]?
    private var cachedPromptText: String?

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

        // Track download progress on MainActor to avoid data race with background progress callbacks
        var didReceiveProgress = false

        let configuration = ModelConfiguration(id: variant.huggingFaceId)
        let container = try await loadModelContainer(
            from: HFDownloader(),
            using: HFTokenizerLoader(),
            configuration: configuration,
            progressHandler: { [weak self] progress in
                Task { @MainActor [weak self] in
                    let fraction = progress.fractionCompleted
                    if fraction > 0 {
                        didReceiveProgress = true
                        self?.loadPhase = .downloading(progress: fraction)
                    }
                }
            }
        )

        // Download done (if it happened) — now loading into memory.
        if didReceiveProgress {
            loadPhase = .loading
            Logger.info("LLM \(variant.displayName) downloaded, loading into memory...", subsystem: .model)
        }

        guard !Task.isCancelled else {
            isLoading = false
            loadPhase = .idle
            Logger.info("LLM load cancelled for \(variant.displayName)", subsystem: .model)
            return
        }

        modelContainer = container
        loadedVariant = variant
        isModelLoaded = true
        isLoading = false
        loadPhase = .ready
        errorMessage = nil

        // oMLX: generous Metal buffer pool prevents constant buffer eviction/reallocation
        // during matmul and attention. Model weights are "active memory" and unaffected;
        // only intermediate/KV-cache buffers from inference are constrained.
        // 20 MB was catastrophically small for a 4B model — every op evicted and reallocated buffers.
        Memory.cacheLimit = 256 * 1024 * 1024
        Logger.info("LLM \(variant.displayName) loaded (MLX cache limit: 256 MB, active: \(Memory.activeMemory / (1024 * 1024)) MB)", subsystem: .model)

        // Load draft model in background so speculative decoding activates without blocking first use.
        // process() checks draftModelContainer at call time — nil = normal generation until draft is ready.
        if let draftVariant = variant.draftVariant {
            draftModelContainer = nil
            Task { [weak self] in
                await self?.loadDraftModel(draftVariant)
            }
        }
    }

    private func loadDraftModel(_ variant: LLMModelVariant) async {
        Logger.info("Loading draft model \(variant.displayName) for speculative decoding...", subsystem: .model)
        do {
            let draft = try await loadModelContainer(
                from: HFDownloader(),
                using: HFTokenizerLoader(),
                configuration: ModelConfiguration(id: variant.huggingFaceId),
                progressHandler: { _ in }
            )
            draftModelContainer = draft
            Logger.info("Draft model \(variant.displayName) ready — speculative decoding active (active: \(Memory.activeMemory / (1024 * 1024)) MB)", subsystem: .model)
        } catch {
            Logger.warning("Draft model load failed: \(error.localizedDescription) — using standard generation", subsystem: .model)
        }
    }

    func unloadModel() {
        modelContainer = nil
        draftModelContainer = nil
        loadedVariant = nil
        isModelLoaded = false
        isLoading = false
        loadPhase = .idle
        errorMessage = nil
        cachedPromptKV = nil
        cachedPromptText = nil
        // oMLX: synchronize GPU before clearing to avoid releasing buffers still in flight
        Stream.gpu.synchronize()
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
        // Already cached for this prompt
        if cachedPromptText == instructions && cachedPromptKV != nil { return }

        Logger.debug("LLM warmup: pre-filling system prompt KV cache (\(instructions.count) chars)...", subsystem: .model)
        // Invalidate while rebuilding so a concurrent process() call falls back to fresh session
        cachedPromptKV = nil
        cachedPromptText = nil

        let warmupSession = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(
                maxTokens: 1,
                temperature: 0.0,
                topP: 1.0,
                topK: 0,
                repetitionPenalty: 1.0,
                prefillStepSize: 512  // oMLX chunked prefill: eval() called between each 512-token chunk
            ),
            additionalContext: ["enable_thinking": false]
        )

        let t0 = Date()
        // Force prefill: encode system prompt + one user turn + generate 1 token.
        // This absorbs Metal JIT compilation and fills the KV cache.
        _ = try? await warmupSession.respond(to: ".", images: [], videos: [])
        // oMLX: force materialization of all lazy KV computations before cache extraction
        Stream.gpu.synchronize()
        Logger.debug("LLM warmup: prefill took \(Int(-t0.timeIntervalSinceNow * 1000))ms", subsystem: .model)

        // Persist KV state to temp file, then load back as [KVCache] for in-memory reuse.
        // Disk I/O (~15-20 MB) happens once here, not on every inference call.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperer_kvcache_\(ProcessInfo.processInfo.processIdentifier).safetensors")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try await warmupSession.saveCache(to: tmpURL)
            // loadPromptCache is synchronous — brief main-thread work acceptable during warmup init
            let (caches, _) = try loadPromptCache(url: tmpURL)
            cachedPromptKV = caches
            cachedPromptText = instructions
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

        // Tiered max token cap: short text gets tight bound, long text gets proportional headroom
        let charCount = text.count
        let estimatedTokens = max(4, charCount / 4)
        let maxTokens: Int
        if charCount < 30 {
            maxTokens = min(maxTokensCap, estimatedTokens + 8)
        } else if charCount < 200 {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)) + 4)
        } else {
            maxTokens = min(maxTokensCap, Int(ceil(Float(estimatedTokens) * 1.15)))
        }

        Logger.debug("LLM gen: inputChars=\(charCount) estTokens=\(estimatedTokens) maxTokens=\(maxTokens) cap=\(maxTokensCap) temp=\(temperature) topP=\(topP) topK=\(topK) repPenalty=\(repetitionPenalty)", subsystem: .transcription)

        let genParams = GenerateParameters(
            maxTokens: maxTokens,
            // oMLX TurboQuant: 8-bit KV cache quantization — 2x memory reduction, faster attention.
            // KVCacheSimple is converted to QuantizedKVCache on first generation step via maybeQuantizeKVCache().
            kvBits: 8,
            kvGroupSize: 64,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            prefillStepSize: 512  // oMLX chunked prefill: eval() between each 512-token chunk
        )

        // Speculative decoding: draft model proposes tokens, main model verifies in one forward pass.
        // numDraftTokens=4 balances acceptance rate vs overhead for short correction outputs.
        let speculativeConfig: SpeculativeDecodingConfig? = draftModelContainer.map {
            SpeculativeDecodingConfig(draftModel: $0, numDraftTokens: 4)
        }

        // Use cached prompt KV if available for this exact instructions string.
        // copy() creates an independent deep copy of each KV layer — fast GPU memory copy.
        let usingCache = cachedPromptKV != nil && cachedPromptText == instructions
        let session: ChatSession
        if usingCache, let cachedKV = cachedPromptKV {
            let freshCache = cachedKV.map { $0.copy() }
            session = ChatSession(
                container,
                instructions: nil,  // Already encoded in the pre-built cache
                cache: freshCache,
                speculativeDecoding: speculativeConfig,
                generateParameters: genParams,
                additionalContext: ["enable_thinking": false]
            )
            Logger.debug("LLM gen: cache hit (\(freshCache.count) KV layers) speculative=\(speculativeConfig != nil)", subsystem: .transcription)
        } else {
            session = ChatSession(
                container,
                instructions: instructions,
                speculativeDecoding: speculativeConfig,
                generateParameters: genParams,
                additionalContext: ["enable_thinking": false]
            )
            // Trigger background warmup for next call if not already building
            if cachedPromptText != instructions {
                Task { [weak self] in
                    await self?.warmupPrompt(instructions)
                }
            }
        }

        // Output length guard: stop generation when output chars exceed expected length.
        // Applies to strict correction modes (maxTokensCap <= 256).
        let outputCharLimit: Int? = maxTokensCap <= 256
            ? Int(Float(charCount) * 1.5) + 20
            : nil

        // Timeout scaled by input size: short text should never need more than 5s with warm cache
        let timeoutSeconds: Double = charCount < 30 ? 5 : charCount < 200 ? 10 : 15

        // Run generation, racing against timeout
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

        // Log generation diagnostics
        if let info = completionInfo {
            Logger.debug("LLM gen: promptTokens=\(info.promptTokenCount) genTokens=\(info.generationTokenCount) stopReason=\(info.stopReason) cacheHit=\(usingCache) promptTime=\(String(format: "%.1f", info.promptTime * 1000))ms genTime=\(String(format: "%.1f", info.generateTime * 1000))ms", subsystem: .transcription)
        } else {
            Logger.warning("LLM gen: stream ended without completion info", subsystem: .transcription)
        }

        // oMLX: synchronize GPU before checking cache memory, then defer clear until pool is large.
        // cacheLimit (256 MB) already evicts on allocation; unconditional clearCache would force
        // unnecessary buffer reallocation on the very next call.
        Stream.gpu.synchronize()
        if Memory.cacheMemory > 256 * 1024 * 1024 {
            Memory.clearCache()
        }
        Logger.debug("MLX memory: active=\(Memory.activeMemory / (1024 * 1024)) MB cache=\(Memory.cacheMemory / (1024 * 1024)) MB", subsystem: .model)

        // Strip <think>...</think> tags from Qwen3 models
        if let thinkRange = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.removeSubrange(thinkRange)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - HuggingFace Hub bridge types (Downloader + TokenizerLoader for mlx-swift-lm main)

private struct HFDownloader: Downloader {
    private let hubApi = HubApi()

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await hubApi.snapshot(
            from: id,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

private struct HFTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return HFTokenizerBridge(upstream)
    }
}

private struct HFTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
