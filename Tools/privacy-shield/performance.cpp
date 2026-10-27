// Offline timing includes resampling + baseline processing, excluding HAL scheduling.
#include "../../Whisperer/PrivacyShield/Native/ShieldDSP.hpp"
#include <chrono>
#include <cstdio>
#include <vector>
int main() {
    using Clock=std::chrono::steady_clock;
    for(double rate:{16000.,44100.,48000.,96000.,192000.}) {
        shield::Ring<32768> input;
        shield::Resampler converter;
        shield::Baseline processor;
        std::array<float,4096> source{};
        std::array<float,480> converted{},output{};
        for(size_t i=0;i<source.size();++i) source[i]=float(.3*std::sin(i*.057));
        std::vector<double> samples; samples.reserve(10000);
        for(int iteration=0;iteration<10100;++iteration) {
            if(input.size()<4096 && !input.push(source.data(),4096)) return 1;
            auto start=Clock::now();
            if(!converter.render(input,rate,converted.data(),480)) return 2;
            processor.process(converted.data(),output.data(),480,.35);
            auto ms=std::chrono::duration<double,std::milli>(Clock::now()-start).count();
            if(iteration>=100) samples.push_back(ms);
            for(float x:output) if(!std::isfinite(x)) return 3;
        }
        std::sort(samples.begin(),samples.end());
        std::printf("%.0f Hz: p50=%.4f ms p95=%.4f ms p99=%.4f ms max=%.4f ms (10 ms budget, 10000 blocks)\n",rate,samples[5000],samples[9500],samples[9900],samples.back());
        if(samples[9900]>=10) return 4;
    }
}
