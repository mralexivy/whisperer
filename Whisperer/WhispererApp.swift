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
    private var isShuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("Application launched", subsystem: .app)

        // Receipt validation using StoreKit 2 (disabled for now)
        // TODO: Enable when in-app purchases are ready by setting receiptValidationEnabled = true
        let receiptValidationEnabled = false

        if receiptValidationEnabled {
            #if !DEBUG
            Task {
                do {
                    let isValid = try await ReceiptValidator.shared.validateReceipt()
                    if !isValid {
                        Logger.error("Receipt validation failed", subsystem: .app)
                    } else {
                        Logger.info("Receipt validation successful", subsystem: .app)
                    }
                } catch {
                    Logger.error("Receipt validation error: \(error.localizedDescription)", subsystem: .app)
                }
            }
            #else
            Logger.debug("Skipping receipt validation in DEBUG build", subsystem: .app)
            #endif
        } else {
            Logger.debug("Receipt validation is disabled", subsystem: .app)
        }

        // Install crash handlers first thing
        CrashHandler.shared.install()

        // Start queue health monitoring
        QueueHealthMonitor.shared.startMonitoring()

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

        // Show onboarding window on first launch
        OnboardingWindowManager.shared.showIfNeeded()
    }

    private func setupComponents() {
        // Initialize core components (always needed)
        appState.audioRecorder = AudioRecorder()
        appState.whisperRunner = WhisperRunner()
        appState.textInjector = TextInjector()
        appState.audioMuter = AudioMuter()
        appState.soundPlayer = SoundPlayer()

        // Set initial selected microphone
        appState.audioRecorder?.selectedDeviceID = appState.audioDeviceManager.selectedDevice?.id

        // Setup audio callback for waveform
        appState.audioRecorder?.onAmplitudeUpdate = { [weak self] amplitude in
            Task { @MainActor in
                self?.appState.updateWaveform(amplitude: amplitude)
            }
        }

        // Setup device recovery callback
        appState.audioRecorder?.onDeviceRecovery = { [weak self] message in
            Task { @MainActor in
                self?.appState.errorMessage = message
            }
        }

        // Only start global key listener if user has opted in
        if appState.systemWideDictationEnabled {
            appState.startGlobalDictation()
        }

        // Eagerly initialize DictionaryManager so its background loading
        // (CoreData fetch + SymSpell/PhoneticMatcher index build) completes
        // before the user's first recording, avoiding a text entry delay.
        _ = DictionaryManager.shared
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel()
        // Panel manages its own visibility based on app state
    }

    private func checkPermissions() async {
        // Only request microphone on startup (core feature).
        // Accessibility is requested only when user enables system-wide dictation.
        await MainActor.run {
            let permissionManager = PermissionManager.shared

            if permissionManager.microphoneStatus != .granted {
                permissionManager.requestMicrophonePermission()
            }
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

    // MARK: - Graceful Shutdown (Fixes crash on quit)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Prevent re-entrancy
        guard !isShuttingDown else {
            return .terminateNow
        }
        isShuttingDown = true

        Logger.info("App termination requested, starting graceful shutdown...", subsystem: .app)

        // Start async cleanup
        Task {
            await gracefulShutdown()

            // Now it's safe to terminate
            Logger.info("Graceful shutdown complete, terminating", subsystem: .app)
            Logger.flush()

            DispatchQueue.main.async {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }

        // Tell macOS to wait for our cleanup
        return .terminateLater
    }

    private func gracefulShutdown() async {
        // 1. Stop any active recording
        Logger.debug("Stopping active recording if any...", subsystem: .app)
        await MainActor.run {
            if appState.state != .idle {
                appState.state = .idle
            }
        }

        // 2. Stop audio engine
        Logger.debug("Stopping audio engine...", subsystem: .app)
        await appState.audioRecorder?.stopRecording()

        // 3. Stop key listener
        Logger.debug("Stopping key listener...", subsystem: .app)
        appState.keyListener?.stop()

        // 4. Free whisper context BEFORE exit() runs C++ destructors
        // This is the key fix - explicitly free the context while we control the timing
        Logger.debug("Freeing whisper context...", subsystem: .app)
        await MainActor.run {
            appState.releaseWhisperResources()
        }

        // 5. Give Metal backend time to finish any pending operations
        Logger.debug("Waiting for Metal operations to complete...", subsystem: .app)
        try? await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        // 6. Stop queue health monitoring
        Logger.debug("Stopping queue health monitoring...", subsystem: .app)
        QueueHealthMonitor.shared.stopMonitoring()

        // 7. Remove crash marker (clean exit)
        CrashHandler.shared.uninstall()
    }
}

// MARK: - Tab Enum

enum MenuTab: String, CaseIterable {
    case status = "Status"
    case models = "Models"
    case settings = "Settings"

    var icon: String {
        switch self {
        case .status: return "waveform"
        case .models: return "cpu"
        case .settings: return "gear"
        }
    }

    var color: Color {
        switch self {
        case .status: return Color(red: 0.357, green: 0.424, blue: 0.969) // blue
        case .models: return .orange
        case .settings: return .purple
        }
    }
}

// MARK: - Menu Bar Colors (dark navy palette — matches workspace & onboarding)

private enum MBColors {
    static let background       = Color(red: 0.047, green: 0.047, blue: 0.102)  // #0C0C1A
    static let cardSurface      = Color(red: 0.078, green: 0.078, blue: 0.169)  // #14142B
    static let elevated         = Color(red: 0.110, green: 0.110, blue: 0.227)  // #1C1C3A
    static let accent           = Color(red: 0.357, green: 0.424, blue: 0.969)  // #5B6CF7
    static let accentPurple     = Color(red: 0.545, green: 0.361, blue: 0.965)  // #8B5CF6
    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accentPurple], startPoint: .leading, endPoint: .trailing)
    }
    static let textPrimary      = Color.white
    static let textSecondary    = Color.white.opacity(0.5)
    static let textTertiary     = Color.white.opacity(0.35)
    static let border           = Color.white.opacity(0.06)
    static let pill             = Color.white.opacity(0.08)
}

// MARK: - Menu Bar Window Configurator

/// Finds the hosting NSWindow and forces dark appearance + navy background
/// so the system window chrome matches the content.
private struct MenuBarWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0)
            window.isOpaque = false
            window.hasShadow = false

            // Remove visible border by configuring the content view layer
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = NSColor(red: 0.047, green: 0.047, blue: 0.102, alpha: 1.0).cgColor
                contentView.layer?.cornerRadius = 10
                contentView.layer?.masksToBounds = true
                contentView.layer?.borderWidth = 0
                contentView.layer?.borderColor = NSColor.clear.cgColor
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Main Menu Bar View

struct MenuBarView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared
    @State private var selectedTab: MenuTab = .status

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient
            headerView

            // Tab bar
            tabBar

            // Content area - flexible height based on content
            tabContent
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Spacer(minLength: 0)

            // Footer
            footerView
        }
        .frame(width: 360, height: 580)
        .background(MBColors.background)
        .background(MenuBarWindowConfigurator())
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // App icon with gradient glow
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [MBColors.accent.opacity(0.3), MBColors.accentPurple.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: statusIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(MBColors.accentGradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisperer")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(MBColors.textPrimary)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(appState.state.displayText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(MBColors.textSecondary)
                    }
                }

                Spacer()

                // Model badge
                HStack(spacing: 4) {
                    if appState.isModelLoaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(MBColors.accent)
                            .font(.system(size: 10))
                    } else if appState.state == .idle {
                        ProgressView()
                            .scaleEffect(0.5)
                    }

                    Text(appState.selectedModel.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(MBColors.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(MBColors.pill)
                .cornerRadius(12)
            }

            // Error banner if present
            if let error = appState.errorMessage {
                errorBanner(error)
            }
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [MBColors.accent.opacity(0.1), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var statusIcon: String {
        switch appState.state {
        case .recording: return "mic.fill"
        case .transcribing: return "text.bubble"
        case .inserting: return "doc.text"
        case .downloadingModel: return "arrow.down.circle"
        default: return "waveform"
        }
    }

    private var statusColor: Color {
        switch appState.state {
        case .recording: return .red
        case .transcribing, .inserting: return .orange
        case .downloadingModel: return MBColors.accent
        default: return appState.isModelLoaded ? MBColors.accent : .orange
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)

            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .lineLimit(2)

            Spacer()

            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(error, forType: .string)
            }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(10)
        .background(Color.red.opacity(0.15))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(MenuTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(MBColors.cardSurface)
    }

    private func tabButton(_ tab: MenuTab) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(tab.color)
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selectedTab == tab ? MBColors.textPrimary : MBColors.textSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                selectedTab == tab
                    ? tab.color.opacity(0.12)
                    : Color.clear
            )
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .status:
            StatusTabView()
        case .models:
            ModelsTabView()
        case .settings:
            SettingsTabView()
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack(spacing: 12) {
            // Workspace button - blue-purple gradient
            Button(action: { HistoryWindowManager.shared.showWindowAndDismissMenu() }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Workspace")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(MBColors.accentGradient)
                .cornerRadius(8)
                .shadow(color: MBColors.accent.opacity(0.3), radius: 4, x: 0, y: 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Quit button - prominent
            Button(action: { NSApplication.shared.terminate(nil) }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium))
                    Text("⌘Q")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(4)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color.red.opacity(0.9), Color.red],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .cornerRadius(8)
                .shadow(color: Color.red.opacity(0.3), radius: 4, x: 0, y: 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            MBColors.cardSurface
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(MBColors.border),
                    alignment: .top
                )
        )
    }

}

// MARK: - Status Tab

struct StatusTabView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared

    /// Whether to show permission warnings (mode-aware)
    private var showPermissionWarning: Bool {
        if permissionManager.microphoneStatus != .granted { return true }
        if appState.systemWideDictationEnabled && permissionManager.accessibilityStatus != .granted { return true }
        return false
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                // Permission warning banner (mode-aware)
                if showPermissionWarning {
                    permissionWarningBanner
                }

                // In-App Transcription — core feature, no Accessibility required
                inAppTranscriptionCard

                // Quick info cards
                VStack(spacing: 12) {
                    infoCard(
                        icon: "cpu",
                        title: "Model",
                        value: appState.selectedModel.displayName,
                        detail: appState.selectedModel.sizeDescription,
                        color: .blue
                    )

                    infoCard(
                        icon: "mic",
                        title: "Microphone",
                        value: AudioDeviceManager.shared.selectedDevice?.name ?? "System Default",
                        detail: nil,
                        color: .cyan
                    )

                    // Only show shortcut card when system-wide dictation is enabled
                    if appState.systemWideDictationEnabled {
                        infoCard(
                            icon: "keyboard",
                            title: "Shortcut",
                            value: appState.keyListener?.shortcutConfig.displayString ?? "Fn",
                            detail: appState.keyListener?.shortcutConfig.recordingMode.displayName,
                            color: .purple
                        )
                    }
                }

                // Usage hint — context-dependent
                if appState.systemWideDictationEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("System-Wide Dictation")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(MBColors.textSecondary)

                        HStack(spacing: 12) {
                            stepBadge(number: 1, text: "Hold shortcut")
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(MBColors.textTertiary)
                            stepBadge(number: 2, text: "Speak")
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundColor(MBColors.textTertiary)
                            stepBadge(number: 3, text: "Release")
                        }
                    }
                    .padding(12)
                    .background(MBColors.cardSurface)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(MBColors.border, lineWidth: 1)
                    )
                } else {
                    // Prompt to enable system-wide dictation
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                                .font(.system(size: 14))
                                .foregroundColor(MBColors.accent)
                            Text("System-Wide Dictation")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(MBColors.textPrimary)
                        }
                        Text("Dictate text anywhere you can type. Enable in Settings.")
                            .font(.system(size: 11))
                            .foregroundColor(MBColors.textSecondary)
                    }
                    .padding(12)
                    .background(MBColors.accent.opacity(0.08))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(MBColors.accent.opacity(0.15), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: - In-App Transcription Card

    private var inAppTranscriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(MBColors.accent.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .foregroundColor(MBColors.accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcribe")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(MBColors.textPrimary)
                    Text("Record and transcribe your voice")
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                }

                Spacer()
            }

            // Recording state or result
            if appState.isInAppMode && appState.state.isRecording {
                // Live transcription during recording
                VStack(spacing: 8) {
                    // Waveform
                    HStack(spacing: 2) {
                        ForEach(0..<appState.waveformAmplitudes.count, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.red)
                                .frame(width: 3, height: max(3, CGFloat(appState.waveformAmplitudes[i]) * 30))
                        }
                    }
                    .frame(height: 30)
                    .animation(.easeOut(duration: 0.1), value: appState.waveformAmplitudes)

                    if !appState.liveTranscription.isEmpty {
                        Text(appState.liveTranscription)
                            .font(.system(size: 12))
                            .foregroundColor(MBColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                    }

                    // Stop button
                    Button(action: {
                        appState.stopInAppRecording()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                            Text("Stop")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            } else if !appState.lastInAppTranscription.isEmpty {
                // Show result
                VStack(spacing: 8) {
                    Text(appState.lastInAppTranscription)
                        .font(.system(size: 12))
                        .foregroundColor(MBColors.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(MBColors.elevated)
                        .cornerRadius(6)
                        .textSelection(.enabled)

                    HStack(spacing: 8) {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.lastInAppTranscription, forType: .string)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                                Text("Copy")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(MBColors.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MBColors.accent.opacity(0.15))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            appState.lastInAppTranscription = ""
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                Text("Clear")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(MBColors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MBColors.pill)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        // Record again button
                        Button(action: {
                            appState.lastInAppTranscription = ""
                            appState.startInAppRecording()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 10))
                                Text("Record")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(MBColors.accent)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                // Record button
                Button(action: {
                    appState.startInAppRecording()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12))
                        Text("Record")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        appState.isModelLoaded && permissionManager.microphoneStatus == .granted
                            ? MBColors.accentGradient
                            : LinearGradient(colors: [Color.gray], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(!appState.isModelLoaded || permissionManager.microphoneStatus != .granted)
            }
        }
        .padding(12)
        .background(MBColors.cardSurface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(MBColors.border, lineWidth: 1)
        )
    }

    private func infoCard(icon: String, title: String, value: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(MBColors.textTertiary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(MBColors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(MBColors.pill)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(MBColors.cardSurface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(MBColors.border, lineWidth: 1)
        )
    }

    private func stepBadge(number: Int, text: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(MBColors.accent)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundColor(MBColors.textSecondary)
        }
    }

    private var permissionWarningBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 14))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions Required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.orange)

                    Text("Some features won't work without permissions")
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                }

                Spacer()
            }

            // Show which permissions are missing (mode-aware)
            HStack(spacing: 8) {
                if permissionManager.microphoneStatus != .granted {
                    missingPermissionBadge("Mic", icon: "mic.fill")
                }
                // Only show Accessibility as missing when system-wide dictation is enabled
                if appState.systemWideDictationEnabled && permissionManager.accessibilityStatus != .granted {
                    missingPermissionBadge("Accessibility", icon: "accessibility")
                }
            }

            Button(action: {
                if permissionManager.microphoneStatus != .granted {
                    permissionManager.requestMicrophonePermission()
                }
                if appState.systemWideDictationEnabled && permissionManager.accessibilityStatus != .granted {
                    permissionManager.requestAccessibilityPermission()
                }
            }) {
                HStack {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 10))
                    Text("Grant Permissions")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.orange)
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    private func missingPermissionBadge(_ name: String, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(name)
                .font(.system(size: 10))
        }
        .foregroundColor(.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.orange.opacity(0.15))
        .cornerRadius(4)
    }
}

// MARK: - Models Tab

struct ModelsTabView: View {
    @ObservedObject var appState = AppState.shared
    @State private var expandedSection: String? = "recommended"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Recommended
            modelSection(
                title: "Recommended",
                icon: "crown.fill",
                color: .yellow,
                models: [.largeTurboQ5],
                sectionId: "recommended"
            )

            // Turbo & Optimized
            modelSection(
                title: "Turbo & Optimized",
                icon: "bolt.fill",
                color: .orange,
                models: [.largeTurbo, .largeV3Q5],
                sectionId: "turbo"
            )

            // Standard
            modelSection(
                title: "Standard",
                icon: "cube.fill",
                color: .blue,
                models: [.tiny, .base, .small, .medium, .largeV3],
                sectionId: "standard"
            )

            // Distilled
            modelSection(
                title: "Distilled",
                icon: "wand.and.stars",
                color: .purple,
                models: WhisperModel.allCases.filter { $0.isDistilled },
                sectionId: "distilled"
            )
        }
    }

    private func modelSection(title: String, icon: String, color: Color, models: [WhisperModel], sectionId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSection = expandedSection == sectionId ? nil : sectionId
                }
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.opacity(0.15))
                            .frame(width: 26, height: 26)
                        Image(systemName: icon)
                            .foregroundColor(color)
                            .font(.system(size: 12, weight: .medium))
                    }

                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(MBColors.textPrimary)

                    Spacer()

                    Image(systemName: expandedSection == sectionId ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(MBColors.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedSection == sectionId {
                VStack(spacing: 6) {
                    ForEach(models, id: \.self) { model in
                        ModelMenuItem(model: model)
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(12)
        .background(MBColors.cardSurface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(MBColors.border, lineWidth: 1)
        )
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // System-Wide Dictation toggle — top of settings
                settingsCard(title: "System-Wide Dictation", icon: "globe", color: .blue) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Dictate anywhere")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(MBColors.textPrimary)
                                Text("Assistive dictation — enter text wherever you type, just like Apple's built-in dictation")
                                    .font(.system(size: 11))
                                    .foregroundColor(MBColors.textSecondary)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { appState.systemWideDictationEnabled },
                                set: { newValue in
                                    appState.systemWideDictationEnabled = newValue
                                    // Request Accessibility permission when first enabled
                                    if newValue && PermissionManager.shared.accessibilityStatus != .granted {
                                        PermissionManager.shared.requestAccessibilityPermission()
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                        }

                        if !appState.systemWideDictationEnabled {
                            Text("Enable to hold a shortcut key and dictate text into any app. Requires Accessibility permission.")
                                .font(.system(size: 10))
                                .foregroundColor(MBColors.textSecondary)
                                .padding(8)
                                .background(MBColors.accent.opacity(0.08))
                                .cornerRadius(6)
                        }
                    }
                }

                // Audio Settings - compact card
                settingsCard(title: "Audio", icon: "speaker.wave.2.fill", color: .orange) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mute other audio")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Pause system audio while recording")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.muteOtherAudioDuringRecording)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                    }
                }

                // Language Settings
                settingsCard(title: "Language", icon: "globe", color: .blue) {
                    LanguagePickerView()
                }

                // Microphone Settings
                settingsCard(title: "Microphone", icon: "mic.fill", color: .green) {
                    MicrophonePickerView()
                }

                // Keyboard Shortcut (only when system-wide dictation is enabled)
                if appState.systemWideDictationEnabled {
                    settingsCard(title: "Shortcut", icon: "keyboard", color: .purple) {
                        ShortcutRecorderView()
                    }
                }

                // Workspace
                settingsCard(title: "Workspace", icon: "square.grid.2x2.fill", color: .indigo) {
                    Button(action: {
                        HistoryWindowManager.shared.showWindowAndDismissMenu()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("View transcription history")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(MBColors.textPrimary)
                                Text("Open workspace window")
                                    .font(.system(size: 11))
                                    .foregroundColor(MBColors.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 13))
                                .foregroundColor(MBColors.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Permissions
                settingsCard(title: "Permissions", icon: "lock.shield.fill", color: .red) {
                    PermissionsView()
                }

                // Diagnostics
                settingsCard(title: "Diagnostics", icon: "ladybug.fill", color: .gray) {
                    DiagnosticsView()
                }

                // Pro Pack
                settingsCard(title: "Pro Pack", icon: "star.fill", color: .yellow) {
                    PurchaseView()
                }

                // About
                settingsCard(title: "About", icon: "info.circle.fill", color: .blue) {
                    AboutView()
                }
            }
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 12, weight: .medium))
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)
            }

            // Content
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(MBColors.cardSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(MBColors.border, lineWidth: 1)
                )
        )
    }
}

// MARK: - Model Menu Item

struct ModelMenuItem: View {
    let model: WhisperModel
    @ObservedObject var appState = AppState.shared

    var isSelected: Bool { appState.selectedModel == model }
    var isDownloaded: Bool { appState.isModelDownloaded(model) }
    var isDownloading: Bool { appState.downloadingModel == model }

    var body: some View {
        Button(action: { handleTap() }) {
            HStack(spacing: 10) {
                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? MBColors.accent : MBColors.textTertiary, lineWidth: 2)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(MBColors.accent)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? MBColors.textPrimary : MBColors.textSecondary)

                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                            .font(.caption2)
                        Text("•")
                            .font(.caption2)
                        Text(model.speedDescription)
                            .font(.caption2)
                    }
                    .foregroundColor(MBColors.textTertiary)
                }

                Spacer()

                statusBadge
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDownloading || appState.downloadingModel != nil)
    }

    @ViewBuilder var statusBadge: some View {
        if isDownloading {
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                Text("\(Int(appState.downloadProgress * 100))%")
                    .font(.caption2)
                    .foregroundColor(MBColors.accent)
            }
        } else if isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(MBColors.accent)
                .font(.system(size: 14))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14))
                Text("Download")
                    .font(.caption2)
            }
            .foregroundColor(MBColors.accent)
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

// MARK: - Microphone Picker View

struct MicrophonePickerView: View {
    @ObservedObject var deviceManager = AudioDeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Default option
            microphoneRow(
                name: "System Default",
                detail: deviceManager.getDefaultInputDevice()?.name,
                isSelected: deviceManager.preferredDeviceUID == nil,
                action: { deviceManager.selectDevice(nil) }
            )

            // Available devices
            ForEach(deviceManager.availableInputDevices) { device in
                microphoneRow(
                    name: device.name,
                    detail: deviceManager.getDefaultInputDevice()?.uid == device.uid ? "Default" : nil,
                    isSelected: deviceManager.selectedDevice?.uid == device.uid && deviceManager.preferredDeviceUID != nil,
                    action: { deviceManager.selectDevice(device) }
                )
            }

            if deviceManager.availableInputDevices.isEmpty {
                Text("No microphones found")
                    .font(.caption)
                    .foregroundColor(MBColors.textTertiary)
                    .italic()
                    .padding(.vertical, 4)
            }
        }
        .onAppear {
            deviceManager.refreshDevices()
        }
    }

    private func microphoneRow(name: String, detail: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? MBColors.accent : MBColors.textTertiary, lineWidth: 2)
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(MBColors.accent)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? MBColors.textPrimary : MBColors.textSecondary)

                Spacer()

                if let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(MBColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MBColors.pill)
                        .cornerRadius(4)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Language Picker View

struct LanguagePickerView: View {
    @ObservedObject var appState = AppState.shared
    @State private var isExpanded = false
    @State private var searchText = ""

    var filteredLanguages: [TranscriptionLanguage] {
        if searchText.isEmpty {
            return TranscriptionLanguage.allCases
        } else {
            return TranscriptionLanguage.allCases.filter { lang in
                lang.displayName.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collapsed view - current selection (always visible)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    if !isExpanded {
                        searchText = ""
                    }
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Transcription language")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(MBColors.textPrimary)
                        Text(appState.selectedLanguage.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(MBColors.textSecondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(MBColors.textTertiary)
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded view - search and language list (only when expanded)
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    // Search field
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(MBColors.textTertiary)
                            .font(.system(size: 12))

                        TextField("Search languages...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(MBColors.textPrimary)

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(MBColors.textTertiary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(MBColors.elevated)
                    .cornerRadius(6)

                    // Language list - show max 5 items (160px height)
                    if filteredLanguages.isEmpty {
                        Text("No languages found")
                            .font(.caption)
                            .foregroundColor(MBColors.textTertiary)
                            .italic()
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(filteredLanguages, id: \.self) { language in
                                    languageRow(language: language)
                                }
                            }
                        }
                        .frame(height: min(CGFloat(filteredLanguages.count) * 32, 160))
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func languageRow(language: TranscriptionLanguage) -> some View {
        Button(action: {
            appState.selectedLanguage = language
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded = false
                searchText = ""
            }
        }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(appState.selectedLanguage == language ? MBColors.accent : MBColors.textTertiary, lineWidth: 2)
                        .frame(width: 14, height: 14)

                    if appState.selectedLanguage == language {
                        Circle()
                            .fill(MBColors.accent)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(language.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(appState.selectedLanguage == language ? MBColors.textPrimary : MBColors.textSecondary)

                Spacer()

                if language == .auto {
                    Text("May be unreliable")
                        .font(.caption2)
                        .foregroundColor(MBColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MBColors.pill)
                        .cornerRadius(4)
                } else if language == .english {
                    Text("Default")
                        .font(.caption2)
                        .foregroundColor(MBColors.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MBColors.pill)
                        .cornerRadius(4)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Permissions View

struct PermissionsView: View {
    @ObservedObject var permissionManager = PermissionManager.shared
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Collapsed view - summary status (always visible)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Required permissions")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(MBColors.textPrimary)

                        if permissionManager.allPermissionsGranted {
                            Text("All permissions granted")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        } else {
                            Text("Some permissions missing")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                        }
                    }

                    Spacer()

                    // Status indicator
                    if permissionManager.allPermissionsGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 16))
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 16))
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(MBColors.textTertiary)
                        .font(.system(size: 11, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded view - individual permission status
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()

                    ForEach(PermissionType.allCases, id: \.self) { permission in
                        permissionRow(permission)
                    }

                    // Request all button
                    if !permissionManager.allPermissionsGranted {
                        Button(action: requestAllPermissions) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                Text("Request All Permissions")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(MBColors.accent)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear {
            // Auto-expand if permissions are missing
            if !permissionManager.allPermissionsGranted {
                isExpanded = true
            }
        }
    }

    private func permissionRow(_ permission: PermissionType) -> some View {
        let status = permissionManager.status(for: permission)

        return HStack(spacing: 10) {
            // Icon
            Image(systemName: permission.icon)
                .foregroundColor(status == .granted ? .green : .orange)
                .font(.system(size: 12))
                .frame(width: 20)

            // Name and description
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(status == .granted ? MBColors.textPrimary : MBColors.textSecondary)

                Text(permission.description)
                    .font(.system(size: 10))
                    .foregroundColor(MBColors.textTertiary)
            }

            Spacer()

            // Status badge
            if status == .granted {
                Text("Granted")
                    .font(.caption2)
                    .foregroundColor(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(4)
            } else {
                Button(action: {
                    requestPermission(permission)
                }) {
                    Text("Grant")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func requestPermission(_ permission: PermissionType) {
        switch permission {
        case .microphone:
            permissionManager.requestMicrophonePermission()
        case .accessibility:
            permissionManager.requestAccessibilityPermission()
        }
    }

    private func requestAllPermissions() {
        if permissionManager.microphoneStatus != .granted {
            permissionManager.requestMicrophonePermission()
        }
        if permissionManager.accessibilityStatus != .granted {
            permissionManager.requestAccessibilityPermission()
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @State private var logFileSize: String = "..."
    @State private var verboseLogging: Bool = Logger.isVerbose

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Verbose logging toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verbose logging")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MBColors.textPrimary)
                    Text("Enable debug-level logs for troubleshooting")
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: $verboseLogging)
                    .toggleStyle(.switch)
                    .tint(MBColors.accent)
                    .labelsHidden()
                    .onChange(of: verboseLogging) { _, newValue in
                        Logger.isVerbose = newValue
                    }
            }

            Divider()
                .opacity(0.3)

            // Log file info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log file")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(MBColors.textPrimary)
                    Text(logFileSize)
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textSecondary)
                }

                Spacer()

                Button(action: {
                    Logger.openLogInFinder()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 11))
                        Text("Open Logs Folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(MBColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(MBColors.pill)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // Crash log indicator
            if CrashHandler.hasCrashLog {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 11))
                    Text("Crash log available")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                }
            }

            Divider()
                .opacity(0.3)

            // Version info
            HStack {
                Text("Version")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                Spacer()
                Text(appVersion)
                    .font(.system(size: 11))
                    .foregroundColor(MBColors.textSecondary)
            }
        }
        .onAppear {
            updateLogFileSize()
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func updateLogFileSize() {
        let url = Logger.logFileURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            if size < 1024 {
                logFileSize = "\(size) bytes"
            } else if size < 1024 * 1024 {
                logFileSize = String(format: "%.1f KB", Double(size) / 1024.0)
            } else {
                logFileSize = String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
            }
        } else {
            logFileSize = "Not found"
        }
    }
}

// MARK: - About View

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // App info
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 32))
                    .foregroundColor(MBColors.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisperer")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(MBColors.textPrimary)

                    Text("Offline Voice Transcription for Mac")
                        .font(.system(size: 12))
                        .foregroundColor(MBColors.textSecondary)

                    Text(appVersion)
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textTertiary)
                }
            }

            Divider()
                .opacity(0.3)

            // Links
            VStack(alignment: .leading, spacing: 10) {
                Text("Legal & Information")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)

                linkButton(
                    icon: "hand.raised",
                    title: "Privacy Policy",
                    action: openPrivacyPolicy
                )

                linkButton(
                    icon: "globe",
                    title: "Website",
                    action: openWebsite
                )
            }

            Divider()
                .opacity(0.3)

            // Copyright
            Text("© 2026 Whisperer. All rights reserved.")
                .font(.system(size: 10))
                .foregroundColor(MBColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Powered by whisper.cpp — 100% offline")
                .font(.system(size: 10))
                .foregroundColor(MBColors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }

    private func linkButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(MBColors.accent)
                    .font(.system(size: 12))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(MBColors.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(MBColors.elevated)
            .cornerRadius(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openPrivacyPolicy() {
        if let url = URL(string: "https://whispererapp.com/privacy") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openWebsite() {
        if let url = URL(string: "https://whispererapp.com") {
            NSWorkspace.shared.open(url)
        }
    }
}
