// Privacy Shield's everyday controls. Setup is owned by the controller.
import SwiftUI

struct PrivacyShieldView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if !APP_STORE
            Toggle("Privacy Shield", isOn: Binding(
                get: { app.privacyShield.blocksTranscription },
                set: { enabled in
                    if enabled { PrivacyShieldController.shared.start() }
                    else { Task { await PrivacyShieldController.shared.stop() } }
                }))
                .toggleStyle(.switch)
                .tint(MBColors.accent)
                .disabled(app.privacyShield.phase == .stopping || (app.privacyShieldInstallerBusy && app.privacyShield.phase == .off))
            HStack(spacing: 8) {
                if app.privacyShield.phase == .starting || app.privacyShield.phase == .stopping {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: app.privacyShield.phase == .active ? "waveform" : "shield.lefthalf.filled")
                        .foregroundStyle(MBColors.accentPurple)
                }
                Text(app.privacyShield.message).font(.caption)
                    .foregroundStyle(MBColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let name = app.privacyShield.microphoneName, app.privacyShield.blocksTranscription {
                Text("Microphone: \(name) · automatic")
                    .font(.caption2).foregroundStyle(MBColors.textSecondary)
            }
            if !app.privacyShield.driverInstalled && app.privacyShield.phase == .off {
                Text("First use sets up audio support and briefly restarts sound. macOS may ask for your password. Finish calls before turning it on.")
                    .font(.caption2).foregroundStyle(MBColors.textSecondary)
            }
            Text("Experimental audio effect. It did not prevent transcription in our tests. Use headphones; speaker echo cancellation is not available.")
                .font(.caption2).foregroundStyle(MBColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Available in the direct-download version.").font(.caption)
            #endif
        }
        .foregroundStyle(MBColors.textPrimary)
        .onAppear { PrivacyShieldController.shared.refreshDriver() }
    }
}
