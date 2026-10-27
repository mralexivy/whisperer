#include "../../Whisperer/PrivacyShield/Native/ShieldDSP.hpp"
#include <cassert>
#include <limits>
#include <thread>
#include <iostream>

int main() {
    shield::Ring<8> ring;
    float a[]={1,2,3,4,5},b[5]{};
    assert(ring.push(a,5)); assert(!ring.push(a,5));
    assert(ring.pop(b,3)); assert(b[0]==1 && b[2]==3);
    assert(ring.push(a,5)); assert(!ring.pop(b,8));
    assert(ring.pop(b,5)); assert(b[0]==4 && b[1]==5 && b[4]==3);
    shield::Timeline timeline;
    assert(timeline.read(1)==0); timeline.write(1,.5); assert(timeline.read(1)==.5); assert(timeline.read(1+(1ULL<<32))==0);
    assert(timeline.read(32769)==0); timeline.write(32769,.25); assert(timeline.read(1)==0);
    assert(timeline.read(32769)==.25); timeline.clear(); assert(timeline.read(32769)==0);
    timeline.write(4,std::numeric_limits<float>::quiet_NaN()); assert(timeline.read(4)==0);
    timeline.write(5,100); assert(timeline.read(5)==1);
    shield::Ring<1024> concurrent;
    std::thread producer([&]{ for(int i=0;i<100000;i++){float x=float(i);while(!concurrent.push(&x,1))std::this_thread::yield();} });
    for(int i=0;i<100000;i++){float x;while(!concurrent.pop(&x,1))std::this_thread::yield();assert(x==float(i));}
    producer.join();
    shield::Baseline dsp; float silence[480]{},out[480]{};
    dsp.process(silence,out,480,1); for(float x:out) assert(x==0);
    for(double rate:{8000.,16000.,44100.,48000.,96000.,192000.}) {
        shield::Ring<4096> input; shield::Resampler resampler;
        float samples[4096]; for(int i=0;i<4096;i++)samples[i]=float(.4*std::sin(2*M_PI*440*i/rate));
        assert(input.push(samples,4096)); assert(resampler.render(input,rate,out,480));
        double squared=0;
        for(int i=40;i<480;i++) {double expected=.4*std::sin(2*M_PI*440*i/48000);squared+=std::pow(out[i]-expected,2);}
        assert(std::sqrt(squared/440)<.005);
    }
    // Preserve phase/history over block boundaries and suppress downsampling alias.
    for(double frequency:{440.,30000.}) {
        shield::Ring<8192> input; shield::Resampler resampler;
        uint64_t generated=0; double squared=0;
        for(int block=0;block<100;++block) {
            float samples[1920];
            for(auto& x:samples) x=float(.4*std::sin(2*M_PI*frequency*(generated++)/96000));
            if(input.size()<2000) assert(input.push(samples,1920));
            else generated-=1920;
            assert(resampler.render(input,96000,out,480));
            for(int i=40;i<480;i++) {
                double expected=frequency==440?.4*std::sin(2*M_PI*440*(block*480+i)/48000):0;
                squared+=std::pow(out[i]-expected,2);
            }
        }
        assert(std::sqrt(squared/44000)<.005);
    }
    float invalid[480]; for(auto& x:invalid)x=std::numeric_limits<float>::infinity();
    dsp.process(invalid,out,480,.5);for(float x:out)assert(std::isfinite(x)&&std::abs(x)<=.98);
    std::cout << "Native tests passed: queue bounds/concurrency, stale-frame rejection, finite DSP, streaming rate conversion.\n";
}
