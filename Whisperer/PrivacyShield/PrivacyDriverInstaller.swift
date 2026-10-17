//
//  PrivacyDriverInstaller.swift
//  Whisperer
//
//  Explicit user-triggered driver installation in direct-download builds only.
//
import Foundation

@MainActor
extension PrivacyShieldController {
    func prepareAudioSupport() async -> Bool {
        #if APP_STORE
        return false
        #else
        guard !Task.isCancelled else { return false }
        refreshDriver()
        if AppState.shared.privacyShield.driverInstalled { return true }
        guard !AppState.shared.privacyShieldInstallerBusy,
              let root = Bundle.main.resourceURL?.appendingPathComponent("PrivacyShield"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("install-driver.sh").path) else {
            AppState.shared.privacyShield.message = "Audio support is unavailable in this build."
            return false
        }
        AppState.shared.privacyShieldInstallerBusy = true
        defer { AppState.shared.privacyShieldInstallerBusy = false }
        AppState.shared.privacyShield.message = "Setting up audio support. Approve the macOS prompt to continue; this briefly restarts sound."
        let success = await Self.runInstaller(script: root.appendingPathComponent("install-driver.sh").path,
                                             source: root.appendingPathComponent("WhispererAudio.driver").path)
        guard !Task.isCancelled else { return false }
        guard success else {
            AppState.shared.privacyShield.message = "Setup was cancelled or failed. Turn on again to retry."
            return false
        }
        // coreaudiod registers a new driver asynchronously after restarting.
        for _ in 0..<40 {
            refreshDriver()
            if AppState.shared.privacyShield.driverInstalled { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled else { return false }
        AppState.shared.privacyShield.message = "Audio support is taking longer to start. Turn on again to retry."
        return false
        #endif
    }

    #if !APP_STORE
    private nonisolated static func runInstaller(script: String, source: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", """
                on run argv
                    do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges
                end run
                """, script, source]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run(); process.waitUntilExit(); continuation.resume(returning: process.terminationStatus == 0) }
                catch { continuation.resume(returning: false) }
            }
        }
    }
    #endif
}
