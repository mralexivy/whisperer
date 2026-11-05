//
//  StalePermissionRepair.swift
//  Whisperer
//
//  macOS ties a permission grant to the app's code signature. When a build signed differently
//  replaces the installed one (a dev build over a release, a re-signed copy), System Settings
//  keeps showing the switch ON while macOS no longer trusts the new binary: no prompt, no error,
//  features quietly degrade. Seen 2026-11-05 on a second Mac: Accessibility "on", AXIsProcessTrusted
//  false, browser meeting detection degraded, fixed only by running `tccutil reset` by hand.
//
//  macOS has no API that grants a permission, so one user action is unavoidable. What this removes
//  is the part users cannot do themselves: the stale entry is deleted (tccutil may reset an app's
//  own entries without admin rights) and a fresh request is made, so the user meets the normal
//  system prompt and an OFF switch to flip — instead of an ON switch that does nothing.
//

#if !APP_STORE
import AppKit
import ApplicationServices
import AVFoundation
import Security

@MainActor
enum StalePermissionRepair {

    private static let accessibilityGrantedKey = "permissionRepair.accessibilityWasGranted"
    private static let microphoneGrantedKey = "permissionRepair.microphoneWasGranted"
    private static let repairedBuildKey = "permissionRepair.repairedBuild"

    /// Run once at launch. Remembers what this app has been granted; when a permission it held
    /// is no longer trusted, resets the stale entry and asks again — once per build, so a user
    /// who really did revoke it is asked again only after an update, never in a loop.
    static func check() {
        let defaults = UserDefaults.standard
        let accessibility = AXIsProcessTrusted()
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        if accessibility { defaults.set(true, forKey: accessibilityGrantedKey) }
        if microphone == .authorized { defaults.set(true, forKey: microphoneGrantedKey) }

        // Installs that predate this check never recorded a grant. Finished onboarding with
        // auto-paste on means Accessibility was granted at some point.
        let hadAccessibility = defaults.bool(forKey: accessibilityGrantedKey)
            || (defaults.bool(forKey: "hasCompletedOnboarding") && defaults.bool(forKey: "autoPasteEnabled"))

        var stale: [String] = []
        if !accessibility && hadAccessibility { stale.append("Accessibility") }
        if microphone == .denied && defaults.bool(forKey: microphoneGrantedKey) { stale.append("Microphone") }
        guard !stale.isEmpty else { return }

        let build = codeIdentity()
        guard defaults.string(forKey: repairedBuildKey) != build else {
            Logger.info("Permissions: \(stale.joined(separator: ", ")) still not trusted; already repaired for this build", subsystem: .permissions)
            return
        }
        defaults.set(build, forKey: repairedBuildKey)
        Logger.warning("Permissions: \(stale.joined(separator: ", ")) granted before but not trusted by this build — resetting the stale entries", subsystem: .permissions)

        let bundleID = Bundle.main.bundleIdentifier ?? "com.ivy.whisperer"
        Task.detached {
            for service in stale { resetTCC(service: service, bundleID: bundleID) }
            await MainActor.run {
                if stale.contains("Microphone") { PermissionManager.shared.requestMicrophonePermission() }
                if stale.contains("Accessibility") { PermissionManager.shared.requestAccessibilityPermission() }
            }
        }
    }

    /// `tccutil reset <service> <bundle>` for this app only. Needs no admin rights.
    nonisolated private static func resetTCC(service: String, bundleID: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            Logger.info("Permissions: tccutil reset \(service) exited \(task.terminationStatus)", subsystem: .permissions)
        } catch {
            Logger.warning("Permissions: tccutil reset \(service) failed: \(error.localizedDescription)", subsystem: .permissions)
        }
    }

    /// This binary's code-directory hash: changes with every build, which is the granularity
    /// the once-per-build guard needs.
    private static func codeIdentity() -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let hash = dict[kSecCodeInfoUnique as String] as? Data else {
            return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
