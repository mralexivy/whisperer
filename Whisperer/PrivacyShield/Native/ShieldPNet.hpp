#pragma once
// Predictive perturbation network (Tools/privacy-shield/eval/pnet.py), streaming, in plain C++.
// Per 10 ms block at 48 kHz (480 samples): decimate the mic signal to 16 kHz, run one front-end
// convolution + LayerNorm + 2-layer GRU step + linear head on the PAST 25 ms window, interpolate the
// 160-sample perturbation back to 48 kHz and add it to the current block. Allocation-free after load;
// called only on the processing worker, never in the Core Audio callback.
//
// When the weights carry a `reshape` ratio, the voice is first reshaped (Tools/privacy-shield/eval/
// reshape.py: a two-tap delay-line pitch shifter that also moves the formants), and the network then
// perturbs the reshaped voice. That pairing is what the network was trained on, so the ratio travels
// inside the weights file rather than being a separate setting.
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK
#endif
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace shield {

class PNet {
public:
    static constexpr int kRate = 48000, kBlock = 480, kHop = 160, kWin = 400, kTaps = 48;

    // Loads a "WSPN" weights file written by pnet.export_weights. Returns false on any mismatch.
    bool load(const char* path, std::string* error = nullptr) {
        auto fail = [&](const char* why) { if (error) *error = why; return false; };
        FILE* f = std::fopen(path, "rb"); if (!f) return fail("cannot open weights");
        char magic[4]; uint32_t hlen = 0;
        bool ok = std::fread(magic, 1, 4, f) == 4 && std::memcmp(magic, "WSPN", 4) == 0 && std::fread(&hlen, 4, 1, f) == 1 && hlen < 4096;
        std::string header(hlen, '\0');
        ok = ok && std::fread(header.data(), 1, hlen, f) == hlen;
        if (!ok) { std::fclose(f); return fail("bad header"); }
        C_ = field(header, "channels"); H_ = field(header, "hidden"); L_ = field(header, "layers");
        maxAmp_ = fieldf(header, "max_amp"); eps_ = fieldf(header, "norm_eps"); relative_ = fieldf(header, "relative");
        reshape_ = fieldd(header, "reshape");
        ahead_ = int(field(header, "ahead") > 0 ? field(header, "ahead") : 0);
        if (ahead_ > 1) { std::fclose(f); return fail("unsupported look-ahead"); }
        if (!std::isfinite(reshape_) || (reshape_ != 0 && (reshape_ < 0.7 || reshape_ > 1.4))) { std::fclose(f); return fail("unsupported reshape ratio"); }
        long count = field(header, "count");
        if (field(header, "hop") != kHop || field(header, "win") != kWin || field(header, "rate") != 16000 || C_ <= 0 || H_ <= 0 || L_ <= 0 || L_ > 4) {
            std::fclose(f); return fail("unsupported layout");
        }
        w_.resize(count);
        ok = std::fread(w_.data(), sizeof(float), count, f) == size_t(count); std::fclose(f);
        if (!ok) return fail("truncated weights");
        // Slice views in export order.
        size_t o = 0; auto take = [&](size_t n) { const float* p = w_.data() + o; o += n; return p; };
        convW_ = take(size_t(C_) * kWin); convB_ = take(C_); normW_ = take(C_); normB_ = take(C_);
        for (int l = 0; l < L_; l++) {
            int in = l == 0 ? C_ + 1 : H_;
            layers_[l] = {take(size_t(3) * H_ * in), take(size_t(3) * H_ * H_), take(3 * H_), take(3 * H_), in};
        }
        headW_ = take(size_t(kHop + 1) * H_); headB_ = take(kHop + 1);
        if (o != size_t(count)) return fail("weight count mismatch");
        feat_.assign(C_ + 1, 0); state_.assign(size_t(L_) * H_, 0); gi_.assign(3 * H_, 0); gh_.assign(3 * H_, 0);
        head_.assign(kHop + 1, 0); hist_.assign(kWin, 0); d16_.assign(kHop, 0);
        line_.assign(2 * kGrain + 4, 0); voice_.assign(kBlock, 0);
        designFilters(); reset(); loaded_ = true; return true;
    }

    void reset() {
        std::fill(state_.begin(), state_.end(), 0.f); std::fill(hist_.begin(), hist_.end(), 0.f);
        std::fill(decimLine_, decimLine_ + kTaps, 0.f); std::fill(interpLine_, interpLine_ + kTaps, 0.f);
        decimPos_ = 0; interpPos_ = 0;
        std::fill(line_.begin(), line_.end(), 0.f); linePos_ = 0; phase_ = 0;
    }
    double reshapeRatio() const { return reshape_; }
    bool loaded() const { return loaded_; }

    // in/out: 480 mono float32 samples at 48 kHz. `strength` scales the learned perturbation (1 = as trained).
    void process(const float* in, float* out, size_t n, float strength) {
        if (!loaded_ || n != size_t(kBlock)) { for (size_t i = 0; i < n; i++) out[i] = std::clamp(in[i], -.98f, .98f); return; }
        strength = std::isfinite(strength) ? std::clamp(strength, 0.f, 2.f) : 0.f;
        // The reshaper always runs so its delay line stays continuous; strength 0 bypasses its output.
        for (int i = 0; i < kBlock; i++) {
            float x = std::isfinite(in[i]) ? std::clamp(in[i], -1.f, 1.f) : 0.f;
            float r = reshape_ != 0 ? reshapeSample(x) : x;
            voice_[i] = strength > 0 ? r : x;
        }
        in = voice_.data();
        // ahead = 1: the analysis window ends at this block's end (trained that way); else at its start.
        if (ahead_) appendHistory(in);
        predict();                                    // perturbation for THIS block from the past window only
        // Interpolate 160 -> 480 (zero-stuff, low-pass with gain 3) and add.
        for (int i = 0; i < kBlock; i++) {
            float s = (i % 3 == 0) ? d16_[i / 3] * 3.f : 0.f;
            interpLine_[interpPos_] = s; interpPos_ = (interpPos_ + 1) % kTaps;
            float acc = 0; for (int k = 0; k < kTaps; k++) acc += lp_[k] * interpLine_[(interpPos_ + k) % kTaps];
            float x = std::isfinite(in[i]) ? std::clamp(in[i], -1.f, 1.f) : 0.f;
            out[i] = std::clamp(x + strength * acc, -.98f, .98f);
        }
        if (!ahead_) appendHistory(in);
    }

private:
    struct Layer { const float *wih, *whh, *bih, *bhh; int in; };

    // Decimate one 480-sample block to 160 samples at 16 kHz and shift it into the analysis history.
    void appendHistory(const float* in) {
        std::memmove(hist_.data(), hist_.data() + kHop, sizeof(float) * (kWin - kHop));
        for (int i = 0; i < kBlock; i++) {
            float x = std::isfinite(in[i]) ? std::clamp(in[i], -1.f, 1.f) : 0.f;
            decimLine_[decimPos_] = x; decimPos_ = (decimPos_ + 1) % kTaps;
            if (i % 3 == 2) {
                float acc = 0; for (int k = 0; k < kTaps; k++) acc += lp_[k] * decimLine_[(decimPos_ + k) % kTaps];
                hist_[kWin - kHop + i / 3] = acc;
            }
        }
    }
    static constexpr int kGrain = kRate * 40 / 1000;   // 40 ms grain: the reshaper's worst-case latency

    // reshape.py, sample for sample: two read heads, half a grain apart, sweep the delay line at
    // (1 - ratio) per sample and are crossfaded with a raised cosine.
    float reshapeSample(float x) {
        const int L = int(line_.size());
        line_[linePos_] = x;
        float out = 0;
        for (double k : {0.0, 0.5}) {
            double p = std::fmod(phase_ + k, 1.0);
            double r = linePos_ - (p * kGrain + 1.0);
            double r0 = std::floor(r); float f = float(r - r0);
            int i0 = int(((long(r0) % L) + L) % L), i1 = (i0 + 1) % L;
            out += (line_[i0] + f * (line_[i1] - line_[i0])) * float(0.5 - 0.5 * std::cos(2 * M_PI * p));
        }
        phase_ = std::fmod(phase_ + (1.0 - reshape_) / kGrain + 1.0, 1.0);
        linePos_ = (linePos_ + 1) % L;
        return out;
    }

    void predict() {
        // Front-end conv over the 400-sample window == one matrix-vector product, then tanh + LayerNorm.
        cblas_sgemv(CblasRowMajor, CblasNoTrans, C_, kWin, 1.f, convW_, kWin, hist_.data(), 1, 0.f, feat_.data(), 1);
        double mean = 0, var = 0;
        for (int c = 0; c < C_; c++) { feat_[c] = std::tanh(feat_[c] + convB_[c]); mean += feat_[c]; }
        mean /= C_; for (int c = 0; c < C_; c++) var += (feat_[c] - mean) * (feat_[c] - mean); var /= C_;
        float inv = 1.f / std::sqrt(float(var) + eps_);
        for (int c = 0; c < C_; c++) feat_[c] = (feat_[c] - float(mean)) * inv * normW_[c] + normB_[c];
        double e = 0; for (int k = 0; k < kWin; k++) e += double(hist_[k]) * hist_[k];
        float ms = float(e / kWin);
        feat_[C_] = std::log10(ms + 1e-6f);
        const float* x = feat_.data();
        for (int l = 0; l < L_; l++) {
            const Layer& g = layers_[l]; float* h = state_.data() + size_t(l) * H_;
            cblas_sgemv(CblasRowMajor, CblasNoTrans, 3 * H_, g.in, 1.f, g.wih, g.in, x, 1, 0.f, gi_.data(), 1);
            cblas_sgemv(CblasRowMajor, CblasNoTrans, 3 * H_, H_, 1.f, g.whh, H_, h, 1, 0.f, gh_.data(), 1);
            for (int j = 0; j < H_; j++) {                // PyTorch GRU, gate order r, z, n
                float r = sigmoid(gi_[j] + g.bih[j] + gh_[j] + g.bhh[j]);
                float z = sigmoid(gi_[H_ + j] + g.bih[H_ + j] + gh_[H_ + j] + g.bhh[H_ + j]);
                float nn = std::tanh(gi_[2 * H_ + j] + g.bih[2 * H_ + j] + r * (gh_[2 * H_ + j] + g.bhh[2 * H_ + j]));
                h[j] = (1 - z) * nn + z * h[j];
            }
            x = h;
        }
        cblas_sgemv(CblasRowMajor, CblasNoTrans, kHop + 1, H_, 1.f, headW_, H_, x, 1, 0.f, head_.data(), 1);
        float gate = sigmoid(head_[kHop] + headB_[kHop]);
        float rms = std::sqrt(ms);
        // relative > 0: hard bound at `relative` x the voice's recent RMS (quiet by construction).
        float scale = relative_ > 0 ? gate * relative_ * rms : gate * maxAmp_ * (rms / (rms + .01f));
        for (int i = 0; i < kHop; i++) d16_[i] = std::tanh(head_[i] + headB_[i]) * scale;
    }

    void designFilters() {   // 48-tap windowed-sinc low-pass at 7.2 kHz (48 kHz), unity DC gain
        double sum = 0;
        for (int k = 0; k < kTaps; k++) {
            double t = k - (kTaps - 1) / 2.0, fc = 7200.0 / kRate;
            double s = t == 0 ? 2 * fc : std::sin(2 * M_PI * fc * t) / (M_PI * t);
            double w = 0.42 - 0.5 * std::cos(2 * M_PI * k / (kTaps - 1)) + 0.08 * std::cos(4 * M_PI * k / (kTaps - 1));
            lp_[k] = float(s * w); sum += lp_[k];
        }
        for (int k = 0; k < kTaps; k++) lp_[k] = float(lp_[k] / sum);
    }

    static float sigmoid(float v) { return 1.f / (1.f + std::exp(-v)); }
    static long field(const std::string& h, const char* key) {
        auto p = h.find(std::string("\"") + key + "\""); if (p == std::string::npos) return -1;
        p = h.find(':', p); return std::strtol(h.c_str() + p + 1, nullptr, 10);
    }
    static double fieldd(const std::string& h, const char* key) {
        auto p = h.find(std::string("\"") + key + "\""); if (p == std::string::npos) return 0;
        p = h.find(':', p); return std::strtod(h.c_str() + p + 1, nullptr);
    }
    static float fieldf(const std::string& h, const char* key) {
        auto p = h.find(std::string("\"") + key + "\""); if (p == std::string::npos) return 0;
        p = h.find(':', p); return std::strtof(h.c_str() + p + 1, nullptr);
    }

    bool loaded_ = false; int C_ = 0, H_ = 0, L_ = 0; float maxAmp_ = 0, eps_ = 1e-5f, relative_ = 0;
    double reshape_ = 0;
    int ahead_ = 0;
    std::vector<float> line_, voice_; int linePos_ = 0; double phase_ = 0;
    std::vector<float> w_, feat_, state_, gi_, gh_, head_, hist_, d16_;
    const float *convW_ = nullptr, *convB_ = nullptr, *normW_ = nullptr, *normB_ = nullptr, *headW_ = nullptr, *headB_ = nullptr;
    Layer layers_[4]{};
    float lp_[kTaps]{}, decimLine_[kTaps]{}, interpLine_[kTaps]{};
    int decimPos_ = 0, interpPos_ = 0;
};

} // namespace shield
