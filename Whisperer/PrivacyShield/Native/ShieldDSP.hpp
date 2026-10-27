// Bounded, allocation-free transport and experimental DSP. No efficacy claims.
#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace shield {
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Audio transport requires lock-free 64-bit atomics");
constexpr unsigned rate = 48000, block = 480;
template<size_t N> class Ring {
    std::array<float, N> samples{};
    std::atomic<uint64_t> readIndex{0}, writeIndex{0};
public:
    size_t size() const { auto r=readIndex.load(std::memory_order_acquire); return std::min<uint64_t>(N,writeIndex.load(std::memory_order_acquire)-r); }
    bool push(const float* p, size_t n) {
        auto w = writeIndex.load(std::memory_order_relaxed);
        auto r = readIndex.load(std::memory_order_acquire);
        if (n > N - (w-r)) return false;
        for (size_t i=0;i<n;i++) samples[(w+i)%N]=p[i];
        writeIndex.store(w+n,std::memory_order_release); return true;
    }
    // Only the single consumer may peek/pop/discard.
    float peek(size_t i) const { return samples[(readIndex.load(std::memory_order_relaxed)+i)%N]; }
    void discard(size_t n) { readIndex.fetch_add(n,std::memory_order_release); }
    bool pop(float* p, size_t n) {
        if (size()<n) return false;
        for(size_t i=0;i<n;i++) p[i]=peek(i);
        discard(n); return true;
    }
};

// Multi-reader timestamp-addressed loopback. Sample and tag publish atomically;
// an absent timestamp is silence, never replay of the last buffer.
class Timeline {
    static constexpr size_t capacity=32768;
    std::array<std::atomic<uint64_t>,capacity> slots{};
    std::atomic<uint64_t> newest{0};
public:
    void clear() { for(auto& s:slots) s.store(0,std::memory_order_relaxed); newest=0; }
    void write(uint64_t frame, float value) {
        if(!std::isfinite(value)) value=0;
        value=std::clamp(value,-1.f,1.f);
        uint32_t bits; std::memcpy(&bits,&value,4);
        uint64_t tag=uint32_t(frame+1);
        slots[frame%capacity].store((tag<<32)|bits,std::memory_order_release);
        newest.store(frame,std::memory_order_release);
    }
    float read(uint64_t frame) const {
        auto last=newest.load(std::memory_order_acquire);
        if(frame>last || last-frame>=capacity) return 0;
        auto v=slots[frame%capacity].load(std::memory_order_acquire);
        if(uint32_t(v>>32)!=uint32_t(frame+1)) return 0;
        uint32_t bits=uint32_t(v); float result; std::memcpy(&result,&bits,4); return result;
    }
};

// Reference baseline: bounded amplitude modulation + speech-relative noise.
// This is deliberately not called an adversarial or validated protection model.
class Baseline {
    double phase=0; uint32_t random=0x573912ab; float envelope=0;
public:
    void process(const float* in,float* out,size_t n,float strength) {
        strength=std::isfinite(strength)?std::clamp(strength,0.f,1.f):0.f;
        for(size_t i=0;i<n;i++) {
            float x=std::isfinite(in[i])?std::clamp(in[i],-1.f,1.f):0;
            envelope += .005f*(std::abs(x)-envelope);
            random ^= random<<13; random ^= random>>17; random ^= random<<5;
            float noise=(float(random)/float(UINT32_MAX)*2-1)*envelope*.12f*strength;
            float gain=1-strength*.3f+strength*.3f*std::sin(phase);
            phase+=2*3.141592653589793*37/rate;
            if(phase>2*3.141592653589793) phase-=2*3.141592653589793;
            out[i]=std::clamp(x*gain+noise,-.98f,.98f);
        }
    }
};

// Windowed-sinc rate conversion on the worker, never the audio callback.
class Resampler {
    double position=0;
    std::array<float,32> past{};
    static constexpr size_t phases=1024;
    std::array<std::array<float,32>,phases+1> weights{};
    double preparedRate=0;
public:
    // Build once per nominal device rate. Clock correction changes the sampling
    // positions, not the filter; leave transition-band headroom for +/-0.1% drift.
    void prepare(double sourceRate) {
        preparedRate=sourceRate;
        double cutoff=std::min(1.,double(rate)/sourceRate)*.94;
        for(size_t phase=0;phase<=phases;++phase) {
            double fraction=double(phase)/phases, norm=0;
            for(int k=-15;k<=16;++k) {
                double delta=fraction-k, z=delta*cutoff;
                double sinc=std::abs(z)<1e-9?1:std::sin(M_PI*z)/(M_PI*z);
                double weight=sinc*(.5+.5*std::cos(M_PI*delta/17))*cutoff;
                weights[phase][k+15]=float(weight); norm+=weight;
            }
            for(auto& weight:weights[phase]) weight/=float(norm);
        }
    }
    template<size_t N> bool render(Ring<N>& input,double sourceRate,float* out,size_t count) {
        if(!std::isfinite(sourceRate) || sourceRate<8000 || sourceRate>192192) return false;
        if(preparedRate==0) prepare(sourceRate);
        double ratio=sourceRate/rate;
        size_t needed=size_t(std::ceil(position+count*ratio))+17;
        if(input.size()<needed) return false;
        for(size_t i=0;i<count;i++) {
            int center=int(position);
            double phase=(position-center)*phases;
            size_t lower=std::min(size_t(phase),phases-1);
            float blend=float(phase-lower), sum=0;
            for(int k=-15;k<=16;k++) {
                int index=center+k;
                float weight=weights[lower][k+15]+blend*(weights[lower+1][k+15]-weights[lower][k+15]);
                float sample=index<0?past[32+index]:input.peek(size_t(index));
                sum+=sample*weight;
            }
            out[i]=sum; position+=ratio;
        }
        size_t consumed=size_t(position);
        std::array<float,32> next{};
        for(int i=0;i<32;i++) {
            int offset=int(consumed)-32+i;
            next[i]=offset<0?past[32+offset]:input.peek(size_t(offset));
        }
        past=next; input.discard(consumed); position-=consumed; return true;
    }
};
}
