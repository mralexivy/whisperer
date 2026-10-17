//
//  PrivacyShieldView.swift
//  Whisperer
//
//  Explicit experimental routing controls, using the existing navy palette.
//
import SwiftUI

struct PrivacyShieldView: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var devices = AudioDeviceManager.shared
    private var busy: Bool { app.privacyShield.phase != .off && app.privacyShield.phase != .muted }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EXPERIMENTAL").font(.caption2.bold()).foregroundStyle(MBColors.accentPurple)
                Spacer()
                Text(app.privacyShield.phase.rawValue.capitalized).font(.caption.bold()).foregroundStyle(MBColors.textPrimary)
            }
            Text(app.privacyShield.message).font(.caption).foregroundStyle(MBColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            #if !APP_STORE
            Picker("Microphone", selection: $app.privacyShieldInputUID) {
                Text("Choose a microphone").tag("")
                ForEach(devices.availableInputDevices.filter { $0.uid != PrivacyShieldController.deviceUID }, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }.disabled(busy)
            Toggle("I am using headphones", isOn: $app.privacyShieldHeadphones).tint(MBColors.accent).disabled(busy)
            HStack {
                Text(app.privacyShield.modelName ?? "DSP baseline (unvalidated)").font(.caption)
                Spacer()
                Button("Load model…") { PrivacyShieldController.shared.chooseModel() }.disabled(busy)
            }
            if app.privacyShield.modelName == nil {
                HStack {
                    Text("Effect strength").font(.caption)
                    Slider(value: $app.privacyShieldStrength, in: 0.1...1).tint(MBColors.accent).disabled(busy)
                }
            } else {
                Button("Use DSP baseline") { PrivacyShieldController.shared.useBaseline() }.disabled(busy)
            }
            HStack {
                Button(app.privacyShield.phase == .muted ? "Retry" : "Enable processing") { PrivacyShieldController.shared.start() }
                    .disabled(busy || !app.privacyShield.driverInstalled)
                if app.privacyShield.blocksTranscription {
                    Button("Turn off") { Task { await PrivacyShieldController.shared.stop() } }
                        .disabled(app.privacyShield.phase == .stopping)
                }
                Spacer()
                Button("Refresh devices") { PrivacyShieldController.shared.refreshDriver() }.disabled(busy)
            }
            if !app.privacyShield.driverInstalled {
                Button(app.privacyShieldInstallerBusy ? "Installing…" : "Install driver (restarts audio)…") {
                    PrivacyShieldController.shared.installDriver()
                }.disabled(app.privacyShieldInstallerBusy || app.privacyShield.phase != .off)
                Text("Installation needs administrator access. Finish calls first.")
                    .font(.caption).foregroundStyle(MBColors.textSecondary)
            }
            if app.privacyShield.driverInstalled && app.privacyShield.phase == .off {
                Button("Remove driver (restarts audio)…") { PrivacyShieldController.shared.installDriver(remove: true) }
                    .disabled(app.privacyShieldInstallerBusy)
            }
            if app.privacyShield.phase == .active {
                Text(String(format: "Last block: %.1f ms · queued audio: %.1f ms", app.privacyShield.processingMS, app.privacyShield.queuedMS))
                    .font(.caption.monospacedDigit()).foregroundStyle(MBColors.textSecondary)
            }
            Text("While enabled, Whisperer blocks new dictation and meeting recordings. Failures mute this virtual mic. A call may switch to another mic independently. This does not prevent recording.")
                .font(.caption2).foregroundStyle(MBColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            #else
            Text("Available only in the direct-download build.").font(.caption)
            #endif
        }
        .foregroundStyle(MBColors.textPrimary)
        .onAppear { PrivacyShieldController.shared.refreshDriver() }
    }
}
