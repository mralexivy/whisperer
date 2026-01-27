//
//  GlobalKeyListener.swift
//  Whisperer
//
//  Multi-layer global keyboard shortcut detection with configurable shortcuts
//

import Cocoa
import IOKit.hid

class GlobalKeyListener {
    // Callbacks
    var onShortcutPressed: (() -> Void)?
    var onShortcutReleased: (() -> Void)?

    // Permission status - true if event tap was successfully created
    private(set) var hasInputMonitoringPermission: Bool = false

    // Legacy callbacks (for backwards compatibility)
    var onFnPressed: (() -> Void)? {
        get { onShortcutPressed }
        set { onShortcutPressed = newValue }
    }
    var onFnReleased: (() -> Void)? {
        get { onShortcutReleased }
        set { onShortcutReleased = newValue }
    }

    // Configuration
    var shortcutConfig: ShortcutConfig = .load() {
        didSet {
            shortcutConfig.save()
            print("Shortcut config updated: \(shortcutConfig.displayString)")
        }
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var nsEventMonitor: Any?
    private var keyDownMonitor: Any?

    // State tracking
    private var isShortcutActive = false
    private var isFnCurrentlyHeld = false
    private var currentModifiers: NSEvent.ModifierFlags = []
    private var currentKeyCode: UInt16 = 0
    private var isKeyDown = false

    private let debounceInterval: TimeInterval = 0.02  // 20ms for instant response
    private var lastStateChange = Date()

    // For toggle mode
    private var isRecordingToggled = false

    // Serial queue for thread-safe state updates (prevents race conditions between input layers)
    private let stateQueue = DispatchQueue(label: "whisperer.keylistener.state")

    // MARK: - Fn Calibration (cookie-based detection)

    // Learned Fn element identification for reliable detection
    private var fnElementCookie: IOHIDElementCookie?
    private var fnDeviceIdentifier: String?  // "vendorID:productID:locationID"

    // Calibration state
    private(set) var isCalibrating = false
    var onFnCalibrationComplete: ((Bool) -> Void)?

    // Whether Fn calibration exists
    var isFnCalibrated: Bool {
        return fnElementCookie != nil && fnDeviceIdentifier != nil
    }

    // MARK: - Start/Stop

    func start() {
        // Load any saved Fn calibration
        loadFnCalibration()

        // Layer 1: CGEventTap (primary - for modifiers and keys)
        setupEventTap()

        // Layer 2: IOKit HID (backup for Fn key)
        setupHIDManager()

        // Layer 3: NSEvent monitors (supplement)
        setupNSEventMonitors()

        print("GlobalKeyListener started with shortcut: \(shortcutConfig.displayString)")
        if isFnCalibrated {
            print("✅ Fn calibration loaded (cookie: \(fnElementCookie ?? 0))")
        } else {
            print("⚠️ Fn not calibrated - using fallback detection")
        }
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

        // Stop NSEvent monitors
        if let monitor = nsEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
        }

        print("GlobalKeyListener stopped")
    }

    // MARK: - Layer 1: CGEventTap

    private func setupEventTap() {
        // Listen for both flag changes and key events
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) |
                        (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let listener = Unmanaged<GlobalKeyListener>.fromOpaque(refcon!).takeUnretainedValue() as GlobalKeyListener? else {
                    return Unmanaged.passRetained(event)
                }

                listener.handleCGEvent(event, type: type)
                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ Failed to create event tap - Input Monitoring permission required")
            print("   Go to System Settings → Privacy & Security → Input Monitoring")
            hasInputMonitoringPermission = false
            Task { @MainActor in
                PermissionManager.shared.eventTapWorking = false
                PermissionManager.shared.checkInputMonitoringPermission()
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let runLoopSource = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            hasInputMonitoringPermission = true
            print("✅ Event tap enabled - Input Monitoring permission granted")
            Task { @MainActor in
                PermissionManager.shared.eventTapWorking = true
            }
        }
    }

    private func handleCGEvent(_ event: CGEvent, type: CGEventType) {
        let flags = event.flags
        let fnPressed = flags.contains(.maskSecondaryFn)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))

        stateQueue.async { [weak self] in
            guard let self = self else { return }

            // Update modifier state
            self.currentModifiers = modifiers

            switch type {
            case .flagsChanged:
                // Get the keycode even for flagsChanged to detect arrow keys
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                // Arrow keys (123-126) internally set the Fn flag on macOS
                // Ignore Fn flag if this is from an arrow key press
                let isArrowKey = (keyCode >= 123 && keyCode <= 126)

                if !isArrowKey {
                    // Only update Fn state if this isn't an arrow key
                    self.isFnCurrentlyHeld = fnPressed
                }

                // Check if this is a modifier-only shortcut match
                self.checkShortcutStateLocked()

            case .keyDown:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                self.currentKeyCode = keyCode
                self.isKeyDown = true

                // Arrow keys set Fn flag, but we should ignore it
                let isArrowKey = (keyCode >= 123 && keyCode <= 126)
                if isArrowKey {
                    self.isFnCurrentlyHeld = false
                }

                self.checkShortcutStateLocked()

            case .keyUp:
                let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
                if self.currentKeyCode == keyCode {
                    self.isKeyDown = false
                    self.checkShortcutStateLocked()
                }

            default:
                break
            }
        }
    }

    // MARK: - Layer 2: IOKit HID (for Fn key backup)

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

            // Pass the device (sender) along with the value for device identification
            let device = sender.map { Unmanaged<IOHIDDevice>.fromOpaque($0).takeUnretainedValue() }
            listener.handleHIDInput(value, device: device)
        }, context)

        IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue as CFString)
        IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

        print("HID manager enabled")
    }

    private func handleHIDInput(_ value: IOHIDValue, device: IOHIDDevice?) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let cookie = IOHIDElementGetCookie(element)
        let intValue = IOHIDValueGetIntegerValue(value)
        let deviceId = device.flatMap { getDeviceIdentifier($0) }

        // Handle calibration mode
        if isCalibrating {
            // Log ALL HID events during calibration to help diagnose
            print("📊 HID event: usagePage=0x\(String(format: "%02X", usagePage)), usage=0x\(String(format: "%02X", usage)), cookie=\(cookie), value=\(intValue), device=\(deviceId ?? "nil")")

            // During calibration, look for vendor-specific page (0xFF) inputs
            // which typically contain the Fn key
            // But accept ANY usagePage on key press for now (we'll filter later)
            if intValue != 0 && usagePage == 0xFF {
                stateQueue.async { [weak self] in
                    guard let self = self else { return }

                    self.fnElementCookie = cookie
                    self.fnDeviceIdentifier = deviceId
                    self.isCalibrating = false
                    self.saveFnCalibration()

                    print("✅ Fn calibrated: cookie=\(cookie), device=\(deviceId ?? "unknown")")

                    DispatchQueue.main.async {
                        self.onFnCalibrationComplete?(true)
                    }
                }
                return
            }
        }

        // Normal operation: detect Fn key
        stateQueue.async { [weak self] in
            guard let self = self else { return }

            var isFnEvent = false

            if let savedCookie = self.fnElementCookie,
               let savedDeviceId = self.fnDeviceIdentifier {
                // Calibrated mode: only accept exact cookie + device match
                isFnEvent = (cookie == savedCookie && deviceId == savedDeviceId)
            } else {
                // Fallback mode (uncalibrated): restrictive predicate
                // Only accept usagePage 0xFF with specific usages known to be Fn
                // Usage 0x03 is commonly Fn, avoid 0x00 which matches too many things
                isFnEvent = (usagePage == 0xFF && usage == 0x03)
            }

            if isFnEvent {
                self.isFnCurrentlyHeld = intValue != 0
                self.checkShortcutStateLocked()
            }
        }
    }

    private func getDeviceIdentifier(_ device: IOHIDDevice) -> String {
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        return "\(vendorID):\(productID):\(locationID)"
    }

    // MARK: - Layer 3: NSEvent Monitors

    private func setupNSEventMonitors() {
        // Monitor for modifier changes
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let fnHeld = event.modifierFlags.contains(.function)
            let modifiers = event.modifierFlags

            self?.stateQueue.async {
                self?.isFnCurrentlyHeld = fnHeld
                self?.currentModifiers = modifiers
                self?.checkShortcutStateLocked()
            }
        }

        // Monitor for key events (backup)
        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let keyCode = event.keyCode
            let isDown = (event.type == .keyDown)
            let modifiers = event.modifierFlags

            self?.stateQueue.async {
                self?.currentKeyCode = keyCode
                self?.isKeyDown = isDown
                self?.currentModifiers = modifiers
                self?.checkShortcutStateLocked()
            }
        }

        print("NSEvent monitors enabled")
    }

    // MARK: - Shortcut Matching

    /// Must be called from stateQueue
    private func checkShortcutStateLocked() {
        let config = shortcutConfig
        var shortcutMatches = false

        if config.useFnKey && config.keyCode == 0 && config.modifierFlags == 0 {
            // Fn-only mode: Must have Fn pressed AND no other modifiers AND no regular keys pressed
            // This prevents Command+Arrow from triggering (arrow keys set Fn flag internally)
            let hasOtherModifiers = currentModifiers.contains(.command) ||
                                    currentModifiers.contains(.option) ||
                                    currentModifiers.contains(.control) ||
                                    currentModifiers.contains(.shift)

            // Only match if Fn is held alone (no other modifiers, no keys pressed)
            shortcutMatches = isFnCurrentlyHeld && !hasOtherModifiers && !isKeyDown
        } else if config.keyCode != 0 {
            // Key + optional modifiers
            shortcutMatches = isKeyDown &&
                              currentKeyCode == config.keyCode &&
                              config.matches(keyCode: currentKeyCode, modifiers: currentModifiers, isFnPressed: isFnCurrentlyHeld)
        } else {
            // Modifier-only (not Fn)
            shortcutMatches = config.matches(keyCode: 0, modifiers: currentModifiers, isFnPressed: isFnCurrentlyHeld)
        }

        updateShortcutState(shortcutMatches)
    }

    private func updateShortcutState(_ active: Bool) {
        // Debounce rapid state changes
        let now = Date()
        guard now.timeIntervalSince(lastStateChange) > debounceInterval else {
            return
        }

        let config = shortcutConfig

        switch config.recordingMode {
        case .holdToRecord:
            // Hold mode: active while shortcut is held
            if active != isShortcutActive {
                isShortcutActive = active
                lastStateChange = now

                if active {
                    print("Shortcut PRESSED (\(config.displayString))")
                    onShortcutPressed?()
                } else {
                    print("Shortcut RELEASED (\(config.displayString))")
                    onShortcutReleased?()
                }
            }

        case .toggle:
            // Toggle mode: press to start, press again to stop
            if active && !isShortcutActive {
                // Shortcut just pressed
                isShortcutActive = true
                lastStateChange = now

                if isRecordingToggled {
                    // Currently recording, stop
                    print("Shortcut TOGGLE OFF (\(config.displayString))")
                    isRecordingToggled = false
                    onShortcutReleased?()
                } else {
                    // Not recording, start
                    print("Shortcut TOGGLE ON (\(config.displayString))")
                    isRecordingToggled = true
                    onShortcutPressed?()
                }
            } else if !active && isShortcutActive {
                // Shortcut released, just update state
                isShortcutActive = false
            }
        }
    }

    // MARK: - Public API

    /// Reset toggle state (call when recording stops externally)
    func resetToggleState() {
        isRecordingToggled = false
        isShortcutActive = false
    }

    // MARK: - Fn Calibration API

    /// Start Fn key calibration mode
    /// When in this mode, the next Fn key press will be recorded for reliable detection
    func startFnCalibration() {
        print("🔧 Starting Fn calibration - press the Fn key...")
        isCalibrating = true
    }

    /// Cancel Fn key calibration
    func cancelFnCalibration() {
        print("❌ Fn calibration cancelled")
        isCalibrating = false
    }

    /// Clear existing Fn calibration
    func clearFnCalibration() {
        fnElementCookie = nil
        fnDeviceIdentifier = nil
        UserDefaults.standard.removeObject(forKey: "fnElementCookie")
        UserDefaults.standard.removeObject(forKey: "fnDeviceIdentifier")
        print("🗑️ Fn calibration cleared")
    }

    // MARK: - Fn Calibration Persistence

    private func loadFnCalibration() {
        if let cookieValue = UserDefaults.standard.object(forKey: "fnElementCookie") as? UInt32 {
            fnElementCookie = IOHIDElementCookie(cookieValue)
        }
        fnDeviceIdentifier = UserDefaults.standard.string(forKey: "fnDeviceIdentifier")
    }

    private func saveFnCalibration() {
        if let cookie = fnElementCookie {
            UserDefaults.standard.set(UInt32(cookie), forKey: "fnElementCookie")
        }
        if let deviceId = fnDeviceIdentifier {
            UserDefaults.standard.set(deviceId, forKey: "fnDeviceIdentifier")
        }
    }

    deinit {
        stop()
    }
}
