//
//  AudioStartupGate.swift
//  Whisperer
//
//  Prevents CoreAudio initialization during SwiftUI's AttributeGraph processing
//

import Foundation

actor AudioStartupGate {
    static let shared = AudioStartupGate()

    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Park the caller until the gate opens. Returns immediately if already open.
    func waitForReady() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Open the gate and resume all parked callers.
    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    /// Schedule the gate to open after 2 main-thread runloop yields,
    /// guaranteeing SwiftUI's AttributeGraph metadata processing has settled.
    /// A 3-second safety timeout forces the gate open if yields don't complete.
    nonisolated func scheduleOpen() {
        // Safety timeout: force open after 3 seconds regardless
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await open()
        }

        // Primary path: 2 runloop yields ensure AttributeGraph has settled
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                Task {
                    await self.open()
                }
            }
        }
    }
}
