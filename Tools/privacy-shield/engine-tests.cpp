// Real production worker and render callback with synthetic queues, no microphone.
#include "../../Whisperer/PrivacyShield/Native/ShieldAudio.cpp"
#include <cassert>
#include <iostream>
#include <functional>
static void waitFor(const std::function<bool()>& condition) {
    auto deadline=Clock::now()+std::chrono::seconds(4);
    while(!condition() && Clock::now()<deadline) std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(condition());
}
static bool baseline(void* ctx,const float* in,float* out,uint32_t count) {
    static_cast<shield::Baseline*>(ctx)->process(in,out,count,.35); return true;
}
static void start(ShieldAudio& session,ShieldProcess processor,void* context=nullptr) {
    session.processor=processor; session.context=context; session.resampler.prepare(48000);
    session.running=true; session.worker=std::thread(runWorker,&session);
}
static auto render(ShieldAudio& session) {
    std::array<float,480> output; output.fill(9);
    AudioBufferList buffers{1,{{1,sizeof(output),output.data()}}};
    outputCallback(&session,nullptr,nullptr,0,480,&buffers); return output;
}
static bool silent(const std::array<float,480>& output) {
    return std::all_of(output.begin(),output.end(),[](float x){return x==0;});
}
int main(int argc,char** argv) {
    const int seconds=argc>1?std::max(1,std::atoi(argv[1])):30;
    std::array<float,2048> input; input.fill(.3);
    {
        ShieldAudio session; shield::Baseline dsp;
        assert(silent(render(session))); // off, before start
        start(session,baseline,&dsp);
        assert(silent(render(session))); // priming cannot expose raw audio
        assert(session.capture.push(input.data(),input.size()));
        waitFor([&]{return session.primed.load();});
        auto next=Clock::now();
        for(int i=0;i<seconds*100;++i) { // Actual worker scheduling, configurable for longer soak runs
            assert(!silent(render(session)));
            assert(session.capture.push(input.data(),480));
            next+=std::chrono::milliseconds(10); std::this_thread::sleep_until(next);
            assert(session.error.load()==0);
        }
        auto metrics=shield_audio_metrics(&session);
        std::cout<<seconds<<"-second worker run: blocks="<<metrics.processedBlocks<<" peak_ms="<<metrics.maximumProcessingMilliseconds
                 <<" queue_ms="<<metrics.queuedMilliseconds<<" underruns="<<metrics.underruns<<"\n";
        assert(metrics.underruns==0 && metrics.queuedMilliseconds<100);
        shield_audio_stop(&session); assert(silent(render(session)));
        shield_audio_stop(&session); // idempotent cleanup
    }
    for(int scenario=0;scenario<4;++scenario) {
        ShieldAudio session;
        ShieldProcess fn=scenario==0? +[](void*,const float*,float*,uint32_t){return false;}:
            scenario==1? +[](void*,const float*,float* out,uint32_t n){std::fill_n(out,n,NAN);return true;}:
            scenario==2? +[](void*,const float*,float*,uint32_t){std::this_thread::sleep_for(std::chrono::milliseconds(110));return true;}:
            +[](void*,const float*,float* out,uint32_t n){std::fill_n(out,n,.1);return true;};
        start(session,fn);
        if(scenario<3) assert(session.capture.push(input.data(),input.size()));
        waitFor([&]{return session.error.load()!=0;});
        assert(session.error.load()==(scenario==0?-7009:scenario==1?-7011:scenario==2?-7010:-7008));
        assert(silent(render(session))); shield_audio_stop(&session);
    }
    {
        ShieldAudio session; session.running=true; session.primed=true;
        assert(silent(render(session))); assert(session.error.load()==-7004);
        assert(session.playback.push(input.data(),480));
        assert(silent(render(session))); // late queued audio cannot undo a fault
        shield_audio_stop(&session);
    }
    std::cout<<"Engine tests passed: priming, timed delivery, mute-on-stop, processor failure, NaN, deadline, input stall, latched underrun.\n";
}
