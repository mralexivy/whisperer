//
//  Qwen3ASRFeatureExtractor.swift
//  Whisperer
//
//  Log-mel front-end for Qwen3-ASR — a line-for-line port of HuggingFace
//  `WhisperFeatureExtractor._np_extract_fbank_features` (128 bins, n_fft 400, hop 160).
//

import Accelerate
import Foundation

/// Produces the exact features `WhisperFeatureExtractor` feeds Qwen3-ASR.
///
/// The previous CoreML front-end ran a 512-point FFT over a zero-padded 400-sample window with
/// zero (not reflect) centre padding, and summed the filterbank in scalar Swift. That is a
/// different spectrogram from the one the model was trained on, and in a Debug build the scalar
/// loop alone cost 31 s on a 71 s recording. Here the 400-point DFT is two `sgemm`s against
/// precomputed cos/sin bases (400 has a factor of 25, so vDSP's FFT/DFT cannot take it), and
/// the filterbank is a third — ~5 ms for 30 s of audio.
nonisolated final class Qwen3ASRFeatureExtractor: @unchecked Sendable {
    static let sampleRate = 16_000
    static let nFFT = 400
    static let hopLength = 160
    static let nMels = 128
    static let nBins = nFFT / 2 + 1  // 201

    static let shared = Qwen3ASRFeatureExtractor()

    /// Periodic Hann window folded into the DFT bases: `[nFFT, nBins]` row-major.
    private let cosBasis: [Float]
    private let sinBasis: [Float]
    /// Slaney-normalised filterbank, `[nBins, nMels]` row-major (already transposed for sgemm).
    private let melFiltersT: [Float]

    private init() {
        let n = Self.nFFT, bins = Self.nBins
        var cosB = [Float](repeating: 0, count: n * bins)
        var sinB = [Float](repeating: 0, count: n * bins)
        for t in 0..<n {
            // np.hanning(401)[:-1] — the periodic Hann HF's window_function(400, "hann") returns.
            let w = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(t) / Double(n))
            for k in 0..<bins {
                let angle = 2.0 * Double.pi * Double(k) * Double(t) / Double(n)
                cosB[t * bins + k] = Float(w * cos(angle))
                sinB[t * bins + k] = Float(w * sin(angle))
            }
        }
        cosBasis = cosB
        sinBasis = sinB
        melFiltersT = Self.slaneyFilterBank()
    }

    /// Log-mel features for `samples` (16 kHz mono).
    /// - Returns: `[nMels, nFrames]` row-major values and `nFrames` (= ceil(count / 160)).
    func extract(samples: [Float]) -> (features: [Float], frames: Int) {
        let hop = Self.hopLength, n = Self.nFFT, bins = Self.nBins, mels = Self.nMels
        guard !samples.isEmpty else { return ([], 0) }

        // The feature attention mask HF derives is `mask[::160]`, i.e. ceil(N/160) frames, while
        // the STFT with its last frame dropped yields floor(N/160). Zero-padding to a whole hop
        // makes the two agree instead of relying on out-of-range slicing downstream.
        var audio = samples
        let remainder = audio.count % hop
        if remainder != 0 { audio += [Float](repeating: 0, count: hop - remainder) }

        // centre=True with numpy "reflect" padding of n_fft/2 on each side.
        let pad = n / 2
        guard audio.count > pad else {
            return extract(samples: audio + [Float](repeating: 0, count: pad + 1 - audio.count))
        }
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        for i in 0..<pad {
            padded[pad - 1 - i] = audio[i + 1]
            padded[pad + audio.count + i] = audio[audio.count - 2 - i]
        }
        padded.replaceSubrange(pad..<(pad + audio.count), with: audio)

        // 1 + N/hop STFT frames; WhisperFeatureExtractor drops the last one.
        let frames = audio.count / hop

        // Frame matrix [frames, nFFT] — overlapping rows copied out of the padded signal.
        var frameMatrix = [Float](repeating: 0, count: frames * n)
        padded.withUnsafeBufferPointer { src in
            frameMatrix.withUnsafeMutableBufferPointer { dst in
                for f in 0..<frames {
                    (dst.baseAddress! + f * n).update(from: src.baseAddress! + f * hop, count: n)
                }
            }
        }

        var re = [Float](repeating: 0, count: frames * bins)
        var im = [Float](repeating: 0, count: frames * bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(frames), Int32(bins), Int32(n),
                    1, frameMatrix, Int32(n), cosBasis, Int32(bins), 0, &re, Int32(bins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(frames), Int32(bins), Int32(n),
                    1, frameMatrix, Int32(n), sinBasis, Int32(bins), 0, &im, Int32(bins))

        // |X|^2
        var power = [Float](repeating: 0, count: frames * bins)
        vDSP_vmul(re, 1, re, 1, &power, 1, vDSP_Length(frames * bins))
        vDSP_vma(im, 1, im, 1, power, 1, &power, 1, vDSP_Length(frames * bins))

        // mel[frames, mels] = power[frames, bins] · filtersT[bins, mels]
        var mel = [Float](repeating: 0, count: frames * mels)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(frames), Int32(mels), Int32(bins),
                    1, power, Int32(bins), melFiltersT, Int32(mels), 0, &mel, Int32(mels))

        // log10(max(mel, 1e-10))
        var floorValue: Float = 1e-10
        vDSP_vthr(mel, 1, &floorValue, &mel, 1, vDSP_Length(mel.count))
        var count = Int32(mel.count)
        vvlog10f(&mel, mel, &count)

        // max(x, globalMax - 8), then (x + 4) / 4
        var globalMax: Float = 0
        vDSP_maxv(mel, 1, &globalMax, vDSP_Length(mel.count))
        var clampFloor = globalMax - 8
        vDSP_vthr(mel, 1, &clampFloor, &mel, 1, vDSP_Length(mel.count))
        var quarter: Float = 0.25
        var one: Float = 1
        vDSP_vsmsa(mel, 1, &quarter, &one, &mel, 1, vDSP_Length(mel.count))

        // Transpose to the [mels, frames] layout the encoder slices by time.
        var out = [Float](repeating: 0, count: mels * frames)
        vDSP_mtrans(mel, 1, &out, 1, vDSP_Length(mels), vDSP_Length(frames))
        return (out, frames)
    }

    // MARK: - Slaney filterbank (transformers.audio_utils.mel_filter_bank, norm="slaney")

    private static func slaneyFilterBank() -> [Float] {
        let bins = nBins, mels = nMels
        func hzToMel(_ f: Double) -> Double {
            let minLogHz = 1000.0, minLogMel = 15.0, logStep = 27.0 / log(6.4)
            return f >= minLogHz ? minLogMel + log(f / minLogHz) * logStep : 3.0 * f / 200.0
        }
        func melToHz(_ m: Double) -> Double {
            let minLogHz = 1000.0, minLogMel = 15.0, logStep = log(6.4) / 27.0
            return m >= minLogMel ? minLogHz * exp(logStep * (m - minLogMel)) : 200.0 * m / 3.0
        }
        let melMin = hzToMel(0), melMax = hzToMel(8000)
        let filterFreqs = (0..<(mels + 2)).map {
            melToHz(melMin + (melMax - melMin) * Double($0) / Double(mels + 1))
        }
        let fftFreqs = (0..<bins).map { Double(sampleRate / 2) * Double($0) / Double(bins - 1) }

        var filtersT = [Float](repeating: 0, count: bins * mels)
        for m in 0..<mels {
            let lower = filterFreqs[m], center = filterFreqs[m + 1], upper = filterFreqs[m + 2]
            let enorm = 2.0 / (upper - lower)
            for k in 0..<bins {
                let down = (fftFreqs[k] - lower) / (center - lower)
                let up = (upper - fftFreqs[k]) / (upper - center)
                let v = max(0, min(down, up))
                filtersT[k * mels + m] = Float(v * enorm)
            }
        }
        return filtersT
    }
}
