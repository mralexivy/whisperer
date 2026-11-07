// Privacy Shield's everyday controls. Setup is owned by the controller.
import SwiftUI

struct PrivacyShieldView: View {
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if !APP_STORE
            Toggle("Automatic Privacy Shield", isOn: Binding(
                get: { app.privacyShield.isEnabled },
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
            if let name = app.privacyShield.microphoneName, app.privacyShield.isEnabled {
                Text("Microphone: \(name) · automatic")
                    .font(.caption2).foregroundStyle(MBColors.textSecondary)
            }
            if !app.privacyShield.driverInstalled && app.privacyShield.phase == .off {
                Text("First use sets up audio support and briefly restarts sound. macOS may ask for your password. Finish calls before turning it on.")
                    .font(.caption2).foregroundStyle(MBColors.textSecondary)
            }
            Text("A small model on your Mac adds a quiet, voice-shaped signal so AI notetakers and live captions get your words wrong. People on the call still hear you. It makes transcription much harder, not impossible. Use headphones.")
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
