//
//  WhispererApp.swift
//  Whisperer
//
//  Main app entry point - menu bar app
//

import SwiftUI

@main
struct WhispererApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu bar app - no main window
        MenuBarExtra("Whisperer", image: "MenuBarIcon") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayPanel: OverlayPanel?
    let appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)

        // Initialize components
        setupComponents()

        // Show overlay panel
        setupOverlay()

        // Check permissions
        Task {
            await checkPermissions()
        }
    }

    private func setupComponents() {
        // Initialize all components
        appState.audioRecorder = AudioRecorder()
        appState.keyListener = GlobalKeyListener()
        appState.whisperRunner = WhisperRunner()
        appState.textInjector = TextInjector()
        appState.audioMuter = AudioMuter()
        appState.soundPlayer = SoundPlayer()

        // Setup key listener callbacks
        appState.keyListener?.onFnPressed = { [weak self] in
            Task { @MainActor in
                self?.appState.startRecording()
            }
        }

        appState.keyListener?.onFnReleased = { [weak self] in
            Task { @MainActor in
                self?.appState.stopRecording()
            }
        }

        // Setup audio callback for waveform
        appState.audioRecorder?.onAmplitudeUpdate = { [weak self] amplitude in
            Task { @MainActor in
                self?.appState.updateWaveform(amplitude: amplitude)
            }
        }

        // Start key listener
        appState.keyListener?.start()
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel()
        // Panel manages its own visibility based on app state
    }

    private func checkPermissions() async {
        // Request permissions on startup
        await MainActor.run {
            // Request microphone permission
            AudioRecorder.requestMicrophonePermission()

            // Request accessibility permission (for text injection)
            TextInjector.requestAccessibilityPermission()
        }

        // Check if selected model is downloaded
        let selectedModel = await MainActor.run { appState.selectedModel }
        if !ModelDownloader.shared.isModelDownloaded(selectedModel) {
            // Download the selected model
            await appState.downloadModel(selectedModel)
        } else {
            // Model already exists - pre-load it immediately
            await MainActor.run {
                self.appState.preloadModel()
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Whisperer")
                .font(.headline)

            Divider()

            Text("Status: \(appState.state.displayText)")
                .font(.caption)

            HStack {
                Text("Model: \(appState.selectedModel.displayName)")
                    .font(.caption)
                if !appState.isModelLoaded && appState.state == .idle {
                    Text("(Loading...)")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if appState.isModelLoaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            if let error = appState.errorMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error:")
                        .font(.caption2)
                        .foregroundColor(.red)

                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(nil)
                        .textSelection(.enabled)
                        .frame(maxHeight: 200)

                    Button("Copy Error") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(error, forType: .string)
                    }
                    .font(.caption2)
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Model picker - Regular models
            Text("Standard Models")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(WhisperModel.allCases.filter { !$0.isDistilled }) { model in
                ModelMenuItem(model: model)
            }

            // Distilled models section
            if !WhisperModel.allCases.filter({ $0.isDistilled }).isEmpty {
                Text("Distilled Models (Faster)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 8)

                ForEach(WhisperModel.allCases.filter { $0.isDistilled }) { model in
                    ModelMenuItem(model: model)
                }
            }

            Divider()

            // Settings
            Toggle(isOn: $appState.muteOtherAudioDuringRecording) {
                Text("Mute other audio while recording")
                    .font(.caption)
            }
            .toggleStyle(.checkbox)

            Divider()

            Button("Check Permissions") {
                checkPermissions()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 350)
    }

    private func checkPermissions() {
        // Request microphone permission
        AudioRecorder.requestMicrophonePermission()

        // Request accessibility permission
        TextInjector.requestAccessibilityPermission()
    }
}

struct ModelMenuItem: View {
    let model: WhisperModel
    @ObservedObject var appState = AppState.shared

    var isSelected: Bool { appState.selectedModel == model }
    var isDownloaded: Bool { appState.isModelDownloaded(model) }
    var isDownloading: Bool { appState.downloadingModel == model }

    var body: some View {
        Button(action: { handleTap() }) {
            HStack {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.caption)
                    if !model.modelDescription.isEmpty {
                        Text(model.modelDescription)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Text("\(model.sizeDescription) • \(model.speedDescription)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                statusIcon
            }
        }
        .buttonStyle(.plain)
        .disabled(isDownloading || appState.downloadingModel != nil)
    }

    @ViewBuilder var statusIcon: some View {
        if isDownloading {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("\(Int(appState.downloadProgress * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } else if isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
                .font(.caption)
        }
    }

    func handleTap() {
        if isDownloaded {
            appState.selectModel(model)
        } else {
            Task {
                await appState.downloadModel(model)
            }
        }
    }
}
