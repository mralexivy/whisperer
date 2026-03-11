//
//  PermissionManager.swift
//  Whisperer
//
//  Centralized permission management for all required permissions
//

import Cocoa
import AVFoundation
import ApplicationServices
import Combine

enum PermissionType: String, CaseIterable {
    case microphone = "Microphone"
    #if !APP_STORE
    case accessibility = "Accessibility"
    #endif

    var description: String {
        switch self {
        case .microphone:
            return "Record audio from your microphone"
        #if !APP_STORE
        case .accessibility:
            return "Auto-paste — enter text wherever you type"
        #endif
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #if !APP_STORE
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #endif
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        #if !APP_STORE
        case .accessibility: return "accessibility"
        #endif
        }
    }
}

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown

    var displayText: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .unknown: return "Unknown"
        }
    }

    var color: NSColor {
        switch self {
        case .granted: return .systemGreen
        case .denied: return .systemRed
        case .notDetermined: return .systemOrange
        case .unknown: return .systemGray
        }
    }
}

@MainActor
class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    @Published var microphoneStatus: PermissionStatus = .unknown
    #if !APP_STORE
    @Published var accessibilityStatus: PermissionStatus = .notDetermined
    #endif

    private var checkTimer: Timer?
    #if !APP_STORE
    private var isAccessibilityTrackingEnabled = false
    #endif

    private init() {
        checkMicrophonePermission()
        startPeriodicCheck()
    }

    // MARK: - Permission Checks

    func refreshAllPermissions() {
        checkMicrophonePermission()
        #if !APP_STORE
        if isAccessibilityTrackingEnabled {
            checkAccessibilityPermission()
        }
        #endif
    }

    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .notDetermined
        @unknown default:
            microphoneStatus = .unknown
        }
    }

    #if !APP_STORE
    func checkAccessibilityPermission() {
        guard isAccessibilityTrackingEnabled else { return }
        if AXIsProcessTrusted() {
            accessibilityStatus = .granted
        } else {
            accessibilityStatus = .denied
        }
    }

    // MARK: - Accessibility Tracking (Lazy)

    /// Start tracking accessibility permission status.
    /// Only call when the user explicitly enables auto-paste.
    func enableAccessibilityTracking() {
        isAccessibilityTrackingEnabled = true
        checkAccessibilityPermission()
    }

    /// Stop tracking accessibility permission and reset status.
    /// Call when the user disables auto-paste.
    func disableAccessibilityTracking() {
        isAccessibilityTrackingEnabled = false
        accessibilityStatus = .notDetermined
    }

    /// Recheck accessibility status if tracking is active.
    /// Called from event-based hooks (app activation, menu bar open, before recording).
    func recheckAccessibilityIfNeeded() {
        guard isAccessibilityTrackingEnabled else { return }
        checkAccessibilityPermission()
    }
    #endif

    // MARK: - Permission Requests

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                self?.microphoneStatus = granted ? .granted : .denied
            }
        }
    }

    #if !APP_STORE
    func requestAccessibilityPermission() {
        // Enable tracking so periodic/event-based checks detect the grant
        isAccessibilityTrackingEnabled = true

        // AXIsProcessTrustedWithOptions with prompt: shows system alert on first call,
        // which directs user to System Settings → Accessibility
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            accessibilityStatus = .granted
            return
        }

        accessibilityStatus = .denied

        // Wait for the system prompt to appear, then check again.
        // If still not granted, open System Settings as fallback
        // (the system prompt only shows on the very first call ever).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if AXIsProcessTrusted() {
                self?.accessibilityStatus = .granted
            } else {
                self?.openSystemSettings(for: .accessibility)
            }
        }
    }
    #endif

    // MARK: - System Settings

    func openSystemSettings(for permission: PermissionType) {
        if let url = permission.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Overall Status

    var allPermissionsGranted: Bool {
        guard microphoneStatus == .granted else { return false }
        #if !APP_STORE
        if isAccessibilityTrackingEnabled {
            return accessibilityStatus == .granted
        }
        #endif
        return true
    }

    /// Permissions required for the current mode.
    /// Microphone is always required. Accessibility is only required
    /// when auto-paste is enabled (non-App Store builds only).
    var requiredPermissionsGranted: Bool {
        guard microphoneStatus == .granted else { return false }
        #if !APP_STORE
        if isAccessibilityTrackingEnabled {
            return accessibilityStatus == .granted
        }
        #endif
        return true
    }

    var criticalPermissionsMissing: Bool {
        // Microphone is critical for basic function
        // Accessibility is optional (clipboard fallback exists)
        microphoneStatus == .denied
    }

    func status(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .microphone: return microphoneStatus
        #if !APP_STORE
        case .accessibility: return accessibilityStatus
        #endif
        }
    }

    // MARK: - Periodic Check

    private func startPeriodicCheck() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.checkMicrophonePermission()
                #if !APP_STORE
                // Check accessibility if tracking is active (user may grant in System Settings)
                self?.recheckAccessibilityIfNeeded()
                #endif
            }
        }
    }

    deinit {
        checkTimer?.invalidate()
    }
}
