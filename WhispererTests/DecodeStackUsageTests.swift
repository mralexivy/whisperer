//
//  DecodeStackUsageTests.swift
//  WhispererTests
//
//  How much thread stack does a whisper.cpp decode actually consume?
//
//  Every non-main thread on macOS gets 512 KB: measured on 2026-08-17,
//  `pthread_get_stacksize_np` returns 536576 for a libdispatch worker, a Swift concurrency
//  cooperative-pool worker, and a default `Thread` alike. Only the main thread gets 8 MB.
//
//  `StreamingTranscriber.stopAsync` runs the tail decode inside `Task.detached`, so
//  `whisper_full` executes synchronously on one of those 512 KB stacks. If its high-water mark
//  is anywhere near that, the stop path is one long prompt or one deep segment away from
//  running off the end of the stack — which faults on the guard page as
//  `EXC_BAD_ACCESS (code=2)` at a `0x16…` address, exactly what was reported.
//
//  This test measures the real number by painting a known pattern down the stack of a
//  dedicated thread, running a real decode, and finding the deepest byte that changed.
//

import XCTest
@testable import whisperer

/// File-scope, not static members: the `pthread_create` entry point must be a C function
/// pointer, which cannot capture context — so it has to reach these by global reference.
private let paintByte: UInt8 = 0xA5
private nonisolated(unsafe) var probeBody: (() -> Void)?
private nonisolated(unsafe) var probeUsed = 0
private nonisolated(unsafe) var probeCapacity = 0
private nonisolated(unsafe) var probeWindow = 0
final class DecodeStackUsageTests: XCTestCase {

    /// Every thread the app decodes on, except the main thread, has this much stack.
    private static let workerStackBytes = 512 * 1024

    /// Stack given to the measurement thread. Deliberately far larger than a worker's, so the
    /// decode cannot fault while we are measuring how much room it would have needed.
    private static let measurementStackBytes = 16 * 1024 * 1024

    func testDecodeStackHighWaterFitsInAWorkerThreadStack() throws {
        let bridge = try loadWhisperBridge()

        let fixtures = HistoryTestLoader.loadFixtures(maxCount: 60)
            .filter { $0.audioURL != nil }
        try XCTSkipIf(fixtures.isEmpty, "No history fixtures with audio on disk")

        // Tail lengths the stop path actually produces, plus a long window to see whether usage
        // scales with the audio at all.
        let lengths: [Double] = [0.6, 2.0, 3.3, 12.0, 30.0]
        var rows: [(seconds: Double, bytes: Int)] = []

        for seconds in lengths {
            var samples: [Float] = []
            for fixture in fixtures {
                guard let url = fixture.audioURL,
                      let loaded = try? loadAudioSamples(from: url) else { continue }
                let n = Int(seconds * 16000)
                guard loaded.count > n else { continue }
                samples = Array(loaded.suffix(n))
                break
            }
            guard !samples.isEmpty else { continue }

            // A long prompt is the worst case for the decoder's own frames, and the stop path
            // always supplies one (`prepareTailTranscription` carries the boundary words).
            let prompt = String(repeating: "boundary context words ", count: 20)

            let (used, capacity, window) = Self.measureStackUsage {
                _ = bridge.transcribe(samples: samples, initialPrompt: prompt, language: .auto)
            }
            print("  measured \(seconds)s: used=\(used) window=\(window) capacity=\(capacity)")
            fflush(stdout)
            XCTAssertLessThan(used, window,
                              "usage filled the whole measurement window — the number is a "
                                  + "floor, not a measurement; widen requestedWindow")
            XCTAssertGreaterThanOrEqual(capacity, Self.measurementStackBytes,
                                        "measurement thread only got \(capacity) bytes of stack; "
                                            + "the high-water number below would be meaningless")
            rows.append((seconds, used))
        }

        try XCTSkipIf(rows.isEmpty, "No usable audio segments")

        print("\n=== whisper_full stack high-water ===")
        print("worker thread stack: \(Self.workerStackBytes) bytes (512 KB)")
        for r in rows {
            let pct = Double(r.bytes) / Double(Self.workerStackBytes) * 100
            print(String(format: "%6.1fs audio -> %9d bytes (%.1f%% of a worker stack)",
                         r.seconds, r.bytes, pct))
        }
        let worst = rows.map(\.bytes).max() ?? 0
        print(String(format: "worst: %d bytes (%.1f%% of 512 KB)\n",
                     worst, Double(worst) / Double(Self.workerStackBytes) * 100))

        // The gate: a decode must not come close to filling a worker stack. 50% is the line —
        // above it there is no headroom for the Swift frames above `whisper_full`, the signal
        // handler, or a deeper prompt, and the stop path is one bad input from the guard page.
        XCTAssertLessThan(
            worst, Self.workerStackBytes / 2,
            "whisper_full needs \(worst) bytes of stack; a worker thread only has "
                + "\(Self.workerStackBytes). The tail decode runs on such a thread "
                + "(StreamingTranscriber.stopAsync -> Task.detached -> stop -> transcribeTail), "
                + "so it can fault on the guard page as EXC_BAD_ACCESS(code=2)."
        )
    }

    // MARK: - Measurement

    /// Runs `body` on a dedicated large-stack thread with the stack pre-painted, and returns the
    /// number of bytes below the entry frame that `body` (and everything it called) touched.
    ///
    /// The payload travels through file-scope globals rather than an `Unmanaged` box. That is not
    /// laziness: `pthread_create`'s entry point must be a context-free C function pointer, and
    /// routing a local class through `Unmanaged.passRetained` made its deinit run on the
    /// task-executor deinit path and abort in libmalloc every single run. The thread is created
    /// and joined inside this one call, so a global is exactly as safe and has no such machinery.
    private static func measureStackUsage(_ body: @escaping () -> Void) -> (used: Int, capacity: Int, window: Int) {
        probeBody = body
        probeUsed = 0
        probeCapacity = 0
        probeWindow = 0

        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        pthread_attr_setstacksize(&attr, measurementStackBytes)

        var tid: pthread_t?
        pthread_create(&tid, &attr, { _ -> UnsafeMutableRawPointer? in
            probeCapacity = pthread_get_stacksize_np(pthread_self())

            // Two lessons paid for in crashes, both encoded here:
            //
            // 1. Clamp the painted region to this thread's OWN allocation. An earlier version
            //    derived it from `pthread_get_stackaddr_np` minus the reported size with no
            //    clamp, painted outside the stack, and corrupted the malloc heap.
            // 2. Leave the deepest slice unpainted. `&probe` is in *this* frame, but the frames
            //    of the closures doing the painting sit BELOW it — painting right up to `&probe`
            //    overwrites their own saved return addresses, and the thread jumps to
            //    0xa5a5a5a5a5a5a5a5 the moment it returns. (Observed: that exact fault.)
            //    Everything under the reserve is charged to the result unmeasured.
            let ownFrameReserve = 16 * 1024
            let requestedWindow = 4 * 1024 * 1024

            var probe: UInt8 = 0
            withUnsafeMutablePointer(to: &probe) { probePtr in
                let ceiling = UnsafeMutableRawPointer(probePtr) - ownFrameReserve
                // Verified on 2026-08-17: `pthread_get_stackaddr_np` is the HIGH address and the
                // stack is exactly [high - size, high), growing down toward the guard page.
                let stackHigh = pthread_get_stackaddr_np(pthread_self())
                let stackFloor = stackHigh - probeCapacity + 64 * 1024
                let low = max(ceiling - requestedWindow, stackFloor)
                let span = low.distance(to: ceiling)
                guard span > 0 else { probeUsed = -2; return }
                probeWindow = span

                memset(low, Int32(paintByte), span)

                probeBody?()

                // The deepest untouched byte marks the high-water line. Scan up from the bottom
                // for the first byte that is no longer the paint value.
                let bytes = low.assumingMemoryBound(to: UInt8.self)
                var i = 0
                while i < span && bytes[i] == paintByte { i += 1 }
                probeUsed = (span - i) + ownFrameReserve
            }
            return nil
        }, nil)

        if let tid { pthread_join(tid, nil) }
        pthread_attr_destroy(&attr)
        probeBody = nil
        return (probeUsed, probeCapacity, probeWindow)
    }
}
