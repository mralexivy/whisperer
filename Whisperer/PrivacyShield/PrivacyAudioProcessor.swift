// Local processor adapters, independent of UI and audio capture.
import Foundation
import CoreML

// One instance belongs to one session and is used exclusively by its C++ worker.
final class PrivacyAudioProcessor {
    /// The trained predictive perturbation network shipped in the app bundle
    /// (Tools/privacy-shield/eval/pnet.py, exported with export_weights).
    static let bundledNetworkName = "ShieldPerturbation"
    static var bundledNetworkURL: URL? { Bundle.main.url(forResource: bundledNetworkName, withExtension: "wspn") }

    private let network: UnsafeMutableRawPointer?
    private let baseline: UnsafeMutableRawPointer?
    private let model: MLModel?
    private let input: MLMultiArray?
    private let features: MLDictionaryFeatureProvider?
    private let strength: Float

    /// `networkURL` selects the native predictive network (the protection). `modelURL` keeps the
    /// developer Core ML adapter. With neither, the unvalidated DSP baseline runs; it gives no
    /// protection and is only for routing tests.
    init(networkURL: URL? = nil, modelURL: URL?, strength: Float) throws {
        self.strength = strength
        if let networkURL {
            guard let handle = networkURL.withUnsafeFileSystemRepresentation({ $0.flatMap(shield_pnet_create) }) else {
                throw PrivacyShieldError.unavailable("The voice protection model is damaged. Reinstall Whisperer.")
            }
            network = handle
            model = nil; input = nil; features = nil; baseline = nil
            // Warmup and validation before microphone capture is opened.
            var silence = [Float](repeating: 0, count: 480), out = [Float](repeating: 0, count: 480)
            shield_pnet_process(handle, &silence, &out, 480, strength)
            guard out.allSatisfy({ $0.isFinite }) else {
                throw PrivacyShieldError.unavailable("Voice protection warmup returned invalid output.")
            }
            shield_pnet_reset(handle)
            return
        }
        network = nil
        if let modelURL {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            guard let spec = model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint,
                  spec.dataType == .float32, spec.shape.map(\.intValue) == [1, 480],
                  model.modelDescription.inputDescriptionsByName.count == 1,
                  let output = model.modelDescription.outputDescriptionsByName["processed"]?.multiArrayConstraint,
                  output.dataType == .float32, output.shape.map(\.intValue) == [1, 480] else {
                throw PrivacyShieldError.unavailable("Model must accept audio and return processed, both float32 [1, 480] at 48 kHz. See the model contract.")
            }
            self.model = model
            let array = try MLMultiArray(shape: [1, 480], dataType: .float32)
            array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: 480)
            input = array
            features = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: array)])
            baseline = nil
            // Warmup and validation happen before microphone capture is opened.
            let result = try model.prediction(from: features!)
            guard let samples = result.featureValue(for: "processed")?.multiArrayValue,
                  samples.count == 480,
                  (0..<480).allSatisfy({ samples[$0].floatValue.isFinite }) else {
                throw PrivacyShieldError.unavailable("Model warmup returned invalid output.")
            }
        } else {
            model = nil; input = nil; features = nil
            baseline = shield_baseline_create()
        }
    }

    deinit {
        if let baseline { shield_baseline_destroy(baseline) }
        if let network { shield_pnet_destroy(network) }
    }

    func process(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, count: UInt32) -> Bool {
        guard count == 480 else { return false }
        if let network {
            shield_pnet_process(network, source, destination, count, strength)
            for i in 0..<Int(count) where !destination[i].isFinite { return false }
            return true
        }
        return autoreleasepool {
            if let model, let input, let features {
                do {
                    // The input is our own contiguous float32 allocation. Avoid
                    // 480 NSNumber allocations per 10 ms inference block.
                    let values = input.dataPointer.assumingMemoryBound(to: Float.self)
                    for i in 0..<480 { values[i] = source[i].isFinite ? min(1, max(-1, source[i])) : 0 }
                    let result = try model.prediction(from: features)
                    guard let audio = result.featureValue(for: "processed")?.multiArrayValue,
                          audio.dataType == .float32,
                          audio.shape.map(\.intValue) == [1, 480] else { return false }
                    let samples = audio.dataPointer.assumingMemoryBound(to: Float.self)
                    let stride = audio.strides[1].intValue
                    guard stride > 0 else { return false }
                    for i in 0..<480 {
                        let sample = samples[i * stride]
                        guard sample.isFinite else { return false }
                        destination[i] = sample
                    }
                    return true
                } catch { return false }
            }
            guard let baseline else { return false }
            shield_baseline_process(baseline, source, destination, count, strength)
            return true
        }
    }
}

