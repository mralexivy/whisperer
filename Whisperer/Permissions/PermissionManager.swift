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
    case accessibility = "Accessibility"

    var description: String {
        switch self {
        case .microphone:
            return "Record audio from your microphone"
        case .accessibility:
            return "Insert dictated text into apps (assistive input)"
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
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
    @Published var accessibilityStatus: PermissionStatus = .unknown

    private var checkTimer: Timer?

    private init() {
        refreshAllPermissions()
        startPeriodicCheck()
    }

    // MARK: - Permission Checks

    func refreshAllPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
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

    func checkAccessibilityPermission() {
        if AXIsProcessTrusted() {
            accessibilityStatus = .granted
        } else {
            // Can't distinguish between denied and not determined for accessibility
            accessibilityStatus = .denied
        }
    }

    // MARK: - Permission Requests

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                self?.microphoneStatus = granted ? .granted : .denied
            }
        }
    }

    func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            accessibilityStatus = .granted
        } else {
            // The system prompt only appears on the very first call.
            // On subsequent attempts, open System Settings directly.
            openSystemSettings(for: .accessibility)
            accessibilityStatus = .denied
        }
    }

    // MARK: - System Settings

    func openSystemSettings(for permission: PermissionType) {
        if let url = permission.systemSettingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Overall Status

    var allPermissionsGranted: Bool {
        microphoneStatus == .granted &&
        accessibilityStatus == .granted
    }

    var criticalPermissionsMissing: Bool {
        // Microphone is critical for basic function
        // Accessibility is optional (clipboard fallback exists)
        microphoneStatus == .denied
    }

    func status(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .microphone: return microphoneStatus
        case .accessibility: return accessibilityStatus
        }
    }

    // MARK: - Periodic Check

    private func startPeriodicCheck() {
        // Check permissions every 2 seconds (user might grant them in System Settings)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    deinit {
        checkTimer?.invalidate()
    }
}
