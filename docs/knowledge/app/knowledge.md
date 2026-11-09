
## Energy tracking (2026-11-09)
- On 2026-11-09 the work Mac drained 100% → 9% in 68 min on battery; macOS's powerlog put Whisperer at 10–21 W, 94% GPU, during a meeting whose eager stream was stalled (40-pass loops over a capped window the whole call).
- `EnergyMonitor` samples once a minute: process energy from `task_info(TASK_POWER_INFO_V2).task_energy` (nJ), GPU time from IORegistry `IOAccelerator` user clients' `AppUsage.accumulatedGPUTime` for our pid (`task_gpu_utilisation` reads 0 on Apple Silicon), Mac draw from AppleSmartBattery voltage × InstantAmperage on battery, and the app phase.
- Log: `Energy: <phase> N min — W (Wh), GPU %, Mac W on battery` per phase ≥ 2 min; a warning at ≥ 8 W for 3 min. Stall dumps carry the last 30 min per minute.
