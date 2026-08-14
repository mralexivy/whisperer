//
//  MainThreadBacktrace.swift
//  Whisperer
//
//  In-process backtrace of the main thread, captured from a watchdog thread while
//  the main thread is wedged.
//

import Foundation
import Darwin

/// Captures where the main thread actually is during a hang.
///
/// ### Why not `/usr/bin/sample`
/// `StuckStateDumper` used to shell out to `sample`, which is the right tool and produces a far
/// better report — but it cannot run here. The App Store build is sandboxed, so `Process` cannot
/// spawn it at all, and even unsandboxed it needs `task_for_pid` on another process, which is
/// gated behind the debugger entitlement or an admin authorization prompt. Every dump written
/// from a real user's machine carried an empty `## Thread Sample`, which is the one section that
/// would have named the blocking frame. An in-process unwind needs no entitlement: a task always
/// has the right to inspect its own threads.
///
/// ### The suspend window is the dangerous part
/// Between `thread_suspend` and `thread_resume` the main thread may be holding the malloc lock or
/// the dyld lock. Allocating, symbolicating, or logging in that window deadlocks the watchdog
/// against the very thread it is inspecting — and now nothing can recover. So the window contains
/// exactly three things: read the register state, walk the frame pointers with
/// `vm_read_overwrite`, resume. Addresses land in a buffer allocated once at file scope.
/// `dladdr` and every string operation happen strictly after the resume.
///
/// This is the standard crash-reporter shape, applied to a live hang rather than a signal.
enum MainThreadBacktrace {

    /// Deep enough to reach through SwiftUI/AppKit and name the blocking callee; short enough
    /// that a corrupt frame pointer chain cannot spin.
    private static let maxFrames = 64

    /// Reports older than this are stale evidence for a dump being written now.
    private static let defaultMaxAge: TimeInterval = 120

    // MARK: - State

    /// Mach port for the main thread. Recorded from the main thread itself — `mach_thread_self()`
    /// is the only way to name it, and it must therefore be called *on* it.
    ///
    /// The port right this returns is deliberately never deallocated: the main thread lives for
    /// the whole process, and dropping the right would leave the watchdog with a dangling name.
    private static var mainThreadPort: mach_port_t = 0   // MACH_PORT_NULL

    /// Scratch space for the unwind. Allocated once so the suspend window never calls malloc.
    private static let frameBuffer = UnsafeMutablePointer<UInt64>.allocate(capacity: maxFrames)

    private static let lock = NSLock()
    private static var latest: Report?

    struct Report {
        let reason: String
        let capturedAt: Date
        let frames: [String]
        /// Set when the unwind could not run at all (no port, suspend failed, bad state).
        let failure: String?
    }

    // MARK: - Registration

    /// Records the calling thread as the main thread. Call once, from the main thread.
    static func registerMainThread() {
        guard Thread.isMainThread else { return }
        lock.lock()
        defer { lock.unlock() }
        guard mainThreadPort == 0 else { return }
        mainThreadPort = mach_thread_self()
    }

    // MARK: - Capture

    /// Suspends the main thread, walks its stack, resumes it, then symbolicates.
    ///
    /// MUST be called from a non-main thread — suspending the thread you are running on is a
    /// self-deadlock with no recovery path.
    static func capture(reason: String) {
        guard !Thread.isMainThread else { return }

        lock.lock()
        let port = mainThreadPort
        lock.unlock()

        guard port != 0 else {
            store(Report(reason: reason, capturedAt: Date(), frames: [],
                         failure: "main thread was never registered"))
            return
        }

        // ---- suspend window: no allocation, no symbolication, no logging ----
        guard thread_suspend(port) == KERN_SUCCESS else {
            store(Report(reason: reason, capturedAt: Date(), frames: [],
                         failure: "thread_suspend failed"))
            return
        }
        let count = unwind(port: port, into: frameBuffer, capacity: maxFrames)
        thread_resume(port)
        // ---- end suspend window ----

        guard count > 0 else {
            store(Report(reason: reason, capturedAt: Date(), frames: [],
                         failure: "could not read thread state"))
            return
        }

        var frames: [String] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            frames.append(symbolicate(frameBuffer[index], index: index))
        }
        store(Report(reason: reason, capturedAt: Date(), frames: frames, failure: nil))
    }

    /// The most recent capture, if it is recent enough to describe the stall being dumped.
    static func latestReport(maxAge: TimeInterval = defaultMaxAge) -> Report? {
        lock.lock()
        defer { lock.unlock() }
        guard let latest, Date().timeIntervalSince(latest.capturedAt) <= maxAge else { return nil }
        return latest
    }

    private static func store(_ report: Report) {
        lock.lock()
        latest = report
        lock.unlock()
    }

    // MARK: - Unwind

    /// Frame-pointer walk. Returns the number of addresses written into `buffer`.
    ///
    /// Both ABIs keep the caller's frame pointer at `[fp]` and the return address at `[fp+8]`,
    /// so one loop covers arm64 and x86_64 once the initial pc/fp come from the right register set.
    private static func unwind(
        port: mach_port_t,
        into buffer: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Int {
        var pc: UInt64 = 0
        var fp: UInt64 = 0

        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let ok = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(port, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        } == KERN_SUCCESS
        guard ok else { return 0 }
        // PAC signs the pointers held in these registers; the top bits are a signature, not
        // address. Stripping them is what makes `dladdr` resolve rather than return nothing.
        pc = strip(state.__pc)
        fp = strip(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let ok = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(port, thread_state_flavor_t(x86_THREAD_STATE64), $0, &stateCount)
            }
        } == KERN_SUCCESS
        guard ok else { return 0 }
        pc = state.__rip
        fp = state.__rbp
        #else
        return 0
        #endif

        guard pc != 0 else { return 0 }
        buffer[0] = pc
        var count = 1

        while count < capacity, fp != 0, fp % 8 == 0 {
            var nextFP: UInt64 = 0
            var returnAddress: UInt64 = 0
            guard readMemory(port: port, address: fp, into: &nextFP),
                  readMemory(port: port, address: fp &+ 8, into: &returnAddress) else { break }

            let caller = strip(returnAddress)
            guard caller != 0 else { break }
            buffer[count] = caller
            count += 1

            // The chain must climb. A non-increasing frame pointer means the stack is corrupt or
            // we walked off the top — either way, stop rather than loop.
            guard nextFP > fp else { break }
            fp = nextFP
        }

        return count
    }

    /// `vm_read_overwrite` rather than a raw dereference: an invalid frame pointer must give a
    /// failed read, not a fault inside the watchdog while the main thread is suspended.
    private static func readMemory(port: mach_port_t, address: UInt64, into out: inout UInt64) -> Bool {
        var outSize: mach_vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &out) { destination -> kern_return_t in
            mach_vm_read_overwrite(
                mach_task_self_,
                mach_vm_address_t(address),
                mach_vm_size_t(MemoryLayout<UInt64>.size),
                mach_vm_address_t(UInt(bitPattern: destination)),
                &outSize
            )
        }
        return result == KERN_SUCCESS && outSize == mach_vm_size_t(MemoryLayout<UInt64>.size)
    }

    /// Clears the pointer-authentication signature from the high bits of an arm64 code pointer.
    private static func strip(_ pointer: UInt64) -> UInt64 {
        #if arch(arm64)
        return pointer & 0x0000_FFFF_FFFF_FFFF
        #else
        return pointer
        #endif
    }

    // MARK: - Symbolication

    /// Crash-report-shaped line: `index  image  0xaddress  symbol + offset`.
    private static func symbolicate(_ address: UInt64, index: Int) -> String {
        var info = Dl_info()
        let indexField = String(index).padding(toLength: 3, withPad: " ", startingAt: 0)
        let addressField = String(format: "0x%016llx", address)

        guard dladdr(UnsafeRawPointer(bitPattern: UInt(address)), &info) != 0 else {
            return "\(indexField) ???                          \(addressField)"
        }

        let image = info.dli_fname.map {
            (String(cString: $0) as NSString).lastPathComponent
        } ?? "???"
        let imageField = image.padding(toLength: 28, withPad: " ", startingAt: 0)

        guard let namePtr = info.dli_sname else {
            return "\(indexField) \(imageField) \(addressField)"
        }
        let raw = String(cString: namePtr)
        let symbol = demangle(raw)
        let offset = address &- UInt64(UInt(bitPattern: info.dli_saddr))
        return "\(indexField) \(imageField) \(addressField) \(symbol) + \(offset)"
    }

    /// Swift symbols come back mangled from `dladdr`. `swift_demangle` is a stdlib entry point
    /// with no header, so it is resolved by name — absent it, the mangled form is still readable
    /// enough to identify the frame.
    private static func demangle(_ mangled: String) -> String {
        guard mangled.hasPrefix("$s") || mangled.hasPrefix("_$s") else { return mangled }
        guard let demangler = swiftDemangle else { return mangled }
        guard let result = mangled.withCString({ demangler($0, strlen($0), nil, nil, 0) }) else {
            return mangled
        }
        defer { free(result) }
        return String(cString: result)
    }

    private typealias SwiftDemangle = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    private static let swiftDemangle: SwiftDemangle? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "swift_demangle") else { return nil }
        return unsafeBitCast(symbol, to: SwiftDemangle.self)
    }()
}
