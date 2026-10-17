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
        let result = await Self.runInstaller(script: root.appendingPathComponent("install-driver.sh").path,
                                             source: root.appendingPathComponent("WhispererAudio.driver").path)
        guard !Task.isCancelled else { return false }
        guard result.status == 0 else {
            Logger.warning("Privacy Shield installer failed (\(result.status)): \(result.details)", subsystem: .audio)
            AppState.shared.privacyShield.message = Self.installerFailureMessage(details: result.details)
            return false
        }
        Logger.info("Privacy Shield driver installed; waiting for audio device registration.", subsystem: .audio)
        // coreaudiod registers a new driver asynchronously after restarting.
        for _ in 0..<40 {
            refreshDriver()
            if AppState.shared.privacyShield.driverInstalled { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard !Task.isCancelled else { return false }
        Logger.warning("Privacy Shield driver installation succeeded but the device did not register within 10 seconds.", subsystem: .audio)
        AppState.shared.privacyShield.message = "Audio support was installed but macOS has not loaded it. Restart your Mac to finish setup."
        return false
        #endif
    }

    nonisolated static func installerFailureMessage(details: String) -> String {
        if details.contains("(-128)") { return "Setup was cancelled. Turn on again when you’re ready." }
        if details.contains("system audio did not restart") {
            return "Audio support was installed. Restart your Mac to finish setup."
        }
        return "Audio setup failed. The macOS error was saved in Whisperer’s log."
    }

    #if !APP_STORE
    private nonisolated static func runInstaller(script: String, source: String) async -> (status: Int32, details: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", """
                on run argv
                    do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges with prompt "Whisperer needs to finish setting up its microphone. This briefly restarts sound."
                end run
                """, script, source]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                do {
                    try process.run()
                    // Drain before waiting so diagnostic output cannot fill the pipe and deadlock.
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus,
                        String(decoding: data.prefix(8192), as: UTF8.self)))
                } catch {
                    continuation.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }
    #endif
}
