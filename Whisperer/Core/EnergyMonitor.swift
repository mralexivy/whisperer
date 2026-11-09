//
//  EnergyMonitor.swift
//  Whisperer
//
//  How much power Whisperer itself draws, and while doing what. On 2026-11-09 a 68-minute
//  stretch on battery (100% → 9%) had Whisperer at 10–21 W, 94% of it GPU, during a meeting —
//  found only by querying macOS's power log by hand. This keeps the same numbers in our own log.
//
//  Once a minute, on the main thread (each read is a syscall or one IORegistry lookup):
//  - the process's energy from `task_info(TASK_POWER_INFO_V2)` (`task_energy`, nJ) → watts;
//  - its GPU time → GPU busy share. `gpu_energy.task_gpu_utilisation` reads 0 on Apple Silicon,
//    so it comes from the GPU driver's per-client `AppUsage.accumulatedGPUTime` (ns) in the
//    IORegistry — what Activity Monitor's GPU column reads;
//  - on battery, the whole machine's draw from AppleSmartBattery (voltage × current), so the log
//    can say whether Whisperer is the drain or a passenger;
//  - the app's phase (idle, dictation, meeting, meeting processing, decoding).
//
//  Logged sparingly — the whole-app log budget is a few hundred lines a day:
//  - one line per phase that lasted 2+ minutes, with its averages;
//  - a warning when Whisperer averages ≥ 8 W for 3 minutes running (at most every 10 minutes).
//  The last 30 minutes of samples go into every stall dump.
//

import Foundation
import IOKit

@MainActor
final class EnergyMonitor {

    static let shared = EnergyMonitor()

    enum Phase: String, Sendable {
        case idle, dictation, meeting, processing, decoding
    }

    struct Sample: Sendable {
        let at: Date
        let seconds: Double
        let appWatts: Double
        /// Share of the interval the process had work on the GPU, 0…1.
        let gpuBusy: Double
        /// Whole-machine draw from the battery; nil on AC.
        let systemWatts: Double?
        let phase: Phase
    }

    static let interval: TimeInterval = 60
    static let highWatts = 8.0
    static let highMinutes = 3
    static let highWarningSpacing: TimeInterval = 600
    static let minimumPhaseSeconds: TimeInterval = 120

    private var timer: Timer?
    private var last: (at: Date, energy: UInt64, gpu: UInt64)?
    private var samples: [Sample] = []
    private var lastHighWarning: Date?
    private var phaseSamples: [Sample] = []

    private init() {}

    func start() {
        guard timer == nil else { return }
        last = Self.readTask().map { (Date(), $0.energy, $0.gpu) }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { EnergyMonitor.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        flushPhase()
        timer?.invalidate()
        timer = nil
    }

    /// Samples from the last `minutes`, oldest first.
    func recent(minutes: Int) -> [Sample] {
        let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
        return samples.filter { $0.at >= cutoff }
    }

    // MARK: - Sampling

    private func tick() {
        guard let now = Self.readTask(), let previous = last else { return }
        let at = Date()
        let seconds = at.timeIntervalSince(previous.at)
        last = (at, now.energy, now.gpu)
        guard seconds > 1 else { return }
        let joules = Double(now.energy &- previous.energy) / 1e9
        let gpuSeconds = Double(now.gpu &- previous.gpu) / 1e9
        let sample = Sample(at: at, seconds: seconds, appWatts: joules / seconds,
                            gpuBusy: min(1, max(0, gpuSeconds / seconds)),
                            systemWatts: Self.batteryDrawWatts(), phase: Self.currentPhase())
        samples.append(sample)
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }

        if let open = phaseSamples.last, open.phase != sample.phase { flushPhase() }
        phaseSamples.append(sample)
        checkHigh()
    }

    private func checkHigh() {
        let window = samples.suffix(Self.highMinutes)
        guard window.count == Self.highMinutes, window.allSatisfy({ $0.appWatts >= Self.highWatts }) else { return }
        if let lastHighWarning, Date().timeIntervalSince(lastHighWarning) < Self.highWarningSpacing { return }
        lastHighWarning = Date()
        Logger.warning("Energy: Whisperer at \(Self.describe(Array(window))) for \(Self.highMinutes) min", subsystem: .app)
    }

    private func flushPhase() {
        defer { phaseSamples = [] }
        guard let first = phaseSamples.first else { return }
        let seconds = phaseSamples.reduce(0) { $0 + $1.seconds }
        guard seconds >= Self.minimumPhaseSeconds else { return }
        Logger.info("Energy: \(first.phase.rawValue) \(Int(seconds / 60)) min — \(Self.describe(phaseSamples))", subsystem: .app)
    }

    /// "14.6 W (3.6 Wh), GPU 93%, Mac 75 W on battery" over `samples`, time-weighted.
    nonisolated static func describe(_ samples: [Sample]) -> String {
        let seconds = samples.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return "no samples" }
        let joules = samples.reduce(0) { $0 + $1.appWatts * $1.seconds }
        let gpu = samples.reduce(0) { $0 + $1.gpuBusy * $1.seconds } / seconds
        var text = String(format: "%.1f W (%.1f Wh), GPU %.0f%%", joules / seconds, joules / 3600, gpu * 100)
        let onBattery = samples.filter { $0.systemWatts != nil }
        if !onBattery.isEmpty {
            let batterySeconds = onBattery.reduce(0) { $0 + $1.seconds }
            let system = onBattery.reduce(0) { $0 + ($1.systemWatts ?? 0) * $1.seconds } / batterySeconds
            text += String(format: ", Mac %.0f W on battery", system)
        } else {
            text += ", on AC"
        }
        return text
    }

    /// Per-minute table for stall dumps.
    func renderDumpSection() -> String {
        var out = "\n## Energy (last 30 min)\n\n"
        let recent = recent(minutes: 30)
        guard !recent.isEmpty else { return out + "_no samples yet_\n" }
        out += "Summary: \(Self.describe(recent))\n\n"
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        for s in recent {
            out += String(format: "- %@  %@  app %.1f W  GPU %3.0f%%  %@\n",
                          formatter.string(from: s.at), s.phase.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0),
                          s.appWatts, s.gpuBusy * 100,
                          s.systemWatts.map { String(format: "Mac %.0f W", $0) } ?? "AC")
        }
        return out
    }

    // MARK: - Sources

    private static func currentPhase() -> Phase {
        let app = AppState.shared
        if app.isMeetingMode { return .meeting }
        switch app.state {
        case .recording, .stopping, .transcribing: return .dictation
        default: break
        }
        if MeetingJobQueue.shared.isProcessing { return .processing }
        if WhisperBridge.isDecoding { return .decoding }
        return .idle
    }

    nonisolated static func readTask() -> (energy: UInt64, gpu: UInt64)? {
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (info.task_energy, ownGPUTimeNanoseconds())
    }

    /// Total GPU time of this process's Metal clients, summed across `IOAccelerator` user clients
    /// whose `IOUserClientCreator` is "pid <ours>, …".
    nonisolated static func ownGPUTimeNanoseconds() -> UInt64 {
        let prefix = "pid \(ProcessInfo.processInfo.processIdentifier),"
        var accelerators: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accelerators) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(accelerators) }
        var total: UInt64 = 0
        var accelerator = IOIteratorNext(accelerators)
        while accelerator != 0 {
            var clients: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &clients) == KERN_SUCCESS {
                var client = IOIteratorNext(clients)
                while client != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       creator.hasPrefix(prefix),
                       let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                        for entry in usage {
                            total &+= (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0
                        }
                    }
                    IOObjectRelease(client)
                    client = IOIteratorNext(clients)
                }
                IOObjectRelease(clients)
            }
            IOObjectRelease(accelerator)
            accelerator = IOIteratorNext(accelerators)
        }
        return total
    }

    /// The machine's draw from its battery, or nil on AC (or a Mac without one).
    nonisolated private static func batteryDrawWatts() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        if (property("ExternalConnected") as? Bool) == true { return nil }
        guard let millivolts = (property("Voltage") as? NSNumber)?.doubleValue,
              let milliamps = ((property("InstantAmperage") ?? property("Amperage")) as? NSNumber)?.doubleValue,
              milliamps < 0 else { return nil }
        return millivolts * -milliamps / 1e6
    }
}
