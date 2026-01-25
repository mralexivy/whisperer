//
//  GlobalKeyListener.swift
//  Whisperer
//
//  Multi-layer global Fn key detection
//

import Cocoa
import IOKit.hid

class GlobalKeyListener {
    var onFnPressed: (() -> Void)?
    var onFnReleased: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var nsEventMonitor: Any?

    private var isFnCurrentlyHeld = false
    private let debounceInterval: TimeInterval = 0.05
    private var lastStateChange = Date()

    // MARK: - Start/Stop

    func start() {
        // Layer 1: CGEventTap (primary)
        setupEventTap()

        // Layer 2: IOKit HID (backup)
        setupHIDManager()

        // Layer 3: NSEvent monitor (supplement)
        setupNSEventMonitor()

        print("GlobalKeyListener started with 3-layer Fn detection")
    }

    func stop() {
        // Stop event tap
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        // Stop HID manager
        if let hidManager = hidManager {
            IOHIDManagerClose(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
        }

        // Stop NSEvent monitor
        if let monitor = nsEventMonitor {
            NSEvent.removeMonitor(monitor)
        }

        print("GlobalKeyListener stopped")
    }

    // MARK: - Layer 1: CGEventTap

    private func setupEventTap() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let listener = Unmanaged<GlobalKeyListener>.fromOpaque(refcon!).takeUnretainedValue() as GlobalKeyListener? else {
                    return Unmanaged.passRetained(event)
                }

                listener.handleCGEvent(event)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap - accessibility permission may be needed")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("Event tap enabled")
        }
    }

    private func handleCGEvent(_ event: CGEvent) {
        let flags = event.flags

        // Check for Fn key (maskSecondaryFn = 0x800000)
        let fnPressed = flags.contains(.maskSecondaryFn)

        updateFnState(fnPressed)
    }

    // MARK: - Layer 2: IOKit HID

    private func setupHIDManager() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let hidManager = hidManager else {
            print("Failed to create HID manager")
            return
        }

        // Match keyboard devices
        let deviceMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard
        ]

        IOHIDManagerSetDeviceMatching(hidManager, deviceMatch as CFDictionary)

        // Register input callback
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterInputValueCallback(hidManager, { context, result, sender, value in
            guard let listener = Unmanaged<GlobalKeyListener>.fromOpaque(context!).takeUnretainedValue() as GlobalKeyListener? else {
                return
            }

            listener.handleHIDInput(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue as CFString)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        print("HID manager enabled")
    }

    private func handleHIDInput(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        // Fn key detection (varies by keyboard)
        // Common patterns: usage page 0xFF00 or usage 0x00FF
        if usagePage == 0xFF || usage == 0xFF || usage == 0x00 {
            let fnPressed = intValue != 0
            updateFnState(fnPressed)
        }
    }

    // MARK: - Layer 3: NSEvent Monitor

    private func setupNSEventMonitor() {
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnPressed = event.modifierFlags.contains(.function)
            self?.updateFnState(fnPressed)
        }

        print("NSEvent monitor enabled")
    }

    // MARK: - State Management

    private func updateFnState(_ pressed: Bool) {
        // Debounce rapid state changes
        let now = Date()
        guard now.timeIntervalSince(lastStateChange) > debounceInterval else {
            return
        }

        // Only fire callbacks on state change
        if pressed != isFnCurrentlyHeld {
            isFnCurrentlyHeld = pressed
            lastStateChange = now

            if pressed {
                print("Fn key PRESSED")
                onFnPressed?()
            } else {
                print("Fn key RELEASED")
                onFnReleased?()
            }
        }
    }

    deinit {
        stop()
    }
}
