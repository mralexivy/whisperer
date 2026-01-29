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
    case inputMonitoring = "Input Monitoring"

    var description: String {
        switch self {
        case .microphone:
            return "Record audio from your microphone"
        case .accessibility:
            return "Insert transcribed text into apps"
        case .inputMonitoring:
            return "Detect keyboard shortcuts globally"
        }
    }

    var systemSettingsURL: URL? {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .inputMonitoring: return "keyboard"
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
    @Published var inputMonitoringStatus: PermissionStatus = .unknown

    // Track if event tap was successfully created (indicates input monitoring works)
    @Published var eventTapWorking: Bool = false

    private var checkTimer: Timer?

    private init() {
        refreshAllPermissions()
        startPeriodicCheck()
    }

    // MARK: - Permission Checks

    func refreshAllPermissions() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        checkInputMonitoringPermission()
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

    func checkInputMonitoringPermission() {
        // Input monitoring is checked by trying to create an event tap
        // If eventTapWorking is set by GlobalKeyListener, use that
        // Otherwise, try to create a test tap

        if eventTapWorking {
            inputMonitoringStatus = .granted
            return
        }

        // Try to create a minimal event tap to test permission
        let testEventMask = (1 << CGEventType.flagsChanged.rawValue)

        if let testTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(testEventMask),
            callback: { _, _, event, _ in
                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        ) {
            // Successfully created, permission granted
            CFMachPortInvalidate(testTap)
            inputMonitoringStatus = .granted
            eventTapWorking = true
        } else {
            inputMonitoringStatus = .denied
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
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityStatus = trusted ? .granted : .denied
    }

    func requestInputMonitoringPermission() {
        // Input monitoring permission is triggered automatically when we try to create an event tap
        // Just open System Settings for the user
        openSystemSettings(for: .inputMonitoring)
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
        accessibilityStatus == .granted &&
        inputMonitoringStatus == .granted
    }

    var criticalPermissionsMissing: Bool {
        // Microphone and input monitoring are critical for basic function
        microphoneStatus == .denied || inputMonitoringStatus == .denied
    }

    func status(for type: PermissionType) -> PermissionStatus {
        switch type {
        case .microphone: return microphoneStatus
        case .accessibility: return accessibilityStatus
        case .inputMonitoring: return inputMonitoringStatus
        }
    }

    // MARK: - Periodic Check

    private func startPeriodicCheck() {
        // Check permissions every 2 seconds (user might grant them in System Settings)
        checkTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    deinit {
        checkTimer?.invalidate()
    }
}
