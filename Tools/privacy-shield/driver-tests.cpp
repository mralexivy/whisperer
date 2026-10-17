// Exercise the production driver callbacks in-process without installing a HAL plugin.
#include "../../Platform/macOS/VirtualMicrophone/Driver.cpp"
#include <cassert>
#include <iostream>
int main() {
    Handler handler;
    auto writer=handler.OnAddClient({0,0,true,"com.ivy.whisperer"});
    auto secondWriter=handler.OnAddClient({2,0,true,"com.ivy.whisperer"});
    auto other=handler.OnAddClient({3,0,true,"org.example.call"});
    std::array<float,512> source{},first{},second{};
    for(size_t i=0;i<source.size();++i) source[i]=float(i)/1024;
    auto read=[&](auto client, double time, auto& output) {
        output.fill(1);
        handler.OnReadClientInput(client,nullptr,0,time,output.data(),sizeof(output));
    };
    auto silent=[](auto& output) { return std::all_of(output.begin(),output.end(),[](float x){return x==0;}); };
    handler.OnStartIO();
    read(other,1024,first); assert(silent(first));
    handler.OnWriteClientOutput(other,nullptr,0,0,source.data(),512,1);
    read(other,1024,first); assert(silent(first));
    handler.OnWriteClientOutput(writer,nullptr,0,0,source.data(),512,1);
    read(other,1024,first); read(secondWriter,1024,second);
    assert(first==source && second==source);
    read(other,1536,first); assert(silent(first)); // absent frames cannot replay
    std::array<float,512> unwanted{}; unwanted.fill(-.8);
    handler.OnWriteClientOutput(secondWriter,nullptr,0,0,unwanted.data(),512,1);
    read(other,1024,first); assert(first==source); // only one producer
    handler.OnRemoveClient(writer);
    read(other,1024,first); assert(silent(first));
    handler.OnWriteClientOutput(secondWriter,nullptr,0,512,source.data(),512,1);
    read(other,1536,first); assert(first==source); // replacement may own the route
    handler.OnWriteClientOutput(secondWriter,nullptr,0,1e30,source.data(),512,1);
    read(other,1e30,first); assert(silent(first));
    handler.OnStartIO();
    read(other,1536,first); assert(silent(first));
    std::cout << "Driver callback tests passed: unowned silence, producer filtering, two readers, missing timestamps, producer removal and replacement, restart.\n";
}
