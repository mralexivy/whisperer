// Whisperer loopback transport. libASPL handles HAL property dispatch.
#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>
#include "../../../Whisperer/PrivacyShield/Native/ShieldDSP.hpp"

namespace {
constexpr uint64_t delayFrames=1024;
struct Client final: aspl::Client {
    const bool producer;
    explicit Client(const aspl::ClientInfo& info):aspl::Client(info),producer(GetBundleID()=="com.ivy.whisperer") {}
};
class Handler final: public aspl::ControlRequestHandler,public aspl::IORequestHandler {
    shield::Timeline timeline;
    // Encode client ID + 1: HAL may legitimately assign client ID zero.
    std::atomic<uint64_t> writer{0};
public:
    OSStatus OnStartIO() override { timeline.clear(); writer=0; return noErr; }
    std::shared_ptr<aspl::Client> OnAddClient(const aspl::ClientInfo& info) override { return std::make_shared<Client>(info); }
    void OnRemoveClient(std::shared_ptr<aspl::Client> client) override {
        uint64_t id=uint64_t(client->GetClientID())+1;
        if(writer.compare_exchange_strong(id,0)) timeline.clear();
    }
    void OnWriteClientOutput(const std::shared_ptr<aspl::Client>& client,const std::shared_ptr<aspl::Stream>&,
                            Float64,Float64 timestamp,const Float32* frames,UInt32 count,UInt32 channels) override {
        if(!static_cast<Client*>(client.get())->producer || channels!=1 || !std::isfinite(timestamp) || timestamp<0 || timestamp>double(INT64_MAX)-count) return;
        uint64_t key=uint64_t(client->GetClientID())+1, none=0; writer.compare_exchange_strong(none,key);
        if(writer.load()!=key) return;
        auto start=uint64_t(timestamp);
        for(UInt32 i=0;i<count;i++) timeline.write(start+i,frames[i]);
    }
    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,const std::shared_ptr<aspl::Stream>&,
                          Float64,Float64 timestamp,void* bytes,UInt32 byteCount) override {
        std::memset(bytes,0,byteCount);
        if(!writer.load() || !std::isfinite(timestamp) || timestamp<double(delayFrames) || timestamp>double(INT64_MAX)-byteCount/sizeof(float)) return;
        auto out=static_cast<float*>(bytes); auto start=uint64_t(timestamp)-delayFrames;
        for(UInt32 i=0;i<byteCount/sizeof(float);i++) out[i]=timeline.read(start+i);
    }
};
std::shared_ptr<aspl::Driver> makeDriver() {
    auto context=std::make_shared<aspl::Context>(std::make_shared<aspl::Tracer>(aspl::Tracer::Mode::Noop));
    aspl::DeviceParameters params;
    params.Name="Whisperer Virtual Mic"; params.Manufacturer="Whisperer";
    params.DeviceUID="com.ivy.whisperer.privacy-mic.v1"; params.ModelUID=params.DeviceUID;
    params.SampleRate=shield::rate; params.ChannelCount=1; params.EnableMixing=false;
    params.CanBeDefault=true; params.CanBeDefaultForSystemSounds=false;
    params.ZeroTimeStampPeriod=512; params.Latency=delayFrames;
    auto device=std::make_shared<aspl::Device>(context,params);
    aspl::StreamParameters stream;
    stream.Format={48000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked,4,1,4,1,32,0};
    stream.Direction=aspl::Direction::Input; device->AddStreamAsync(stream);
    stream.Direction=aspl::Direction::Output; device->AddStreamAsync(stream);
    auto handler=std::make_shared<Handler>(); device->SetControlHandler(handler); device->SetIOHandler(handler);
    auto plugin=std::make_shared<aspl::Plugin>(context); plugin->AddDevice(device);
    return std::make_shared<aspl::Driver>(context,plugin);
}
}
extern "C" void* WhispererAudioEntry(CFAllocatorRef,CFUUIDRef type) {
    if(!CFEqual(type,kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver=makeDriver(); return driver->GetReference();
}
