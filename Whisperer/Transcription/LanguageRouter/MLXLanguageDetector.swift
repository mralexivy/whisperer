//
//  MLXLanguageDetector.swift
//  Whisperer
//
//  Language identification using ECAPA-TDNN VoxLingua107 via MLX.
//  Downloads weights on demand; outputs [String: Float] probabilities
//  compatible with LiveLanguageArbiter.recordAccurate(probabilities:start:end:).
//
//  Model: https://huggingface.co/beshkenadze/lang-id-voxlingua107-ecapa-mlx
//  Reference: https://github.com/beshkenadze/lid-bench
//

import Foundation
import MLX
import MLXNN

// MARK: - Constants

private let kSampleRate = 16_000
private let kNfft = 400
private let kHopLength = 160
private let kNMels = 60

// MARK: - Mel Spectrogram (SpeechBrain-compatible, MLX rfft)

private func speechbrainMelFilterbank(sampleRate: Int, nfft: Int, nMels: Int) -> [[Float]] {
    func hzToMel(_ f: Float) -> Float { 2595.0 * log10(1.0 + f / 700.0) }
    func melToHz(_ m: Float) -> Float { 700.0 * (pow(10.0, m / 2595.0) - 1.0) }
    let lowMel = hzToMel(0)
    let highMel = hzToMel(Float(sampleRate) / 2)
    let melPoints = (0..<(nMels + 2)).map { i in
        melToHz(lowMel + Float(i) * (highMel - lowMel) / Float(nMels + 1))
    }
    let fftBins = (0..<(nfft / 2 + 1)).map { Float(sampleRate) * Float($0) / Float(nfft) }
    var fb = [[Float]](repeating: [Float](repeating: 0, count: nfft / 2 + 1), count: nMels)
    for m in 0..<nMels {
        let fL = melPoints[m], fC = melPoints[m + 1], fR = melPoints[m + 2]
        let bandLeft = fC - fL, bandRight = fR - fC
        for k in 0..<fftBins.count {
            let f = fftBins[k]
            if f >= fL && f <= fC && bandLeft > 0 { fb[m][k] = (f - fL) / bandLeft }
            else if f > fC && f <= fR && bandRight > 0 { fb[m][k] = (fR - f) / bandRight }
        }
    }
    return fb
}

private func computeMelSpectrogram(audio: [Float]) -> MLXArray {
    let window = MLXArray((0..<kNfft).map { n -> Float in
        Float(0.54 - 0.46 * cos(2.0 * Double.pi * Double(n) / Double(kNfft)))
    })
    let melFbRaw = speechbrainMelFilterbank(sampleRate: kSampleRate, nfft: kNfft, nMels: kNMels)
    let melFbT = MLXArray(melFbRaw.flatMap { $0 })
        .reshaped(kNMels, kNfft / 2 + 1)
        .transposed()

    let padLen = kNfft / 2
    let audioMLX = MLXArray(audio)
    let padded = concatenated([MLXArray.zeros([padLen]), audioMLX, MLXArray.zeros([padLen])])

    let totalLen = padLen + audio.count + padLen
    let numFrames = max(0, (totalLen - kNfft) / kHopLength + 1)
    guard numFrames > 0 else { return MLXArray.zeros([1, 0, kNMels]) }

    let frames = asStrided(padded, [numFrames, kNfft], strides: [kHopLength, 1])
    let fftResult = rfft(frames * window, n: kNfft, axis: -1)
    let magnitude = abs(fftResult)
    let powerSpec = magnitude * magnitude
    let melSpec = matmul(powerSpec, melFbT)
    // lid-bench reference: dB scale = 10*log10, floor at 1e-10, then clip to top_db=80.
    let logMel = 10.0 * log10(maximum(melSpec, MLXArray(Float(1e-10))))
    let clipped = maximum(logMel, logMel.max() - 80.0)
    return clipped.reshaped(1, numFrames, kNMels)
}

// MARK: - ECAPA-TDNN Architecture
//
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor causes the compiler to synthesize a
// MainActor-isolated init() for every Module subclass, which conflicts with the
// nonisolated Module.init() from MLXNN. Explicit nonisolated override init() on
// each subclass suppresses the synthesis and resolves the conflict.

private class TDNNBlock: Module {
    @ModuleInfo var conv: Conv1d
    @ModuleInfo var norm: BatchNorm

    nonisolated override init() { super.init() }

    init(inputChannels: Int, outputChannels: Int, kernelSize: Int, dilation: Int = 1, groups: Int = 1) {
        let padding = (kernelSize - 1) * dilation / 2
        _conv.wrappedValue = Conv1d(
            inputChannels: inputChannels, outputChannels: outputChannels,
            kernelSize: kernelSize, padding: padding, dilation: dilation,
            groups: groups, bias: true
        )
        _norm.wrappedValue = BatchNorm(featureCount: outputChannels)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { norm(relu(conv(x))) }
}

private class Res2NetBlock: Module {
    let scale: Int
    @ModuleInfo var blocks: [TDNNBlock]

    nonisolated override init() { self.scale = 0; super.init() }

    init(channels: Int, kernelSize: Int = 3, dilation: Int = 1, scale: Int = 8) {
        self.scale = scale
        let hidden = channels / scale
        _blocks.wrappedValue = (0..<(scale - 1)).map { _ in
            TDNNBlock(inputChannels: hidden, outputChannels: hidden, kernelSize: kernelSize, dilation: dilation)
        }
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let chunks = split(x, parts: scale, axis: -1)
        var y = [chunks[0]]
        for i in 0..<blocks.count {
            let inp = i > 0 ? chunks[i + 1] + y.last! : chunks[i + 1]
            y.append(blocks[i](inp))
        }
        return concatenated(y, axis: -1)
    }
}

private class SEBlock: Module {
    @ModuleInfo var conv1: Conv1d
    @ModuleInfo var conv2: Conv1d

    nonisolated override init() { super.init() }

    init(inputDim: Int, bottleneck: Int = 128) {
        _conv1.wrappedValue = Conv1d(inputChannels: inputDim, outputChannels: bottleneck, kernelSize: 1)
        _conv2.wrappedValue = Conv1d(inputChannels: bottleneck, outputChannels: inputDim, kernelSize: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var s = mean(x, axis: 1, keepDims: true)
        s = relu(conv1(s))
        s = sigmoid(conv2(s))
        return x * s
    }
}

private class SERes2NetBlock: Module {
    @ModuleInfo var tdnn1: TDNNBlock
    @ModuleInfo(key: "res2net_block") var res2netBlock: Res2NetBlock
    @ModuleInfo var tdnn2: TDNNBlock
    @ModuleInfo(key: "se_block") var seBlock: SEBlock

    nonisolated override init() { super.init() }

    init(channels: Int, kernelSize: Int = 3, dilation: Int = 1, res2netScale: Int = 8, seChannels: Int = 128) {
        _tdnn1.wrappedValue = TDNNBlock(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        _res2netBlock.wrappedValue = Res2NetBlock(channels: channels, kernelSize: kernelSize, dilation: dilation, scale: res2netScale)
        _tdnn2.wrappedValue = TDNNBlock(inputChannels: channels, outputChannels: channels, kernelSize: 1)
        _seBlock.wrappedValue = SEBlock(inputDim: channels, bottleneck: seChannels)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let residual = x
        var out = tdnn1(x)
        out = res2netBlock(out)
        out = tdnn2(out)
        out = seBlock(out)
        return out + residual
    }
}

private class AttentiveStatisticsPooling: Module {
    @ModuleInfo var tdnn: TDNNBlock
    @ModuleInfo var conv: Conv1d

    nonisolated override init() { super.init() }

    init(channels: Int, attentionChannels: Int = 128) {
        _tdnn.wrappedValue = TDNNBlock(inputChannels: channels * 3, outputChannels: attentionChannels, kernelSize: 1)
        _conv.wrappedValue = Conv1d(inputChannels: attentionChannels, outputChannels: channels, kernelSize: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let m = mean(x, axis: 1, keepDims: true)
        let v = variance(x, axis: 1, keepDims: true)
        let s = sqrt(v + 1e-9)
        let mExp = broadcast(m, to: x.shape)
        let sExp = broadcast(s, to: x.shape)
        let attnInput = concatenated([x, mExp, sExp], axis: -1)
        var attn = tdnn(attnInput)
        attn = tanh(attn)
        attn = conv(attn)
        attn = softmax(attn, axis: 1)
        let wMean = sum(attn * x, axis: 1)
        let wVar = sum(attn * (x * x), axis: 1) - wMean * wMean
        let wStd = sqrt(maximum(wVar, 1e-9))
        return concatenated([wMean, wStd], axis: -1)
    }
}

private class EcapaTdnnBlocks: Module {
    @ModuleInfo(key: "block0") var block0: TDNNBlock
    @ModuleInfo(key: "block1") var block1: SERes2NetBlock
    @ModuleInfo(key: "block2") var block2: SERes2NetBlock
    @ModuleInfo(key: "block3") var block3: SERes2NetBlock

    nonisolated override init() { super.init() }

    init(nMels: Int, channels: Int) {
        _block0.wrappedValue = TDNNBlock(inputChannels: nMels, outputChannels: channels, kernelSize: 5)
        _block1.wrappedValue = SERes2NetBlock(channels: channels, kernelSize: 3, dilation: 2)
        _block2.wrappedValue = SERes2NetBlock(channels: channels, kernelSize: 3, dilation: 3)
        _block3.wrappedValue = SERes2NetBlock(channels: channels, kernelSize: 3, dilation: 4)
    }
}

private class EcapaTdnnEmbedding: Module {
    @ModuleInfo var blocks: EcapaTdnnBlocks
    @ModuleInfo var mfa: TDNNBlock
    @ModuleInfo var asp: AttentiveStatisticsPooling
    @ModuleInfo(key: "asp_bn") var aspBn: BatchNorm
    @ModuleInfo var fc: Conv1d

    nonisolated override init() { super.init() }

    init(nMels: Int = 60, channels: Int = 1024, embedDim: Int = 256) {
        _blocks.wrappedValue = EcapaTdnnBlocks(nMels: nMels, channels: channels)
        _mfa.wrappedValue = TDNNBlock(inputChannels: channels * 3, outputChannels: channels * 3, kernelSize: 1)
        _asp.wrappedValue = AttentiveStatisticsPooling(channels: channels * 3, attentionChannels: 128)
        _aspBn.wrappedValue = BatchNorm(featureCount: channels * 6)
        _fc.wrappedValue = Conv1d(inputChannels: channels * 6, outputChannels: embedDim, kernelSize: 1)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var out = blocks.block0(x)
        var xl = [MLXArray]()
        out = blocks.block1(out); xl.append(out)
        out = blocks.block2(out); xl.append(out)
        out = blocks.block3(out); xl.append(out)
        out = concatenated(xl, axis: -1)
        out = mfa(out)
        out = asp(out)
        out = aspBn(out)
        out = expandedDimensions(out, axis: 1)
        out = fc(out)
        return out
    }
}

private class DNNLinear: Module {
    @ModuleInfo var w: Linear

    nonisolated override init() { super.init() }

    init(inputDim: Int, outputDim: Int) { _w.wrappedValue = Linear(inputDim, outputDim) }
    func callAsFunction(_ x: MLXArray) -> MLXArray { w(x) }
}

private class DNNBlock: Module {
    @ModuleInfo var linear: DNNLinear
    @ModuleInfo var norm: BatchNorm

    nonisolated override init() { super.init() }

    init(inputDim: Int, outputDim: Int) {
        _linear.wrappedValue = DNNLinear(inputDim: inputDim, outputDim: outputDim)
        _norm.wrappedValue = BatchNorm(featureCount: outputDim)
    }
    func callAsFunction(_ x: MLXArray) -> MLXArray { relu(norm(linear(x))) }
}

private class DNN: Module {
    @ModuleInfo(key: "block_0") var block0: DNNBlock

    nonisolated override init() { super.init() }

    init(inputDim: Int, outputDim: Int) { _block0.wrappedValue = DNNBlock(inputDim: inputDim, outputDim: outputDim) }
    func callAsFunction(_ x: MLXArray) -> MLXArray { block0(x) }
}

private class ClassifierLinear: Module {
    @ModuleInfo var w: Linear

    nonisolated override init() { super.init() }

    init(inputDim: Int, outputDim: Int) { _w.wrappedValue = Linear(inputDim, outputDim) }
    func callAsFunction(_ x: MLXArray) -> MLXArray { w(x) }
}

private class EcapaClassifier: Module {
    @ModuleInfo var norm: BatchNorm
    @ModuleInfo var DNN: DNN
    @ModuleInfo var out: ClassifierLinear

    nonisolated override init() { super.init() }

    init(embedDim: Int = 256, hiddenDim: Int = 512, numClasses: Int = 107) {
        _norm.wrappedValue = BatchNorm(featureCount: embedDim)
        _DNN.wrappedValue = .init(inputDim: embedDim, outputDim: hiddenDim)
        _out.wrappedValue = ClassifierLinear(inputDim: hiddenDim, outputDim: numClasses)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var v = x.squeezed(axis: 1)
        v = norm(v)
        v = DNN(v)
        v = out(v)
        return logSoftmax(v, axis: -1)
    }
}

private class EcapaTdnnLidModel: Module {
    @ModuleInfo(key: "embedding_model") var embeddingModel: EcapaTdnnEmbedding
    @ModuleInfo var classifier: EcapaClassifier

    nonisolated override init() { super.init() }

    init(nMels: Int = 60, channels: Int = 1024, embedDim: Int = 256, numClasses: Int = 107) {
        _embeddingModel.wrappedValue = EcapaTdnnEmbedding(nMels: nMels, channels: channels, embedDim: embedDim)
        _classifier.wrappedValue = EcapaClassifier(embedDim: embedDim, hiddenDim: 512, numClasses: numClasses)
    }

    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        classifier(embeddingModel(mel))
    }
}

// MARK: - Weight Loading

private func mapEcapaKey(_ sbKey: String) -> String? {
    guard !sbKey.contains("num_batches_tracked") else { return nil }
    var key = sbKey
    key = key.replacingOccurrences(of: "embedding_model.blocks.0.", with: "embedding_model.blocks.block0.")
    key = key.replacingOccurrences(of: "embedding_model.blocks.1.", with: "embedding_model.blocks.block1.")
    key = key.replacingOccurrences(of: "embedding_model.blocks.2.", with: "embedding_model.blocks.block2.")
    key = key.replacingOccurrences(of: "embedding_model.blocks.3.", with: "embedding_model.blocks.block3.")
    key = key.replacingOccurrences(of: ".conv.conv.", with: ".conv.")
    key = key.replacingOccurrences(of: ".norm.norm.", with: ".norm.")
    key = key.replacingOccurrences(of: ".se_block.conv1.conv.", with: ".se_block.conv1.")
    key = key.replacingOccurrences(of: ".se_block.conv2.conv.", with: ".se_block.conv2.")
    key = key.replacingOccurrences(of: ".asp_bn.norm.", with: ".asp_bn.")
    key = key.replacingOccurrences(of: ".fc.conv.", with: ".fc.")
    return key
}

private func loadLidWeights(weightsPath: URL, numClasses: Int) throws -> EcapaTdnnLidModel {
    let model = EcapaTdnnLidModel(nMels: kNMels, channels: 1024, embedDim: 256, numClasses: numClasses)
    model.train(false)
    let rawWeights = try loadArrays(url: weightsPath)
    var mapped = [(String, MLXArray)]()
    var mappedDict = [String: MLXArray]()
    for (key, value) in rawWeights {
        guard let mlxKey = mapEcapaKey(key) else { continue }
        mapped.append((mlxKey, value))
        mappedDict[mlxKey] = value
    }
    // Load learnable parameters (update() skips frozen running_mean/running_var)
    try model.update(parameters: ModuleParameters.unflattened(mapped), verify: .none)
    // Patch frozen BatchNorm running stats directly — they are excluded from parameters()
    // but _updateInternal is public on MLXArray and works regardless of frozen state.
    patchBatchNormRunningStats(model, weights: mappedDict)
    eval(model)
    return model
}

private func patchBatchNormRunningStats(_ model: EcapaTdnnLidModel, weights: [String: MLXArray]) {
    // BatchNorm.runningMean/runningVar are frozen @ParameterInfo properties — internal to MLXNN,
    // inaccessible directly. Access the ParameterInfo<MLXArray?> backing store through Mirror
    // and call the public _updateInternal to mutate the array in place.
    func apply(_ bn: BatchNorm, key: String) {
        guard let mean = weights["\(key).running_mean"],
              let variance = weights["\(key).running_var"] else { return }
        for child in Mirror(reflecting: bn).children {
            switch child.label {
            case "_runningMean":
                (child.value as? ParameterInfo<MLXArray?>)?.wrappedValue?._updateInternal(mean)
            case "_runningVar":
                (child.value as? ParameterInfo<MLXArray?>)?.wrappedValue?._updateInternal(variance)
            default: break
            }
        }
    }
    func tdnn(_ b: TDNNBlock, key: String) { apply(b.norm, key: "\(key).norm") }
    func res2net(_ b: Res2NetBlock, key: String) {
        for (i, sub) in b.blocks.enumerated() { tdnn(sub, key: "\(key).blocks.\(i)") }
    }
    func seRes2Net(_ b: SERes2NetBlock, key: String) {
        tdnn(b.tdnn1, key: "\(key).tdnn1")
        res2net(b.res2netBlock, key: "\(key).res2net_block")
        tdnn(b.tdnn2, key: "\(key).tdnn2")
    }
    let em = model.embeddingModel
    let bl = em.blocks
    tdnn(bl.block0, key: "embedding_model.blocks.block0")
    seRes2Net(bl.block1, key: "embedding_model.blocks.block1")
    seRes2Net(bl.block2, key: "embedding_model.blocks.block2")
    seRes2Net(bl.block3, key: "embedding_model.blocks.block3")
    tdnn(em.mfa, key: "embedding_model.mfa")
    tdnn(em.asp.tdnn, key: "embedding_model.asp.tdnn")
    apply(em.aspBn, key: "embedding_model.asp_bn")
    apply(model.classifier.norm, key: "classifier.norm")
    apply(model.classifier.DNN.block0.norm, key: "classifier.DNN.block_0.norm")
}

// MARK: - Detector

/// Downloads VoxLingua107 ECAPA-TDNN weights on demand and provides language-probability
/// vectors compatible with `LiveLanguageArbiter.recordAccurate(probabilities:start:end:)`.
nonisolated final class MLXLanguageDetector: @unchecked Sendable {
    static let shared = MLXLanguageDetector()
    private init() {}

    private let weightsURL = URL(string: "https://huggingface.co/beshkenadze/lang-id-voxlingua107-ecapa-mlx/resolve/main/ecapa_tdnn_lid107.safetensors")!
    // config.json is standard in every HuggingFace repo and carries id2label — more reliable than a custom labels file
    private let configURL  = URL(string: "https://huggingface.co/beshkenadze/lang-id-voxlingua107-ecapa-mlx/resolve/main/config.json")!

    private var model: EcapaTdnnLidModel?
    private var labels: [String: String] = [:]
    private var compiledForward: ((MLXArray) -> MLXArray)?
    private var isLoading = false
    private let lock = NSLock()

    nonisolated var isReady: Bool {
        lock.withLock { model != nil && !labels.isEmpty }
    }

    /// Kick off background download + load. Safe to call multiple times — idempotent.
    nonisolated func prepareAsync() {
        lock.withLock {
            guard !isLoading && model == nil else { return }
            isLoading = true
        }
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadAndLoad()
            } catch {
                self.lock.withLock { self.isLoading = false }
                Logger.error("MLX language detector failed to load: \(error)", subsystem: .transcription)
            }
        }
    }

    /// Detect language from 16 kHz mono PCM samples. Returns nil if model not ready.
    /// Thread-safe; runs synchronously on the caller's thread (intended for probeQueue).
    /// Uses GPU (Metal) — caller must ensure no concurrent whisper.cpp Metal encode is running.
    nonisolated func detect(samples: [Float]) -> [String: Float]? {
        let (lbl, fwd): ([String: String], ((MLXArray) -> MLXArray)?) = lock.withLock {
            (labels, compiledForward)
        }
        guard !lbl.isEmpty, let fwd else { return nil }
        let mel = computeMelSpectrogram(audio: samples)
        let logProbs = fwd(mel)
        eval(logProbs)
        let probs = exp(logProbs)
        eval(probs)
        let flat = probs.squeezed(axis: 0)
        var result: [String: Float] = [:]
        for (idxStr, label) in lbl {
            guard let idx = Int(idxStr) else { continue }
            var code = label.components(separatedBy: ": ").first ?? label
            // Translate deprecated ISO 639-1 codes to modern equivalents used by Whisper.
            if code == "iw" { code = "he" }  // Hebrew: iw (deprecated) → he
            if code == "jw" { code = "jv" }  // Javanese: jw (deprecated) → jv
            result[code] = flat[idx].item(Float.self)
        }
        return result.isEmpty ? nil : result
    }

    // MARK: - Private

    private var langIdDir: URL {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whisperer/lang-id")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func downloadAndLoad() async throws {
        let dir = langIdDir
        let weightsPath = dir.appendingPathComponent("ecapa_tdnn_lid107.safetensors")
        let configPath  = dir.appendingPathComponent("config.json")
        // Remove any stale labels file from the previous URL scheme
        let staleLabels = dir.appendingPathComponent("ecapa_tdnn_lid107_labels.json")
        try? FileManager.default.removeItem(at: staleLabels)

        if !FileManager.default.fileExists(atPath: weightsPath.path) {
            Logger.info("Downloading MLX language detector weights (~81 MB)…", subsystem: .transcription)
            try await downloadFile(from: weightsURL, to: weightsPath)
            Logger.info("MLX language detector weights downloaded", subsystem: .transcription)
        }
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try await downloadFile(from: configURL, to: configPath)
        }

        let loadedLabels = try parseLabels(from: configPath)
        let loaded = try loadLidWeights(weightsPath: weightsPath, numClasses: loadedLabels.count)
        let compiled = compile(inputs: [loaded], outputs: [loaded]) { [loaded] x in loaded(x) }

        lock.withLock {
            self.model = loaded
            self.labels = loadedLabels
            self.compiledForward = compiled
            self.isLoading = false
        }
        Logger.info("MLX language detector ready (\(loadedLabels.count) languages)", subsystem: .transcription)

        // Warm up Metal JIT after marking ready so the first real probe doesn't stall.
        Task.detached(priority: .background) {
            let warmup = computeMelSpectrogram(audio: [Float](repeating: 0, count: kSampleRate * 2))
            eval(compiled(warmup))
        }
    }

    /// Parse the HuggingFace config.json id2label map into the labels dict used by detect().
    private func parseLabels(from configPath: URL) throws -> [String: String] {
        let data = try Data(contentsOf: configPath)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id2label = json["id2label"] as? [String: String] else {
            throw URLError(.cannotParseResponse)
        }
        return id2label
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue("Whisperer/1.0 (macOS; language-detection)", forHTTPHeaderField: "User-Agent")
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.badServerResponse)
        }
        guard http.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tempURL)
            Logger.error("MLX language detector download failed: HTTP \(http.statusCode) for \(url.lastPathComponent)", subsystem: .transcription)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
}
