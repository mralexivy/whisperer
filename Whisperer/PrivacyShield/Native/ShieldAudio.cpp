#include "ShieldAudio.h"
#include "ShieldDSP.hpp"
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <chrono>
#include <thread>
#include <memory>
#include <pthread.h>
using Clock=std::chrono::steady_clock;
static std::atomic<bool> captureBlocked{false};
extern "C" void shield_set_capture_blocked(bool blocked) { captureBlocked.store(blocked); }
extern "C" bool shield_capture_blocked() { return captureBlocked.load(); }
struct ShieldAudio {
    AudioUnit input=nullptr, output=nullptr, probe=nullptr;
    shield::Ring<32768> capture, playback;
    shield::Resampler resampler;
    std::array<float,8192> scratch{}, probeScratch{};
    std::atomic<uint64_t> received{0}, receivedSignal{0};
    std::atomic<bool> running{false}, primed{false}, processing{true};
    std::atomic<int32_t> error{0};
    std::atomic<uint64_t> processed{0}, underruns{0};
    std::atomic<double> processingMs{0}, maximumMs{0};
    std::atomic<uint64_t> overBudget{0};
    std::thread worker;
    double inputRate=48000;
    uint32_t targetFrames=1440;
    ShieldProcess processor=nullptr; void* context=nullptr;
    void fail(int32_t code) { int32_t expected=0; error.compare_exchange_strong(expected,code); }
};
static OSStatus inputCallback(void* ctx,AudioUnitRenderActionFlags* flags,const AudioTimeStamp* ts,UInt32,UInt32 count,AudioBufferList*) {
    auto& s=*static_cast<ShieldAudio*>(ctx);
    if(!s.running.load() || s.error.load()) return noErr;
    if(count>s.scratch.size()) { s.fail(-7001); return noErr; }
    AudioBufferList b{1,{{1,count*uint32_t(sizeof(float)),s.scratch.data()}}};
    OSStatus status=AudioUnitRender(s.input,flags,ts,1,count,&b);
    if(status) s.fail(status);
    else if(!s.capture.push(s.scratch.data(),count)) s.fail(-7002);
    return noErr;
}
// Read the virtual input through HAL, as a call would. No audio is saved.
static OSStatus probeCallback(void* ctx,AudioUnitRenderActionFlags* flags,const AudioTimeStamp* ts,UInt32,UInt32 count,AudioBufferList*) {
    auto& s=*static_cast<ShieldAudio*>(ctx);
    if(!s.running.load() || s.error.load()) return noErr;
    if(count>s.probeScratch.size()) { s.fail(-7001); return noErr; }
    AudioBufferList b{1,{{1,count*uint32_t(sizeof(float)),s.probeScratch.data()}}};
    OSStatus status=AudioUnitRender(s.probe,flags,ts,1,count,&b);
    if(status) { s.fail(status); return noErr; }
    uint64_t signal=0;
    for(UInt32 i=0;i<count;i++) {
        float value=s.probeScratch[i];
        if(!std::isfinite(value)) { s.fail(-7011); return noErr; }
        if(std::abs(value)>0.00001f) ++signal;
    }
    s.received.fetch_add(count);
    s.receivedSignal.fetch_add(signal);
    return noErr;
}
static OSStatus outputCallback(void* ctx,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32 count,AudioBufferList* b) {
    auto& s=*static_cast<ShieldAudio*>(ctx);
    for(UInt32 i=0;i<b->mNumberBuffers;i++) if(b->mBuffers[i].mData) std::memset(b->mBuffers[i].mData,0,b->mBuffers[i].mDataByteSize);
    if(!s.running.load() || s.error.load() || !s.primed.load()) return noErr;
    if(b->mNumberBuffers!=1 || b->mBuffers[0].mDataByteSize<count*sizeof(float) || !b->mBuffers[0].mData) { s.fail(-7003); return noErr; }
    if(!s.playback.pop(static_cast<float*>(b->mBuffers[0].mData),count)) {
        s.underruns.fetch_add(1); s.fail(-7004);
    }
    return noErr;
}
static AudioStreamBasicDescription format(double rate) {
    AudioStreamBasicDescription f{};
    f.mSampleRate=rate; f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=kAudioFormatFlagsNativeFloatPacked;
    f.mBytesPerPacket=4; f.mFramesPerPacket=1; f.mBytesPerFrame=4;
    f.mChannelsPerFrame=1; f.mBitsPerChannel=32; return f;
}
static OSStatus setupUnit(AudioUnit& unit,AudioDeviceID device,bool capture,double rate,ShieldAudio* s, AURenderCallback overrideCallback=nullptr) {
    AudioComponentDescription d{kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    auto component=AudioComponentFindNext(nullptr,&d);
    if(!component) return -7005;
    OSStatus status=AudioComponentInstanceNew(component,&unit); if(status) return status;
    auto set=[&](AudioUnitPropertyID p,AudioUnitScope scope,AudioUnitElement element,const void* v,UInt32 n) {
        if(!status) status=AudioUnitSetProperty(unit,p,scope,element,v,n);
    };
    UInt32 one=1,zero=0,max=8192;
    set(kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,capture?&one:&zero,4);
    set(kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,capture?&zero:&one,4);
    set(kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device));
    auto f=format(rate);
    set(kAudioUnitProperty_StreamFormat,capture?kAudioUnitScope_Output:kAudioUnitScope_Input,capture?1:0,&f,sizeof(f));
    set(kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&max,4);
    AURenderCallbackStruct callback{capture?inputCallback:outputCallback,s};
    if(overrideCallback) callback.inputProc=overrideCallback;
    set(capture?AudioUnitPropertyID(kAudioOutputUnitProperty_SetInputCallback):AudioUnitPropertyID(kAudioUnitProperty_SetRenderCallback),
        capture?kAudioUnitScope_Global:kAudioUnitScope_Input,0,&callback,sizeof(callback));
    if(!status) status=AudioUnitInitialize(unit);
    return status;
}
static void runWorker(ShieldAudio* s) {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0);
        std::array<float,shield::block> in{},out{};
        auto last=Clock::now();
        while(s->running.load() && !s->error.load()) {
            // Compensate independent input/output clocks with a bounded rate correction.
            double drift=s->primed.load()?std::clamp((double(s->playback.size())-s->targetFrames)/1440000.,-.001,.001):0;
            auto blockStart=Clock::now();
            if(!s->resampler.render(s->capture,s->inputRate*(1+drift),in.data(),in.size())) {
                if(Clock::now()-last>std::chrono::seconds(2)) s->fail(-7008);
                std::this_thread::sleep_for(std::chrono::milliseconds(1)); continue;
            }
            last=Clock::now();
            if(s->processing.load()) {
                if(!s->processor(s->context,in.data(),out.data(),uint32_t(out.size()))) {s->fail(-7009);break;}
            } else {
                // Explicit user opt-out: normal voice, without reopening the call's device.
                std::copy(in.begin(),in.end(),out.begin());
            }
            double elapsed=std::chrono::duration<double,std::milli>(Clock::now()-blockStart).count();
            s->processingMs=elapsed;
            s->maximumMs=std::max(s->maximumMs.load(),elapsed);
            if(elapsed>10) s->overBudget.fetch_add(1);
            if(elapsed>100) {s->fail(-7010);break;}
            bool valid=true;
            for(float& x:out) {if(!std::isfinite(x)) {valid=false;break;} x=std::clamp(x,-.98f,.98f);}
            if(!valid) {s->fail(-7011);break;}
            if(s->capture.size()/s->inputRate>.1 || s->playback.size()>4800) {s->fail(-7012);break;}
            if(!s->playback.push(out.data(),out.size())) {s->fail(-7013);break;}
            s->processed.fetch_add(1);
            if(s->playback.size()>=s->targetFrames) s->primed=true;
        }
}
extern "C" ShieldAudio* shield_audio_create() { return new ShieldAudio; }
extern "C" int32_t shield_audio_start(ShieldAudio* s,uint32_t input,uint32_t output,ShieldProcess process,void* ctx) {
    if(!s || s->input || s->output || !process || input==output) return -7006;
    AudioObjectPropertyAddress address{kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 n=sizeof(double);
    OSStatus status=AudioObjectGetPropertyData(input,&address,0,nullptr,&n,&s->inputRate);
    if(status || !std::isfinite(s->inputRate) || s->inputRate<8000 || s->inputRate>192000) return status?status:-7007;
    // Hardware input can arrive in larger bursts than the output callback.
    // Prime enough for both periods; reject configurations outside our latency cap.
    address.mSelector=kAudioDevicePropertyBufferFrameSize;
    UInt32 inputFrames=0,outputFrames=0; n=sizeof(UInt32);
    status=AudioObjectGetPropertyData(input,&address,0,nullptr,&n,&inputFrames);
    if(!status) status=AudioObjectGetPropertyData(output,&address,0,nullptr,&n,&outputFrames);
    if(status) return status;
    double target=std::ceil(inputFrames/s->inputRate*shield::rate)+outputFrames+shield::block;
    if(!inputFrames || !outputFrames || inputFrames>8192 || target>3840) return -7014;
    s->targetFrames=std::max(1440u,uint32_t(target));
    s->resampler.prepare(s->inputRate);
    s->processor=process; s->context=ctx;
    status=setupUnit(s->input,input,true,s->inputRate,s);
    if(!status) status=setupUnit(s->output,output,false,shield::rate,s);
    if(!status) status=setupUnit(s->probe,output,true,shield::rate,s,probeCallback);
    if(status) { shield_audio_stop(s); return status; }
    s->running=true;
    s->worker=std::thread(runWorker,s);
    status=AudioOutputUnitStart(s->output);
    if(!status) status=AudioOutputUnitStart(s->probe);
    if(!status) status=AudioOutputUnitStart(s->input);
    if(status) shield_audio_stop(s);
    return status;
}
extern "C" void shield_audio_set_processing(ShieldAudio* s,bool enabled) { if(s) s->processing=enabled; }
extern "C" void shield_audio_stop(ShieldAudio* s) {
    if(!s) return;
    s->running=false; s->primed=false;
    // Keep output callbacks producing silence while a possibly slow model finishes.
    if(s->probe) {AudioOutputUnitStop(s->probe);AudioUnitUninitialize(s->probe);AudioComponentInstanceDispose(s->probe);s->probe=nullptr;}
    if(s->input) AudioOutputUnitStop(s->input);
    if(s->worker.joinable()) s->worker.join();
    if(s->output) {AudioOutputUnitStop(s->output);AudioUnitUninitialize(s->output);AudioComponentInstanceDispose(s->output);s->output=nullptr;}
    if(s->input) {AudioUnitUninitialize(s->input);AudioComponentInstanceDispose(s->input);s->input=nullptr;}
}
extern "C" void shield_audio_destroy(ShieldAudio* s) { shield_audio_stop(s); delete s; }
extern "C" ShieldMetrics shield_audio_metrics(ShieldAudio* s) {
    return {s->error.load(),s->processed.load(),s->underruns.load(),s->processingMs.load(),
        1000*(s->capture.size()/s->inputRate+s->playback.size()/double(shield::rate)),s->maximumMs.load(),s->overBudget.load(),s->received.load(),s->receivedSignal.load()};
}
extern "C" void* shield_baseline_create() { return new shield::Baseline; }
extern "C" void shield_baseline_process(void* p,const float* in,float* out,uint32_t n,float strength) { static_cast<shield::Baseline*>(p)->process(in,out,n,strength); }
extern "C" void shield_baseline_destroy(void* p) { delete static_cast<shield::Baseline*>(p); }
