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
    // Recording callbacks
    var onShortcutPressed: (() -> Void)?
    var onShortcutReleased: (() -> Void)?
    var onShortcutCancelled: (() -> Void)?
    var onHandsFreeActivated: (() -> Void)?

    // Rewrite mode callbacks
    var onRewriteShortcutPressed: (() -> Void)?
    var onRewriteShortcutReleased: (() -> Void)?

    // Picker callbacks (Option+V transcription picker)
    var onPickerActivated: (() -> Void)?
    var onPickerCycled: (() -> Void)?
    var onPickerConfirmed: (() -> Void)?
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
            Logger.info("Shortcut config updated: \(shortcutConfig.displayString)", subsystem: .keyListener)
        }
    }

    // NSEvent monitors for flagsChanged (modifier key detection — NOT keystroke monitoring)
    private var flagsChangedMonitor: Any?
    private var localFlagsChangedMonitor: Any?

    // Carbon hotkey for non-Fn key+modifier shortcuts
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?

    // Carbon hotkey for picker (Option+V)
    private var pickerHotKeyRef: EventHotKeyRef?
    private var pickerEventHandler: EventHandlerRef?

    // Carbon hotkey for rewrite mode
    private var rewriteHotKeyRef: EventHotKeyRef?
    private var rewriteEventHandler: EventHandlerRef?
    private var rewriteRecordingInProgress = false

    // Polling fallback for Fn release detection (safety net for Globe/Fn key edge cases)
    private var releaseCheckTimer: DispatchSourceTimer?

    // State tracking
    private var isShortcutActive = false
    private var fnDown = false
    private var recordingInProgress = false
    private var pickerVisible = false

    // For toggle mode
    private var isRecordingToggled = false

    // Fn+H hands-free mode (within holdToRecord)
    // While holding Fn, press H → hands-free activates, release Fn → recording continues
    // Press Fn again → stops recording
    private var isHandsFreeMode = false
    private let handsFreeKeyCode: CGKeyCode = 4  // H key

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

        // Setup Carbon hotkey for transcription picker (Option+V)
        registerPickerHotKey()

        // Setup Carbon hotkey for rewrite mode
        registerRewriteHotKeyIfNeeded()

        Logger.info("GlobalKeyListener started with shortcut: \(shortcutConfig.displayString)", subsystem: .keyListener)
    }

    func stop() {
        fnDown = false
        recordingInProgress = false
        isRecordingToggled = false
        isHandsFreeMode = false

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

        // Unregister Carbon hotkeys
        unregisterCarbonHotKey()
        unregisterPickerHotKey()
        unregisterRewriteHotKey()
        pickerVisible = false
        rewriteRecordingInProgress = false

        Logger.info("GlobalKeyListener stopped", subsystem: .keyListener)
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

        Logger.info("FlagsChanged monitors enabled (global + local)", subsystem: .keyListener)
    }

    private func handleFlagsChanged(_ event: NSEvent, config: ShortcutConfig) {
        // Picker: detect Option release while picker is visible
        if pickerVisible {
            let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !currentMods.contains(.option) {
                Logger.info("Option released — confirming picker selection", subsystem: .keyListener)
                pickerVisible = false
                DispatchQueue.main.async { [weak self] in
                    self?.onPickerConfirmed?()
                }
                return
            }
        }

        // Fn key detection using keyCode 63
        if event.keyCode == 63 {
            handleFnKeyEvent(event, config: config)
            return
        }

        Logger.debug("flagsChanged keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)", subsystem: .keyListener)

        // Fn+key combo: another modifier pressed while Fn is held during recording.
        // Cancel recording entirely — don't process audio.
        if fnDown && recordingInProgress && config.useFnKey && config.keyCode == 0 && config.modifierFlags == 0 {
            handleShortcutCancelled(config: config, reason: "Fn+modifier keyCode=\(event.keyCode)")
            return
        }

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
        let elapsed = now.timeIntervalSince(lastStateChange)
        guard elapsed > debounceInterval else {
            Logger.info("Shortcut PRESS debounced (\(String(format: "%.0f", elapsed * 1000))ms < \(String(format: "%.0f", debounceInterval * 1000))ms, recording=\(recordingInProgress))", subsystem: .keyListener)
            return
        }

        switch config.recordingMode {
        case .holdToRecord:
            if isHandsFreeMode && recordingInProgress {
                // Fn press during hands-free — stop recording
                Logger.info("Shortcut PRESSED in hands-free — stopping (\(config.displayString))", subsystem: .keyListener)
                isHandsFreeMode = false
                recordingInProgress = false
                isShortcutActive = false
                lastStateChange = now
                stopReleaseCheckTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutReleased?()
                }
            } else if !recordingInProgress {
                // Normal press — start recording
                Logger.info("Shortcut PRESSED (\(config.displayString))", subsystem: .keyListener)
                recordingInProgress = true
                isShortcutActive = true
                lastStateChange = now
                startReleaseCheckTimer(config: config)
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutPressed?()
                }
            } else {
                Logger.info("Shortcut PRESS ignored — already recording (fnDown=\(fnDown), active=\(isShortcutActive))", subsystem: .keyListener)
            }

        case .toggle:
            if !isShortcutActive {
                isShortcutActive = true
                lastStateChange = now

                if isRecordingToggled {
                    Logger.info("Shortcut TOGGLE OFF (\(config.displayString))", subsystem: .keyListener)
                    isRecordingToggled = false
                    recordingInProgress = false
                    DispatchQueue.main.async { [weak self] in
                        self?.onShortcutReleased?()
                    }
                } else {
                    Logger.info("Shortcut TOGGLE ON (\(config.displayString))", subsystem: .keyListener)
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

        // In hold-to-record mode, NEVER debounce the release — dropping a release
        // leaves recordingInProgress stuck true (state machine breaks).
        // Debounce only applies to toggle mode where spurious releases are harmless.
        if config.recordingMode == .toggle {
            let elapsed = now.timeIntervalSince(lastStateChange)
            guard elapsed > debounceInterval else {
                Logger.info("Shortcut RELEASE debounced in toggle mode (\(String(format: "%.0f", elapsed * 1000))ms)", subsystem: .keyListener)
                return
            }
        }

        switch config.recordingMode {
        case .holdToRecord:
            if isHandsFreeMode {
                // In hands-free mode, ignore Fn release (stop happens on next press)
                isShortcutActive = false
                Logger.debug("Shortcut RELEASE ignored — hands-free mode active", subsystem: .keyListener)
            } else if recordingInProgress {
                // Normal hold release — stop recording
                Logger.info("Shortcut RELEASED (\(config.displayString))", subsystem: .keyListener)
                recordingInProgress = false
                isShortcutActive = false
                lastStateChange = now
                stopReleaseCheckTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onShortcutReleased?()
                }
            } else {
                Logger.info("Shortcut RELEASE ignored — not recording (fnDown=\(fnDown), active=\(isShortcutActive))", subsystem: .keyListener)
            }

        case .toggle:
            // In toggle mode, releasing the key just updates active state
            isShortcutActive = false
        }
    }

    /// Cancels the shortcut activation due to Fn+key combo detection.
    /// Unlike deactivation (normal release), cancellation discards the recording.
    private func handleShortcutCancelled(config: ShortcutConfig, reason: String) {
        guard recordingInProgress else { return }

        Logger.info("Shortcut CANCELLED (\(config.displayString)) — \(reason)", subsystem: .keyListener)
        recordingInProgress = false
        isShortcutActive = false
        isRecordingToggled = false
        isHandsFreeMode = false
        lastStateChange = Date()
        stopReleaseCheckTimer()
        DispatchQueue.main.async { [weak self] in
            self?.onShortcutCancelled?()
        }
    }

    // MARK: - Polling Fallback

    /// Polls key state to detect Fn release or Fn+key combos during hold-to-record mode.
    /// Catches: (1) Fn release consumed by the system (Globe key, emoji picker, dictation),
    /// (2) any key pressed while Fn is held (volume, brightness, F-keys, letter keys, etc.).
    /// Uses CGEventSource.keyState to query the system key state table — this is a passive
    /// state query, NOT event monitoring or interception.
    private func startReleaseCheckTimer(config: ShortcutConfig) {
        guard config.useFnKey && config.keyCode == 0 && config.recordingMode == .holdToRecord else { return }

        stopReleaseCheckTimer()

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.recordingInProgress else {
                self?.stopReleaseCheckTimer()
                return
            }

            // Check 1: Fn key released (event monitors may have missed it)
            // Skip in hands-free mode — release is expected and should be ignored
            let currentFlags = NSEvent.modifierFlags
            if !self.isHandsFreeMode && !currentFlags.contains(.function) {
                Logger.info("Fn release detected via polling", subsystem: .keyListener)
                self.handleShortcutDeactivated(config: config)
                self.fnDown = false
                return
            }

            // Check 2: H key pressed while Fn is held → activate hands-free
            if !self.isHandsFreeMode && self.isHandsFreeKeyPressed() {
                Logger.info("Fn+H detected — HANDS-FREE mode activated", subsystem: .keyListener)
                self.isHandsFreeMode = true
                DispatchQueue.main.async { [weak self] in
                    self?.onHandsFreeActivated?()
                }
                return
            }

            // Check 3 & 4: Only cancel on key/modifier combos when NOT in hands-free mode
            // In hands-free mode, user has released Fn and can type freely — only Fn press stops recording
            if !self.isHandsFreeMode {
                // Check 3: Any non-modifier key (except H) pressed while Fn is held → Fn+key combo
                if self.isAnyNonModifierKeyPressed() {
                    self.handleShortcutCancelled(config: config, reason: "Fn+key via key state polling")
                    return
                }

                // Check 4: Modifier key added while Fn is held (Fn+Cmd, Fn+Shift, etc.)
                let extraModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
                if !currentFlags.intersection(extraModifiers).isEmpty {
                    self.handleShortcutCancelled(config: config, reason: "Fn+modifier via polling")
                }
            }
        }
        timer.resume()
        releaseCheckTimer = timer
    }

    /// Checks if H key is currently pressed (for Fn+H hands-free activation).
    private func isHandsFreeKeyPressed() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: handsFreeKeyCode)
    }

    /// Checks if any non-modifier key (except H) is currently pressed.
    /// Uses CGEventSource.keyState which queries the system key state table —
    /// a passive read, not event monitoring or interception.
    private func isAnyNonModifierKeyPressed() -> Bool {
        let modifierKeyCodes: Set<CGKeyCode> = [
            54, 55,  // Right/Left Command
            56, 60,  // Left/Right Shift
            58, 61,  // Left/Right Option
            59, 62,  // Left/Right Control
            63,      // Fn/Globe
            57,      // Caps Lock
        ]

        for keyCode: CGKeyCode in 0..<128 {
            guard !modifierKeyCodes.contains(keyCode) else { continue }
            guard keyCode != handsFreeKeyCode else { continue }  // H handled separately
            if CGEventSource.keyState(.combinedSessionState, key: keyCode) {
                return true
            }
        }
        return false
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
            Logger.error("Failed to register Carbon hotkey: \(status)", subsystem: .keyListener)
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
            Logger.info("Carbon hotkey registered: \(config.displayString)", subsystem: .keyListener)
        } else {
            Logger.error("Failed to install Carbon event handler: \(handlerResult)", subsystem: .keyListener)
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

    // MARK: - Picker Hot Key (Option+V for transcription picker)

    private func registerPickerHotKey() {
        // Skip if user's recording shortcut is also Option+V
        let config = shortcutConfig
        let recordingUsesOptionV = config.keyCode == 9 &&
            NSEvent.ModifierFlags(rawValue: config.modifierFlags).contains(.option)
        guard !recordingUsesOptionV else {
            Logger.warning("Option+V conflicts with recording shortcut — picker hotkey not registered", subsystem: .keyListener)
            return
        }

        // Register Option+V (V keyCode = 0x09 = 9)
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x57485350), // "WHSP"
            id: 2
        )

        let status = RegisterEventHotKey(
            UInt32(9),                // V key
            UInt32(optionKey),        // Option modifier
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &pickerHotKeyRef
        )

        guard status == noErr else {
            Logger.error("Failed to register picker hotkey (Option+V): \(status)", subsystem: .keyListener)
            return
        }

        // Install dedicated event handler for picker
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let listener = Unmanaged<GlobalKeyListener>.fromOpaque(userData).takeUnretainedValue()
                listener.handlePickerHotKeyEvent(event)
                return noErr
            },
            eventSpecs.count,
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &pickerEventHandler
        )

        if handlerResult == noErr {
            Logger.info("Picker hotkey registered (Option+V)", subsystem: .keyListener)
        } else {
            Logger.error("Failed to install picker event handler: \(handlerResult)", subsystem: .keyListener)
        }
    }

    private func handlePickerHotKeyEvent(_ event: EventRef?) {
        guard let event = event else { return }

        let eventKind = GetEventKind(event)

        stateQueue.async { [weak self] in
            guard let self = self else { return }

            // Only handle key pressed (V down while Option held)
            guard eventKind == UInt32(kEventHotKeyPressed) else { return }

            // Don't open picker during recording
            guard !self.recordingInProgress else { return }

            if !self.pickerVisible {
                // First press: show picker
                Logger.info("Picker activated (Option+V)", subsystem: .keyListener)
                self.pickerVisible = true
                DispatchQueue.main.async { [weak self] in
                    self?.onPickerActivated?()
                }
            } else {
                // Subsequent presses: cycle to next item
                Logger.debug("Picker cycled (Option+V)", subsystem: .keyListener)
                DispatchQueue.main.async { [weak self] in
                    self?.onPickerCycled?()
                }
            }
        }
    }

    private func unregisterPickerHotKey() {
        if let hotKeyRef = pickerHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            pickerHotKeyRef = nil
        }
        if let handler = pickerEventHandler {
            RemoveEventHandler(handler)
            pickerEventHandler = nil
        }
    }

    // MARK: - Rewrite Hot Key

    var rewriteShortcutConfig: RewriteShortcutConfig = .load() {
        didSet {
            rewriteShortcutConfig.save()
            unregisterRewriteHotKey()
            registerRewriteHotKeyIfNeeded()
        }
    }

    private func registerRewriteHotKeyIfNeeded() {
        let config = rewriteShortcutConfig
        guard config.isEnabled, config.keyCode != 0 else { return }

        var carbonModifiers: UInt32 = 0
        let mods = config.modifiers
        if mods.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if mods.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if mods.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if mods.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        let hotKeyID = EventHotKeyID(
            signature: OSType(0x57485350), // "WHSP"
            id: 3
        )

        let status = RegisterEventHotKey(
            UInt32(config.keyCode),
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &rewriteHotKeyRef
        )

        guard status == noErr else {
            Logger.error("Failed to register rewrite hotkey: \(status)", subsystem: .keyListener)
            return
        }

        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handlerResult = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let listener = Unmanaged<GlobalKeyListener>.fromOpaque(userData).takeUnretainedValue()
                listener.handleRewriteHotKeyEvent(event)
                return noErr
            },
            eventSpecs.count,
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &rewriteEventHandler
        )

        if handlerResult == noErr {
            Logger.info("Rewrite hotkey registered: \(config.displayString)", subsystem: .keyListener)
        } else {
            Logger.error("Failed to install rewrite event handler: \(handlerResult)", subsystem: .keyListener)
        }
    }

    private func handleRewriteHotKeyEvent(_ event: EventRef?) {
        guard let event = event else { return }
        let eventKind = GetEventKind(event)

        stateQueue.async { [weak self] in
            guard let self = self else { return }

            if eventKind == UInt32(kEventHotKeyPressed) {
                guard !self.recordingInProgress, !self.rewriteRecordingInProgress else { return }
                self.rewriteRecordingInProgress = true
                Logger.info("Rewrite shortcut PRESSED", subsystem: .keyListener)
                DispatchQueue.main.async { [weak self] in
                    self?.onRewriteShortcutPressed?()
                }
            } else if eventKind == UInt32(kEventHotKeyReleased) {
                guard self.rewriteRecordingInProgress else { return }
                self.rewriteRecordingInProgress = false
                Logger.info("Rewrite shortcut RELEASED", subsystem: .keyListener)
                DispatchQueue.main.async { [weak self] in
                    self?.onRewriteShortcutReleased?()
                }
            }
        }
    }

    private func unregisterRewriteHotKey() {
        if let hotKeyRef = rewriteHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            rewriteHotKeyRef = nil
        }
        if let handler = rewriteEventHandler {
            RemoveEventHandler(handler)
            rewriteEventHandler = nil
        }
    }

    // MARK: - Public API

    /// Reset toggle state (call when recording stops externally)
    func resetToggleState() {
        isRecordingToggled = false
        isShortcutActive = false
        isHandsFreeMode = false
        recordingInProgress = false
    }

    deinit {
        stop()
    }
}
