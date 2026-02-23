//
//  GlobalKeyListener.swift
//  Whisperer
//
//  Global keyboard shortcut detection using flagsChanged monitoring and Carbon hotkeys.
//  Does NOT use CGEventTap, IOKit HID, or global keyDown/keyUp monitoring.
//

import Cocoa
import Carbon.HIToolbox

class GlobalKeyListener {
    // Callbacks
    var onShortcutPressed: (() -> Void)?
    var onShortcutReleased: (() -> Void)?

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
            // Re-register Carbon hotkey if shortcut changed
            if oldValue != shortcutConfig {
                unregisterCarbonHotKey()
                registerCarbonHotKeyIfNeeded()
            }
            print("Shortcut config updated: \(shortcutConfig.displayString)")
        }
    }

    // NSEvent monitors for flagsChanged (modifier key detection — NOT keystroke monitoring)
    private var flagsChangedMonitor: Any?
    private var localFlagsChangedMonitor: Any?

    // Carbon hotkey for non-Fn key+modifier shortcuts
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?

    // Polling fallback for Fn release detection (safety net for Globe/Fn key edge cases)
    private var releaseCheckTimer: DispatchSourceTimer?

    // State tracking
    private var isShortcutActive = false
    private var fnDown = false
    private var recordingInProgress = false

    // For toggle mode
    private var isRecordingToggled = false

    private let debounceInterval: TimeInterval = 0.02  // 20ms for instant response
    private var lastStateChange = Date()

    // Serial queue for thread-safe state updates
    private let stateQueue = DispatchQueue(label: "whisperer.keylistener.state")

    // MARK: - Start/Stop

    func start() {
        // Setup flagsChanged monitor for Fn key and modifier-only shortcuts
        setupFlagsChangedMonitor()

        // Setup Carbon hotkey for key+modifier shortcuts (e.g., Cmd+Shift+Space)
        registerCarbonHotKeyIfNeeded()

        print("GlobalKeyListener started with shortcut: \(shortcutConfig.displayString)")
    }

    func stop() {
        fnDown = false
        recordingInProgress = false
        isRecordingToggled = false

        // Stop release check timer
        releaseCheckTimer?.cancel()
        releaseCheckTimer = nil

        // Stop flagsChanged monitors
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
        if let monitor = localFlagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsChangedMonitor = nil
        }

        // Unregister Carbon hotkey
        unregisterCarbonHotKey()

        print("GlobalKeyListener stopped")
    }

    // MARK: - Modifier Flags Monitor (Fn key detection)

    private func setupFlagsChangedMonitor() {
        let config = shortcutConfig

        // Monitor modifier flag changes only — this does NOT monitor keystrokes
        // Global monitor: catches events when OTHER apps are active
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }

            self.stateQueue.async {
                self.handleFlagsChanged(event, config: config)
            }
        }

        // Local monitor: catches events when Whisperer itself is active
        // (e.g., menu bar extra is open, or system Globe/Fn key activated the app)
        // Without this, Fn release is missed when the app is frontmost.
        localFlagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }

            self.stateQueue.async {
                self.handleFlagsChanged(event, config: config)
            }
            return event
        }

        print("FlagsChanged monitors enabled (global + local)")
    }

    private func handleFlagsChanged(_ event: NSEvent, config: ShortcutConfig) {
        // Fn key detection using keyCode 63
        if event.keyCode == 63 {
            handleFnKeyEvent(event, config: config)
            return
        }

        Logger.debug("flagsChanged keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)", subsystem: .keyListener)

        // For modifier-only shortcuts (non-Fn), check if modifiers match
        if !config.useFnKey && config.keyCode == 0 && config.modifierFlags != 0 {
            handleModifierOnlyShortcut(event, config: config)
        }
    }

    private func handleFnKeyEvent(_ event: NSEvent, config: ShortcutConfig) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.function) {
            // Fn key pressed DOWN
            fnDown = true
            Logger.debug("Fn DOWN detected (keyCode 63, flags=\(mods.rawValue))", subsystem: .keyListener)

            // Only handle if Fn is part of the configured shortcut
            guard config.useFnKey else { return }

            // For Fn-only mode (no additional key required)
            if config.keyCode == 0 && config.modifierFlags == 0 {
                handleShortcutActivated(config: config)
            }
        } else {
            // Fn key RELEASED
            Logger.debug("Fn UP detected (keyCode 63, flags=\(mods.rawValue), fnDown=\(fnDown))", subsystem: .keyListener)
            guard fnDown else { return }

            if config.useFnKey && config.keyCode == 0 && config.modifierFlags == 0 {
                handleShortcutDeactivated(config: config)
            }

            fnDown = false
        }
    }

    private func handleModifierOnlyShortcut(_ event: NSEvent, config: ShortcutConfig) {
        let relevantMods: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let currentMods = event.modifierFlags.intersection(relevantMods)
        let requiredMods = NSEvent.ModifierFlags(rawValue: config.modifierFlags).intersection(relevantMods)

        if currentMods == requiredMods && !requiredMods.isEmpty {
            handleShortcutActivated(config: config)
        } else if isShortcutActive {
            handleShortcutDeactivated(config: config)
        }
    }

    // MARK: - Shortcut State Management

    private func handleShortcutActivated(config: ShortcutConfig) {
        let now = Date()
        guard now.timeIntervalSince(lastStateChange) > debounceInterval else { return }

        switch config.recordingMode {
        case .holdToRecord:
            if !recordingInProgress {
                print("Shortcut PRESSED (\(config.displayString))")
                recordingInProgress = true
                isShortcutActive = true
                lastStateChange = now
                startReleaseCheckTimer(config: config)
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutPressed?()
                }
            }

        case .toggle:
            if !isShortcutActive {
                isShortcutActive = true
                lastStateChange = now

                if isRecordingToggled {
                    print("Shortcut TOGGLE OFF (\(config.displayString))")
                    isRecordingToggled = false
                    recordingInProgress = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onShortcutReleased?()
                    }
                } else {
                    print("Shortcut TOGGLE ON (\(config.displayString))")
                    isRecordingToggled = true
                    recordingInProgress = true
                    DispatchQueue.main.async { [weak self] in
                        self?.onShortcutPressed?()
                    }
                }
            }
        }
    }

    private func handleShortcutDeactivated(config: ShortcutConfig) {
        let now = Date()
        guard now.timeIntervalSince(lastStateChange) > debounceInterval else { return }

        switch config.recordingMode {
        case .holdToRecord:
            if recordingInProgress {
                print("Shortcut RELEASED (\(config.displayString))")
                recordingInProgress = false
                isShortcutActive = false
                lastStateChange = now
                stopReleaseCheckTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutReleased?()
                }
            }

        case .toggle:
            // In toggle mode, releasing the key just updates active state
            isShortcutActive = false
        }
    }

    // MARK: - Polling Fallback

    /// Safety net: periodically checks if Fn is still held during hold-to-record mode.
    /// Catches cases where the Fn release event is consumed by the system (e.g., Globe key
    /// opening emoji picker, input source switch, or macOS dictation).
    private func startReleaseCheckTimer(config: ShortcutConfig) {
        guard config.useFnKey && config.keyCode == 0 && config.recordingMode == .holdToRecord else { return }

        stopReleaseCheckTimer()

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.recordingInProgress else {
                self?.stopReleaseCheckTimer()
                return
            }

            let currentFlags = NSEvent.modifierFlags
            Logger.debug("Polling check: .function=\(currentFlags.contains(.function))", subsystem: .keyListener)
            if !currentFlags.contains(.function) {
                Logger.warning("Fn release detected via polling fallback (event monitors missed it)", subsystem: .keyListener)
                self.handleShortcutDeactivated(config: config)
                self.fnDown = false
            }
        }
        timer.resume()
        releaseCheckTimer = timer
    }

    private func stopReleaseCheckTimer() {
        releaseCheckTimer?.cancel()
        releaseCheckTimer = nil
    }

    // MARK: - Carbon Hot Key (for key+modifier shortcuts)

    private func registerCarbonHotKeyIfNeeded() {
        let config = shortcutConfig

        // Carbon hotkeys are only needed for shortcuts that include a key code
        // Fn-only and modifier-only shortcuts are handled by flagsChanged monitor
        guard config.keyCode != 0 else { return }

        // Convert NSEvent modifier flags to Carbon modifier flags
        var carbonModifiers: UInt32 = 0
        let mods = NSEvent.ModifierFlags(rawValue: config.modifierFlags)
        if mods.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if mods.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if mods.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if mods.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Register the hotkey
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x57485350), // "WHSP"
            id: 1
        )

        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )

        guard status == noErr else {
            print("Failed to register Carbon hotkey: \(status)")
            return
        }

        // Install event handler for pressed/released
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let listener = Unmanaged<GlobalKeyListener>.fromOpaque(userData).takeUnretainedValue()
                listener.handleCarbonHotKeyEvent(event)
                return noErr
            },
            eventSpecs.count,
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &carbonEventHandler
        )

        if handlerResult == noErr {
            print("Carbon hotkey registered: \(config.displayString)")
        } else {
            print("Failed to install Carbon event handler: \(handlerResult)")
        }
    }

    private func handleCarbonHotKeyEvent(_ event: EventRef?) {
        guard let event = event else { return }

        let eventKind = GetEventKind(event)
        let config = shortcutConfig

        stateQueue.async { [weak self] in
            guard let self = self else { return }

            if eventKind == UInt32(kEventHotKeyPressed) {
                self.handleShortcutActivated(config: config)
            } else if eventKind == UInt32(kEventHotKeyReleased) {
                self.handleShortcutDeactivated(config: config)
            }
        }
    }

    private func unregisterCarbonHotKey() {
        if let hotKeyRef = carbonHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            carbonHotKeyRef = nil
        }
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
            carbonEventHandler = nil
        }
    }

    // MARK: - Public API

    /// Reset toggle state (call when recording stops externally)
    func resetToggleState() {
        isRecordingToggled = false
        isShortcutActive = false
    }

    deinit {
        stop()
    }
}
