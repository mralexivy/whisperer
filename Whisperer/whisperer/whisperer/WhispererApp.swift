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

        // Validate App Store receipt (only in Release builds)
        #if !DEBUG
        do {
            let isValid = try ReceiptValidator.shared.validateReceipt()
            if !isValid {
                Logger.error("Receipt validation failed", subsystem: .app)
                // Exit with code 173 to trigger receipt refresh from App Store
                exit(173)
            }
            Logger.info("Receipt validation successful", subsystem: .app)
        } catch ReceiptValidationError.noReceiptFound {
            Logger.error("No App Store receipt found", subsystem: .app)
            // Exit with 173 to prompt macOS to obtain receipt
            exit(173)
        } catch {
            Logger.error("Receipt validation error: \(error.localizedDescription)", subsystem: .app)
            exit(173)
        }
        #else
        Logger.debug("Skipping receipt validation in DEBUG build", subsystem: .app)
        #endif

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
    }

    private func setupComponents() {
        // Initialize all components
        appState.audioRecorder = AudioRecorder()
        appState.keyListener = GlobalKeyListener()
        appState.whisperRunner = WhisperRunner()
        appState.textInjector = TextInjector()
        appState.audioMuter = AudioMuter()
        appState.soundPlayer = SoundPlayer()

        // Set initial selected microphone
        appState.audioRecorder?.selectedDeviceID = appState.audioDeviceManager.selectedDevice?.id

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

        appState.keyListener?.onShortcutCancelled = { [weak self] in
            Task { @MainActor in
                self?.appState.cancelRecording()
            }
        }

        appState.keyListener?.onHistoryShortcut = {
            Task { @MainActor in
                HistoryWindowManager.shared.toggleWindow()
            }
        }

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

        // Start key listener
        appState.keyListener?.start()
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel()
        // Panel manages its own visibility based on app state
    }

    private func checkPermissions() async {
        // Initialize permission manager and request permissions on startup
        await MainActor.run {
            let permissionManager = PermissionManager.shared

            // Request microphone permission if not granted
            if permissionManager.microphoneStatus != .granted {
                permissionManager.requestMicrophonePermission()
            }

            // Request accessibility permission if not granted
            if permissionManager.accessibilityStatus != .granted {
                permissionManager.requestAccessibilityPermission()
            }

            // Input monitoring is checked when GlobalKeyListener starts
            // If it failed, the permission warning will show in the UI
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
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // App icon with glow effect
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 44, height: 44)

                    Image(systemName: statusIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisperer")
                        .font(.system(size: 16, weight: .bold))

                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)

                        Text(appState.state.displayText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Model badge
                HStack(spacing: 4) {
                    if appState.isModelLoaded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 10))
                    } else if appState.state == .idle {
                        ProgressView()
                            .scaleEffect(0.5)
                    }

                    Text(appState.selectedModel.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
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
                colors: [Color.accentColor.opacity(0.1), Color.clear],
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
        case .downloadingModel: return .blue
        default: return appState.isModelLoaded ? .green : .orange
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
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
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
        .background(Color.secondary.opacity(0.05))
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
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                selectedTab == tab
                    ? Color.accentColor.opacity(0.15)
                    : Color.clear
            )
            .foregroundColor(selectedTab == tab ? .accentColor : .secondary)
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
            // Permissions button - navigates to Settings tab
            Button(action: { selectedTab = .settings }) {
                HStack(spacing: 6) {
                    ZStack {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11))

                        // Warning badge if permissions missing
                        if !permissionManager.allPermissionsGranted {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                                .offset(x: 6, y: -5)
                        }
                    }
                    Text("Permissions")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(permissionManager.allPermissionsGranted ? .secondary : .orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(permissionManager.allPermissionsGranted ? Color.secondary.opacity(0.08) : Color.orange.opacity(0.15))
                .cornerRadius(8)
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
            Color.secondary.opacity(0.03)
                .overlay(
                    Rectangle()
                        .frame(height: 1)
                        .foregroundColor(Color.secondary.opacity(0.1)),
                    alignment: .top
                )
        )
    }

    private func checkPermissions() {
        let permissionManager = PermissionManager.shared
        if permissionManager.microphoneStatus != .granted {
            permissionManager.requestMicrophonePermission()
        }
        if permissionManager.accessibilityStatus != .granted {
            permissionManager.requestAccessibilityPermission()
        }
        if permissionManager.inputMonitoringStatus != .granted {
            permissionManager.openSystemSettings(for: .inputMonitoring)
        }
    }
}

// MARK: - Status Tab

struct StatusTabView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Permission warning banner (if needed)
            if !permissionManager.allPermissionsGranted {
                permissionWarningBanner
            }

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
                    color: .green
                )

                infoCard(
                    icon: "keyboard",
                    title: "Shortcut",
                    value: appState.keyListener?.shortcutConfig.displayString ?? "Fn",
                    detail: appState.keyListener?.shortcutConfig.recordingMode.displayName,
                    color: .purple
                )
            }

            // Usage hint
            VStack(alignment: .leading, spacing: 8) {
                Text("How to use")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    stepBadge(number: 1, text: "Hold shortcut")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    stepBadge(number: 2, text: "Speak")
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    stepBadge(number: 3, text: "Release")
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(10)
        }
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
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }

            Spacer()

            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    private func stepBadge(number: Int, text: String) -> some View {
        HStack(spacing: 6) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
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
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            // Show which permissions are missing
            HStack(spacing: 8) {
                if permissionManager.microphoneStatus != .granted {
                    missingPermissionBadge("Mic", icon: "mic.fill")
                }
                if permissionManager.accessibilityStatus != .granted {
                    missingPermissionBadge("Accessibility", icon: "accessibility")
                }
                if permissionManager.inputMonitoringStatus != .granted {
                    missingPermissionBadge("Keyboard", icon: "keyboard")
                }
            }

            Button(action: {
                // Request all missing permissions
                if permissionManager.microphoneStatus != .granted {
                    permissionManager.requestMicrophonePermission()
                }
                if permissionManager.accessibilityStatus != .granted {
                    permissionManager.requestAccessibilityPermission()
                }
                if permissionManager.inputMonitoringStatus != .granted {
                    permissionManager.openSystemSettings(for: .inputMonitoring)
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
        .background(Color.orange.opacity(0.1))
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
                icon: "star.fill",
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
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 12))

                    Text(title)
                        .font(.system(size: 12, weight: .semibold))

                    Spacer()

                    Image(systemName: expandedSection == sectionId ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Audio Settings - compact card
                settingsCard(title: "Audio", icon: "speaker.wave.2.fill", color: .orange) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Mute other audio")
                                .font(.system(size: 13, weight: .medium))
                            Text("Pause system audio while recording")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.muteOtherAudioDuringRecording)
                            .toggleStyle(.switch)
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

                // Keyboard Shortcut
                settingsCard(title: "Shortcut", icon: "keyboard", color: .purple) {
                    ShortcutRecorderView()
                }

                // History
                settingsCard(title: "History", icon: "clock.fill", color: .indigo) {
                    Button(action: {
                        HistoryWindowManager.shared.showWindow()
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("View transcription history")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Press Fn+S to toggle history window")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 13))
                                .foregroundColor(.accentColor)
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
            }

            // Content
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.08), lineWidth: 1)
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
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)

                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                            .font(.caption2)
                        Text("•")
                            .font(.caption2)
                        Text(model.speedDescription)
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.accentColor)
            }
        } else if isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14))
                Text("Download")
                    .font(.caption2)
            }
            .foregroundColor(.accentColor)
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
                    .foregroundColor(.secondary)
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
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 16, height: 16)

                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }

                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .primary : .secondary)

                Spacer()

                if let detail = detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
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
                            .foregroundColor(.primary)
                        Text(appState.selectedLanguage.displayName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
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
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))

                        TextField("Search languages...", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)

                    // Language list - show max 5 items (160px height)
                    if filteredLanguages.isEmpty {
                        Text("No languages found")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        .stroke(appState.selectedLanguage == language ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2)
                        .frame(width: 14, height: 14)

                    if appState.selectedLanguage == language {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }

                Text(language.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(appState.selectedLanguage == language ? .primary : .secondary)

                Spacer()

                if language == .auto {
                    Text("May be unreliable")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                } else if language == .english {
                    Text("Default")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
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
                            .foregroundColor(.primary)

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
                        .foregroundColor(.secondary)
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
                            .background(Color.accentColor)
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
                    .foregroundColor(status == .granted ? .primary : .secondary)

                Text(permission.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
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
        case .inputMonitoring:
            permissionManager.openSystemSettings(for: .inputMonitoring)
        }
    }

    private func requestAllPermissions() {
        if permissionManager.microphoneStatus != .granted {
            permissionManager.requestMicrophonePermission()
        }
        if permissionManager.accessibilityStatus != .granted {
            permissionManager.requestAccessibilityPermission()
        }
        if permissionManager.inputMonitoringStatus != .granted {
            permissionManager.openSystemSettings(for: .inputMonitoring)
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @State private var logFileSize: String = "..."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Log file info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log file")
                        .font(.system(size: 12, weight: .medium))
                    Text(logFileSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.12))
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
                .opacity(0.5)

            // Version info
            HStack {
                Text("Version")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(appVersion)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
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
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Whisperer")
                        .font(.system(size: 14, weight: .bold))

                    Text("Voice to Text for Mac")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)

                    Text(appVersion)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Links
            VStack(alignment: .leading, spacing: 10) {
                Text("Legal & Information")
                    .font(.system(size: 12, weight: .semibold))

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

            // Copyright
            Text("© 2026 Whisperer. All rights reserved.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Powered by whisper.cpp — 100% offline")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
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
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.05))
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
