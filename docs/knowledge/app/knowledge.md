
## Energy tracking (2026-11-09)
- On 2026-11-09 the work Mac drained 100% → 9% in 68 min on battery; macOS's powerlog put Whisperer at 10–21 W, 94% GPU, during a meeting whose eager stream was stalled (40-pass loops over a capped window the whole call).
- `EnergyMonitor` samples once a minute: process energy from `task_info(TASK_POWER_INFO_V2).task_energy` (nJ), GPU time from IORegistry `IOAccelerator` user clients' `AppUsage.accumulatedGPUTime` for our pid (`task_gpu_utilisation` reads 0 on Apple Silicon), Mac draw from AppleSmartBattery voltage × InstantAmperage on battery, and the app phase.
- Log: `Energy: <phase> N min — W (Wh), GPU %, Mac W on battery` per phase ≥ 2 min; a warning at ≥ 8 W for 3 min. Stall dumps carry the last 30 min per minute.

## Idle and meeting energy pass (2026-11-09)
- `DockPresenceMonitor` polled the Dock at 60 Hz from launch for the life of the process — 60 main-thread wakeups a second while idle. Now 60 Hz only while recording, 2 Hz otherwise (`setFastPolling`, driven by `AppState.state`).
- `HealthManager` checks the main thread every 1 s while recording, every 5 s idle.
- `StreamingTranscriber.scanAndProcessChunks` returns before copying the ring when the live engine writes the meeting (it copied up to 35 s of audio twice a second for nothing).
- Apple language ID checks the session's language first; ≥ 0.65 confirms it in one pass (the highest wrong-locale confidence in the benchmark was 0.54). he→en replay: same ~3 s switch, language-ID time 15.2 s → 9.0 s over 205 s.
