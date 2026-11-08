// Privacy Shield's everyday controls. Setup is owned by the controller.
import SwiftUI

struct PrivacyShieldView: View {
    @ObservedObject private var app = AppState.shared
    @State private var jams = PrivacyShieldController.jamsTranscription

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
            Toggle("Block transcription", isOn: Binding(
                get: { jams },
                set: { jams = $0; PrivacyShieldController.shared.setJamsTranscription($0) }))
                .toggleStyle(.switch)
                .tint(MBColors.accent)
                .disabled(app.privacyShield.phase == .stopping || app.privacyShield.phase == .starting)
            Text(jams
                 ? "Your Mac reshapes your voice and scrambles it in short slices before it reaches the call. Your voice sounds robotic to people on the call; AI note takers get mostly nonsense, and can't identify or clone your voice. In our tests on real speech after a call, three speech recognizers kept only about 1 in 8 of the words that matter. It makes transcription much harder, not impossible. Adds about 90 ms of delay. Use headphones."
                 : "Your Mac reshapes your voice before it reaches the call, so AI can't identify you or clone your voice. People and transcription still get every word. It makes recognition much harder, not impossible. Use headphones.")
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
