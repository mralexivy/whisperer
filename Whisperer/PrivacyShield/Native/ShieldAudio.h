#ifndef SHIELD_AUDIO_H
#define SHIELD_AUDIO_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ShieldAudio ShieldAudio;
// Called exclusively on the processing worker with 480 mono float32 frames at 48 kHz.
// Returning false mutes permanently until the session is explicitly restarted.
typedef bool (*ShieldProcess)(void*, const float*, float*, uint32_t);
typedef struct {
    int32_t error;
    uint64_t processedBlocks;
    uint64_t underruns;
    double processingMilliseconds;
    double queuedMilliseconds;
    double maximumProcessingMilliseconds;
    uint64_t overBudgetBlocks;
    uint64_t receivedFrames;
    uint64_t receivedSignalFrames;
} ShieldMetrics;
void shield_set_capture_blocked(bool);
bool shield_capture_blocked(void);
ShieldAudio* shield_audio_create(void);
int32_t shield_audio_start(ShieldAudio*, uint32_t input, uint32_t output, ShieldProcess, void*);
void shield_audio_set_processing(ShieldAudio*, bool);
void shield_audio_stop(ShieldAudio*);
void shield_audio_destroy(ShieldAudio*);
ShieldMetrics shield_audio_metrics(ShieldAudio*);
void* shield_baseline_create(void);
void shield_baseline_process(void*, const float*, float*, uint32_t, float);
void shield_baseline_destroy(void*);
// Predictive perturbation network (ShieldPNet.hpp). Returns NULL if the weights file is invalid.
void* shield_pnet_create(const char* weightsPath);
void shield_pnet_process(void*, const float*, float*, uint32_t, float strength);
void shield_pnet_reset(void*);
void shield_pnet_destroy(void*);
// Transcription jammer (ShieldJammer.hpp): local time reversal with randomised frame lengths.
// Returns NULL for out-of-range parameters. Output is delayed by shield_jammer_latency() samples.
void* shield_jammer_create(float frameMs, float fadeMs, float jitter, uint32_t seed);
void shield_jammer_process(void*, const float*, float*, uint32_t, float strength);
uint32_t shield_jammer_latency(void*);
void shield_jammer_reset(void*);
void shield_jammer_destroy(void*);
#ifdef __cplusplus
}
#endif
#endif
