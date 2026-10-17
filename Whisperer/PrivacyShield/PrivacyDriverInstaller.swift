//
//  PrivacyDriverInstaller.swift
//  Whisperer
//
//  Explicit user-triggered driver installation in direct-download builds only.
//
import Foundation

@MainActor
extension PrivacyShieldController {
    func installDriver(remove: Bool = false) {
        #if !APP_STORE
        guard AppState.shared.privacyShield.phase == .off, !AppState.shared.privacyShieldInstallerBusy else { return }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("PrivacyShield"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("install-driver.sh").path) else {
            AppState.shared.privacyShield.message = "Driver resources are missing. Rebuild the direct-download app."
            return
        }
        AppState.shared.privacyShieldInstallerBusy = true
        AppState.shared.privacyShield.message = "Administrator authorization will appear. This restarts system audio; finish calls first."
        let script = root.appendingPathComponent("install-driver.sh").path
        let source = remove ? "--uninstall" : root.appendingPathComponent("WhispererAudio.driver").path
        Task { [weak self] in
            let success = await Self.runInstaller(script: script, source: source)
            guard let self else { return }
            AppState.shared.privacyShieldInstallerBusy = false
            AppState.shared.privacyShield.message = success
                ? (remove ? "Driver removed." : "Driver installed. Refresh devices, then select a microphone.")
                : "Installation was cancelled or failed. Refresh devices to check the installed driver before retrying."
            refreshDriver()
        }
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
