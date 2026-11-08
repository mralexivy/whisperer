#pragma once
// Transcription jammer (Tools/privacy-shield/eval/transform_processor.py `revfade`), streaming, in plain C++.
// Cuts the voice into frames of about 70 ms (length randomised per frame by +-jitter), plays each frame
// time-reversed, and joins neighbouring frames with a short power-complementary crossfade so there is
// no click at the seams. Listeners integrate speech over syllables (~150-250 ms) and follow it; ASR
// encoders read fine 10-25 ms spectro-temporal detail and lose the words. Randomised frame lengths
// mean a fixed-grid re-reversal cannot undo it.
//
// Latency is fixed at the longest frame plus the crossfade (~87 ms at the defaults): an output sample
// is final once every frame that covers it has been read. Allocation-free after construction; called
// only on the processing worker, never in the Core Audio callback.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace shield {

class Jammer {
public:
    static constexpr int kRate = 48000;

    explicit Jammer(float frameMs = 70.f, float fadeMs = 3.f, float jitter = 0.2f, uint32_t seed = 0x9E3779B9u)
        : base_(int(kRate * frameMs / 1000.f)), fade_(std::max(1, int(kRate * fadeMs / 1000.f))),
          jitter_(std::clamp(jitter, 0.f, 0.5f)), seed_(seed ? seed : 1u) {
        maxFrame_ = int(std::ceil(base_ * (1.f + jitter_)));
        latency_ = maxFrame_ + fade_;
        size_t n = 1; while (n < size_t(2 * (latency_ + 4096))) n <<= 1;
        in_.assign(n, 0.f); acc_.assign(n, 0.f); mask_ = n - 1;
        ramp_.resize(size_t(fade_));
        for (int j = 0; j < fade_; ++j) {
            float s = std::sin(float(M_PI) * 0.5f * float(j) / float(std::max(1, fade_ - 1)));
            ramp_[size_t(j)] = s * s;
        }
        reset();
    }

    int latencySamples() const { return latency_; }

    void reset() {
        std::fill(in_.begin(), in_.end(), 0.f); std::fill(acc_.begin(), acc_.end(), 0.f);
        written_ = 0; start_ = 0; rng_ = seed_; width_ = drawWidth();
    }

    // in/out: n mono float32 samples at 48 kHz. `strength` mixes jammed (1) against the equally delayed
    // dry voice (0), so the output timing never changes with the setting.
    void process(const float* in, float* out, size_t n, float strength) {
        const float wet = std::clamp(strength, 0.f, 1.f);
        for (size_t k = 0; k < n; ++k) {
            float x = std::isfinite(in[k]) ? in[k] : 0.f;
            in_[written_ & mask_] = x;
            ++written_;
            while (written_ >= start_ + uint64_t(width_ + fade_)) addFrame();
            float y = 0.f, dry = 0.f;
            if (written_ > uint64_t(latency_)) {
                uint64_t p = written_ - 1 - uint64_t(latency_);
                y = acc_[p & mask_]; acc_[p & mask_] = 0.f; dry = in_[p & mask_];
            }
            out[k] = wet * y + (1.f - wet) * dry;
        }
    }

private:
    // Frame [start, start + width + fade) is written reversed at the same position. Its first `fade`
    // samples rise and its last `fade` fall, overlapping the next frame's rise: sin^2 + cos^2 = 1.
    void addFrame() {
        const int len = width_ + fade_;
        for (int j = 0; j < len; ++j) {
            float g = j < fade_ ? ramp_[size_t(j)] : (j >= width_ ? ramp_[size_t(len - 1 - j)] : 1.f);
            acc_[(start_ + uint64_t(j)) & mask_] += g * in_[(start_ + uint64_t(len - 1 - j)) & mask_];
        }
        start_ += uint64_t(width_);
        width_ = drawWidth();
    }

    int drawWidth() {
        if (jitter_ <= 0.f) return base_;
        rng_ ^= rng_ << 13; rng_ ^= rng_ >> 17; rng_ ^= rng_ << 5;          // xorshift32
        float u = float(rng_ >> 8) / float(1u << 24) * 2.f - 1.f;
        return std::clamp(int(std::lround(base_ * (1.f + jitter_ * u))), fade_ + 1, maxFrame_);
    }

    int base_, fade_; float jitter_; uint32_t seed_, rng_ = 1;
    int maxFrame_ = 0, latency_ = 0, width_ = 0;
    std::vector<float> in_, acc_, ramp_;
    size_t mask_ = 0;
    uint64_t written_ = 0, start_ = 0;
};

}  // namespace shield
