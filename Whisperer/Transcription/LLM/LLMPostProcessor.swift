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
        let container = try await LLMModelFactory.shared.loadContainer(
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

        // Cap the MLX Metal buffer pool. Model weights are "active memory" and unaffected;
        // only intermediate/KV-cache buffers from inference are constrained.
        Memory.cacheLimit = 20 * 1024 * 1024
        Logger.info("LLM \(variant.displayName) loaded (MLX cache limit: 20 MB, active: \(Memory.activeMemory / (1024 * 1024)) MB)", subsystem: .model)
    }

    func unloadModel() {
        modelContainer = nil
        loadedVariant = nil
        isModelLoaded = false
        isLoading = false
        loadPhase = .idle
        errorMessage = nil
        cachedPromptKV = nil
        cachedPromptText = nil
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
                repetitionPenalty: 1.0
            ),
            additionalContext: ["enable_thinking": false]
        )

        let t0 = Date()
        // Force prefill: encode system prompt + one user turn + generate 1 token.
        // This absorbs Metal JIT compilation and fills the KV cache.
        _ = try? await warmupSession.respond(to: ".", images: [], videos: [])
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
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty
        )

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
            Logger.warning("LLM gen timed out or cancelled after \(Int(timeoutSeconds))s (\(charCount) chars), returning original", subsystem: .transcription)
            return text
        }

        // Log generation diagnostics
        if let info = completionInfo {
            Logger.debug("LLM gen: promptTokens=\(info.promptTokenCount) genTokens=\(info.generationTokenCount) stopReason=\(info.stopReason) cacheHit=\(usingCache) promptTime=\(String(format: "%.1f", info.promptTime * 1000))ms genTime=\(String(format: "%.1f", info.generateTime * 1000))ms", subsystem: .transcription)
        } else {
            Logger.warning("LLM gen: stream ended without completion info", subsystem: .transcription)
        }

        // Release KV-cache Metal buffers. Only force-clear when the pool exceeds the 25 MB
        // threshold — cacheLimit (20 MB) already evicts on allocation, so unconditional
        // clearCache would force unnecessary buffer reallocation on the very next call.
        if Memory.cacheMemory > 25 * 1024 * 1024 {
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
