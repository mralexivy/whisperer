// Local processor adapters, independent of UI and audio capture.
import Foundation
import CoreML

// One instance belongs to one session and is used exclusively by its C++ worker.
final class PrivacyAudioProcessor {
    private let baseline: UnsafeMutableRawPointer?
    private let model: MLModel?
    private let input: MLMultiArray?
    private let features: MLDictionaryFeatureProvider?
    private let strength: Float

    init(modelURL: URL?, strength: Float) throws {
        self.strength = strength
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
            for i in 0..<480 { array[i] = 0 }
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

    deinit { if let baseline { shield_baseline_destroy(baseline) } }

    func process(_ source: UnsafePointer<Float>, _ destination: UnsafeMutablePointer<Float>, count: UInt32) -> Bool {
        guard count == 480 else { return false }
        return autoreleasepool {
            if let model, let input, let features {
                do {
                    for i in 0..<480 { input[i] = NSNumber(value: source[i]) }
                    let result = try model.prediction(from: features)
                    guard let audio = result.featureValue(for: "processed")?.multiArrayValue,
                          audio.count == 480 else { return false }
                    for i in 0..<480 { destination[i] = audio[i].floatValue }
                    return true
                } catch { return false }
            }
            guard let baseline else { return false }
            shield_baseline_process(baseline, source, destination, count, strength)
            return true
        }
    }
}

