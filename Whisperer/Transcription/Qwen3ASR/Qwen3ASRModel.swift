//
//  Qwen3ASRModel.swift
//  Whisperer
//
//  MLX port of Qwen3-ASR (audio tower + Qwen3 text decoder), weight-compatible with
//  mlx-community/Qwen3-ASR-*-{bf16,8bit,4bit}. Reference: mlx-audio
//  `mlx_audio/stt/models/qwen3_asr/qwen3_asr.py`.
//

import Foundation
import MLX
import MLXLMCommon
import MLXNN

// MARK: - Configuration

nonisolated struct Qwen3ASRConfiguration: Sendable {
    struct Audio: Sendable {
        var dModel = 1024
        var layers = 24
        var heads = 16
        var ffnDim = 4096
        var numMelBins = 128
        var downsampleHidden = 480
        var outputDim = 2048
        var maxSourcePositions = 1500
        var nWindow = 50
        var nWindowInfer = 800
    }
    struct Text: Sendable {
        var hiddenSize = 2048
        var intermediateSize = 6144
        var heads = 16
        var kvHeads = 8
        var headDim = 128
        var layers = 28
        var rmsNormEps: Float = 1e-6
        var ropeTheta: Float = 1_000_000
        var vocabSize = 151_936
    }
    var audio = Audio()
    var text = Text()
    var quantization: (groupSize: Int, bits: Int)?
    var supportedLanguages: [String] = []

    /// Parses `config.json` as published by mlx-community (`thinker_config.{audio,text}_config`).
    static func load(from url: URL) throws -> Qwen3ASRConfiguration {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Qwen3ASRError.invalidModel("config.json is not an object")
        }
        let thinker = root["thinker_config"] as? [String: Any] ?? root
        var cfg = Qwen3ASRConfiguration()
        func int(_ d: [String: Any], _ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        func float(_ d: [String: Any], _ k: String) -> Float? { (d[k] as? NSNumber)?.floatValue }
        if let a = thinker["audio_config"] as? [String: Any] {
            cfg.audio.dModel = int(a, "d_model") ?? cfg.audio.dModel
            cfg.audio.layers = int(a, "encoder_layers") ?? cfg.audio.layers
            cfg.audio.heads = int(a, "encoder_attention_heads") ?? cfg.audio.heads
            cfg.audio.ffnDim = int(a, "encoder_ffn_dim") ?? cfg.audio.ffnDim
            cfg.audio.numMelBins = int(a, "num_mel_bins") ?? cfg.audio.numMelBins
            cfg.audio.downsampleHidden = int(a, "downsample_hidden_size") ?? cfg.audio.downsampleHidden
            cfg.audio.outputDim = int(a, "output_dim") ?? cfg.audio.outputDim
            cfg.audio.maxSourcePositions = int(a, "max_source_positions") ?? cfg.audio.maxSourcePositions
            cfg.audio.nWindow = int(a, "n_window") ?? cfg.audio.nWindow
            cfg.audio.nWindowInfer = int(a, "n_window_infer") ?? cfg.audio.nWindowInfer
        }
        if let t = thinker["text_config"] as? [String: Any] {
            cfg.text.hiddenSize = int(t, "hidden_size") ?? cfg.text.hiddenSize
            cfg.text.intermediateSize = int(t, "intermediate_size") ?? cfg.text.intermediateSize
            cfg.text.heads = int(t, "num_attention_heads") ?? cfg.text.heads
            cfg.text.kvHeads = int(t, "num_key_value_heads") ?? cfg.text.kvHeads
            cfg.text.headDim = int(t, "head_dim") ?? cfg.text.headDim
            cfg.text.layers = int(t, "num_hidden_layers") ?? cfg.text.layers
            cfg.text.rmsNormEps = float(t, "rms_norm_eps") ?? cfg.text.rmsNormEps
            cfg.text.ropeTheta = float(t, "rope_theta") ?? cfg.text.ropeTheta
            cfg.text.vocabSize = int(t, "vocab_size") ?? cfg.text.vocabSize
        }
        if let q = (root["quantization"] ?? root["quantization_config"]) as? [String: Any],
           let g = int(q, "group_size"), let b = int(q, "bits") {
            cfg.quantization = (g, b)
        }
        cfg.supportedLanguages = root["support_languages"] as? [String] ?? []
        return cfg
    }
}

nonisolated enum Qwen3ASRError: Error, LocalizedError {
    case invalidModel(String)
    case notLoaded

    var errorDescription: String? {
        switch self {
        case .invalidModel(let m): return "Qwen3 ASR model is invalid: \(m)"
        case .notLoaded: return "Qwen3 ASR model is not loaded"
        }
    }
}

// MARK: - Audio encoder

nonisolated final class Qwen3ASRAudioAttention: Module {
    let heads: Int
    let headDim: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    init(_ cfg: Qwen3ASRConfiguration.Audio) {
        heads = cfg.heads
        headDim = cfg.dModel / cfg.heads
        scale = pow(Float(headDim), -0.5)
        _qProj.wrappedValue = Linear(cfg.dModel, cfg.dModel, bias: true)
        _kProj.wrappedValue = Linear(cfg.dModel, cfg.dModel, bias: true)
        _vProj.wrappedValue = Linear(cfg.dModel, cfg.dModel, bias: true)
        _outProj.wrappedValue = Linear(cfg.dModel, cfg.dModel, bias: true)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let (B, L, D) = (x.dim(0), x.dim(1), x.dim(2))
        let q = qProj(x).reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
        let k = kProj(x).reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(B, L, heads, headDim).transposed(0, 2, 1, 3)
        let out = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale,
            mask: mask.map { .array($0) } ?? .none)
        return outProj(out.transposed(0, 2, 1, 3).reshaped(B, L, D))
    }
}

nonisolated final class Qwen3ASRAudioEncoderLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3ASRAudioAttention
    @ModuleInfo(key: "self_attn_layer_norm") var selfAttnLayerNorm: LayerNorm
    @ModuleInfo(key: "fc1") var fc1: Linear
    @ModuleInfo(key: "fc2") var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalLayerNorm: LayerNorm

    init(_ cfg: Qwen3ASRConfiguration.Audio) {
        _selfAttn.wrappedValue = Qwen3ASRAudioAttention(cfg)
        _selfAttnLayerNorm.wrappedValue = LayerNorm(dimensions: cfg.dModel)
        _fc1.wrappedValue = Linear(cfg.dModel, cfg.ffnDim)
        _fc2.wrappedValue = Linear(cfg.ffnDim, cfg.dModel)
        _finalLayerNorm.wrappedValue = LayerNorm(dimensions: cfg.dModel)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let h = x + selfAttn(selfAttnLayerNorm(x), mask: mask)
        return h + fc2(gelu(fc1(finalLayerNorm(h))))
    }
}

nonisolated final class Qwen3ASRAudioEncoder: Module {
    let cfg: Qwen3ASRConfiguration.Audio

    @ModuleInfo(key: "conv2d1") var conv2d1: Conv2d
    @ModuleInfo(key: "conv2d2") var conv2d2: Conv2d
    @ModuleInfo(key: "conv2d3") var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    let layers: [Qwen3ASRAudioEncoderLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo(key: "proj1") var proj1: Linear
    @ModuleInfo(key: "proj2") var proj2: Linear

    /// Sinusoidal table `[maxSourcePositions, dModel]`. The leading underscore keeps `Module`
    /// reflection from treating it as a checkpoint parameter (`verify: .all` would reject it).
    private let _positionalTable: MLXArray

    init(_ cfg: Qwen3ASRConfiguration.Audio) {
        self.cfg = cfg
        let hidden = cfg.downsampleHidden
        _conv2d1.wrappedValue = Conv2d(inputChannels: 1, outputChannels: hidden,
                                       kernelSize: 3, stride: 2, padding: 1)
        _conv2d2.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden,
                                       kernelSize: 3, stride: 2, padding: 1)
        _conv2d3.wrappedValue = Conv2d(inputChannels: hidden, outputChannels: hidden,
                                       kernelSize: 3, stride: 2, padding: 1)
        let freqAfterConv = ((((cfg.numMelBins + 1) / 2) + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(hidden * freqAfterConv, cfg.dModel, bias: false)
        layers = (0..<cfg.layers).map { _ in Qwen3ASRAudioEncoderLayer(cfg) }
        _lnPost.wrappedValue = LayerNorm(dimensions: cfg.dModel)
        _proj1.wrappedValue = Linear(cfg.dModel, cfg.dModel)
        _proj2.wrappedValue = Linear(cfg.dModel, cfg.outputDim)

        let half = cfg.dModel / 2
        let logIncrement = log(Float(10_000)) / Float(half - 1)
        let invTimescales = MLX.exp(MLXArray((0..<half).map(Float.init)) * -logIncrement)
        let positions = MLXArray((0..<cfg.maxSourcePositions).map(Float.init)).expandedDimensions(axis: 1)
        let scaled = positions * invTimescales.expandedDimensions(axis: 0)
        _positionalTable = concatenated([MLX.sin(scaled), MLX.cos(scaled)], axis: 1)
    }

    /// Encoder output length for `frames` mel frames (HF `_get_feat_extract_output_lengths`).
    static func outputLength(frames: Int) -> Int {
        func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }
        let leave = frames % 100
        let feat = floorDiv(leave - 1, 2) + 1
        return floorDiv(floorDiv(feat - 1, 2) + 1 - 1, 2) + 1 + (frames / 100) * 13
    }

    /// - Parameter features: `[nMels, frames]` log-mel.
    /// - Returns: `[tokens, outputDim]` audio embeddings, `tokens == outputLength(frames:)`.
    func callAsFunction(_ features: MLXArray) -> MLXArray {
        let frames = features.dim(1)
        let chunkSize = cfg.nWindow * 2

        // Split into 100-frame chunks (last one ragged) — each is convolved independently and
        // its positional embedding restarts at 0, exactly as the model was trained.
        var chunkLengths: [Int] = []
        var remaining = frames
        while remaining > 0 {
            chunkLengths.append(min(chunkSize, remaining))
            remaining -= chunkSize
        }
        let maxChunk = chunkLengths.max() ?? 0
        var chunks: [MLXArray] = []
        var pos = 0
        for len in chunkLengths {
            var chunk = features[0..., pos..<(pos + len)]
            if len < maxChunk {
                chunk = padded(chunk, widths: [[0, 0], [0, maxChunk - len]])
            }
            chunks.append(chunk)
            pos += len
        }

        // NHWC: H = mel bins, W = time, C = 1.
        var x = stacked(chunks, axis: 0).expandedDimensions(axis: -1)
        x = gelu(conv2d1(x))
        x = gelu(conv2d2(x))
        x = gelu(conv2d3(x))
        let (b, f, t, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        x = convOut(x.transposed(0, 2, 3, 1).reshaped(b, t, c * f))
        x = x + _positionalTable[0..<t].asType(x.dtype).expandedDimensions(axis: 0)

        // Drop each chunk's padded tail and join into one token sequence.
        let validLengths = chunkLengths.map { Self.outputLength(frames: $0) }
        var hidden = concatenated(
            validLengths.enumerated().map { i, n in x[i, 0..<n] }, axis: 0)
        let tokens = hidden.dim(0)

        // Attention is block-diagonal over windows of `maxAfterCNN × (nWindowInfer / chunkSize)`
        // tokens. Batch the windows instead of materialising a tokens² mask: the last window is
        // zero-padded and its padded keys masked out; padded query rows are discarded.
        let window = t * (cfg.nWindowInfer / chunkSize)
        let windowCount = (tokens + window - 1) / window
        let paddedTokens = windowCount * window
        var mask: MLXArray?
        if paddedTokens > tokens {
            hidden = padded(hidden, widths: [[0, paddedTokens - tokens], [0, 0]])
            let lastValid = tokens - (windowCount - 1) * window
            var maskValues = [Float](repeating: 0, count: windowCount * window)
            for k in lastValid..<window { maskValues[(windowCount - 1) * window + k] = -1e9 }
            mask = MLXArray(maskValues, [windowCount, 1, 1, window]).asType(hidden.dtype)
        }
        var h = hidden.reshaped(windowCount, window, cfg.dModel)
        for layer in layers {
            h = layer(h, mask: mask)
        }
        h = h.reshaped(paddedTokens, cfg.dModel)[0..<tokens]
        h = lnPost(h)
        h = gelu(proj1(h))
        return proj2(h)
    }
}

// MARK: - Text decoder (Qwen3)

nonisolated final class Qwen3ASRTextAttention: Module {
    let heads: Int
    let kvHeads: Int
    let scale: Float

    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let rope: RoPE

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        heads = cfg.heads
        kvHeads = cfg.kvHeads
        scale = pow(Float(cfg.headDim), -0.5)
        _qProj.wrappedValue = Linear(cfg.hiddenSize, cfg.heads * cfg.headDim, bias: false)
        _kProj.wrappedValue = Linear(cfg.hiddenSize, cfg.kvHeads * cfg.headDim, bias: false)
        _vProj.wrappedValue = Linear(cfg.hiddenSize, cfg.kvHeads * cfg.headDim, bias: false)
        _oProj.wrappedValue = Linear(cfg.heads * cfg.headDim, cfg.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: cfg.headDim, eps: cfg.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: cfg.headDim, eps: cfg.rmsNormEps)
        // Audio-only prompts give all three M-RoPE sections the same position id, which makes
        // interleaved M-RoPE identical to plain RoPE.
        rope = RoPE(dimensions: cfg.headDim, traditional: false, base: cfg.ropeTheta)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        var q = qNorm(qProj(x).reshaped(B, L, heads, -1)).transposed(0, 2, 1, 3)
        var k = kNorm(kProj(x).reshaped(B, L, kvHeads, -1)).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(B, L, kvHeads, -1).transposed(0, 2, 1, 3)
        let offset = cache?.offset ?? 0
        q = rope(q, offset: offset)
        k = rope(k, offset: offset)
        let out = attentionWithCacheUpdate(
            queries: q, keys: k, values: v, cache: cache, scale: scale, mask: mask)
        return oProj(out.transposed(0, 2, 1, 3).reshaped(B, L, -1))
    }
}

nonisolated final class Qwen3ASRTextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        _gateProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(cfg.hiddenSize, cfg.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(cfg.intermediateSize, cfg.hiddenSize, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(silu(gateProj(x)) * upProj(x))
    }
}

nonisolated final class Qwen3ASRTextLayer: Module {
    @ModuleInfo(key: "self_attn") var selfAttn: Qwen3ASRTextAttention
    @ModuleInfo(key: "mlp") var mlp: Qwen3ASRTextMLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        _selfAttn.wrappedValue = Qwen3ASRTextAttention(cfg)
        _mlp.wrappedValue = Qwen3ASRTextMLP(cfg)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let h = x + selfAttn(inputLayerNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionLayerNorm(h))
    }
}

nonisolated final class Qwen3ASRTextModel: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    let layers: [Qwen3ASRTextLayer]
    @ModuleInfo(key: "norm") var norm: RMSNorm

    init(_ cfg: Qwen3ASRConfiguration.Text) {
        _embedTokens.wrappedValue = Embedding(embeddingCount: cfg.vocabSize, dimensions: cfg.hiddenSize)
        layers = (0..<cfg.layers).map { _ in Qwen3ASRTextLayer(cfg) }
        _norm.wrappedValue = RMSNorm(dimensions: cfg.hiddenSize, eps: cfg.rmsNormEps)
    }

    func callAsFunction(embeddings: MLXArray, cache: [KVCache]) -> MLXArray {
        var h = embeddings
        let mask = createAttentionMask(h: h, cache: cache.first)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache[i])
        }
        return norm(h)
    }
}

// MARK: - Top level

nonisolated final class Qwen3ASRMLXModel: Module {
    let configuration: Qwen3ASRConfiguration

    @ModuleInfo(key: "audio_tower") var audioTower: Qwen3ASRAudioEncoder
    @ModuleInfo(key: "model") var model: Qwen3ASRTextModel

    init(_ configuration: Qwen3ASRConfiguration) {
        self.configuration = configuration
        _audioTower.wrappedValue = Qwen3ASRAudioEncoder(configuration.audio)
        _model.wrappedValue = Qwen3ASRTextModel(configuration.text)
    }

    func newCache() -> [KVCache] {
        (0..<configuration.text.layers).map { _ in KVCacheSimple() }
    }

    func embed(_ tokens: [Int32]) -> MLXArray {
        model.embedTokens(MLXArray(tokens))
    }

    /// Runs the decoder over `embeddings` (`[1, L, hidden]`) and returns logits for the last
    /// position only — the full `[L, vocab]` projection is never needed for greedy decoding.
    func lastLogits(embeddings: MLXArray, cache: [KVCache]) -> MLXArray {
        let hidden = model(embeddings: embeddings, cache: cache)
        let last = hidden[0..., (hidden.dim(1) - 1)..., 0...]
        return model.embedTokens.asLinear(last)
    }

    /// Loads every `*.safetensors` in `directory`, quantizing exactly the modules whose
    /// `.scales` are present (the text decoder; the audio tower ships unquantized).
    static func load(from directory: URL) throws -> Qwen3ASRMLXModel {
        let configuration = try Qwen3ASRConfiguration.load(
            from: directory.appendingPathComponent("config.json"))
        let model = Qwen3ASRMLXModel(configuration)

        var weights: [String: MLXArray] = [:]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
        guard !files.isEmpty else { throw Qwen3ASRError.invalidModel("no safetensors") }
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                // Original (non-mlx-community) checkpoints nest everything under `thinker.`.
                let k = key.hasPrefix("thinker.") ? String(key.dropFirst("thinker.".count)) : key
                if k.hasPrefix("lm_head.") { continue }  // tied to embed_tokens
                weights[k] = value
            }
        }

        if let (groupSize, bits) = configuration.quantization {
            quantize(model: model) { path, _ in
                weights["\(path).scales"] != nil ? (groupSize, bits, .affine) : nil
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return model
    }
}
