// Real-time budget for the native predictive network: per-block time over 10,000 blocks (100 s audio).
#include "../../Whisperer/PrivacyShield/Native/ShieldPNet.hpp"
#include <chrono>
#include <cstdio>
#include <vector>
int main(int argc, char** argv) {
    if (argc < 2) { std::fprintf(stderr, "usage: pnet-performance WEIGHTS.wspn\n"); return 2; }
    shield::PNet net; std::string err;
    if (!net.load(argv[1], &err)) { std::fprintf(stderr, "load failed: %s\n", err.c_str()); return 1; }
    std::vector<float> in(480), out(480); std::vector<double> ms;
    for (int b = 0; b < 10000; b++) {
        for (int i = 0; i < 480; i++) in[i] = 0.3f * std::sin(2 * M_PI * 180 * (b * 480 + i) / 48000.0);
        auto t0 = std::chrono::steady_clock::now();
        net.process(in.data(), out.data(), 480, 1.f);
        ms.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    }
    std::sort(ms.begin(), ms.end());
    std::printf("blocks %zu  median %.3f ms  p99 %.3f ms  max %.3f ms  (budget 10 ms)\n", ms.size(), ms[ms.size() / 2], ms[ms.size() * 99 / 100], ms.back());
    return ms[ms.size() * 99 / 100] < 2.0 ? 0 : 1;
}
