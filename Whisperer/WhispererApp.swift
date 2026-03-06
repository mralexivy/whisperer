//
//  WhispererApp.swift
//  Whisperer
//
//  Main app entry point - menu bar app
//

import SwiftUI
import ServiceManagement

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
    var pickerPanel: TranscriptionPickerPanel?
    let appState = AppState.shared
    private var isShuttingDown = false
    private var rightClickMenu: NSMenu?
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("Application launched", subsystem: .app)

        // Setup right-click menu on the status bar icon
        setupStatusItemRightClickMenu()

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

        // Show onboarding window on first launch (pure UI, runs immediately)
        OnboardingWindowManager.shared.showIfNeeded()

        // Defer heavy service initialization to let MenuBarExtra complete initial layout.
        // Prevents potential EXC_BAD_ACCESS from AttributeGraph metadata processing
        // during concurrent service init and SwiftUI layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }

            self.setupComponents()
            self.setupOverlay()

            Task {
                await self.checkPermissions()
            }
        }
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

        pickerPanel = TranscriptionPickerPanel()
        // Panel manages its own visibility based on TranscriptionPickerState
    }

    private func checkPermissions() async {
        // Only request microphone on startup if onboarding is complete.
        // During onboarding, microphone is requested on the dedicated page.
        // Accessibility is requested only when user enables auto-paste.
        await MainActor.run {
            let permissionManager = PermissionManager.shared

            if appState.hasCompletedOnboarding && permissionManager.microphoneStatus != .granted {
                permissionManager.requestMicrophonePermission()
            }
        }

        // Only auto-download/preload if onboarding is complete.
        // During onboarding, the model download page (page 5) handles this.
        let onboardingDone = await MainActor.run { appState.hasCompletedOnboarding }
        if onboardingDone {
            let selectedModel = await MainActor.run { appState.selectedModel }
            if !ModelDownloader.shared.isModelDownloaded(selectedModel) {
                await appState.downloadModel(selectedModel)
            } else {
                await MainActor.run {
                    self.appState.preloadModel()
                }
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

    // MARK: - Status Item Right-Click Menu

    private func setupStatusItemRightClickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Whisperer", action: #selector(quitApp), keyEquivalent: "q")
        self.rightClickMenu = menu

        // Monitor right-click on the status bar area
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseUp]) { [weak self] event in
            guard let self = self,
                  let button = event.window?.contentView?.hitTest(event.locationInWindow),
                  button is NSStatusBarButton else {
                return event
            }
            self.rightClickMenu?.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
            return nil
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
        case .settings: return .red
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

enum SettingsScrollTarget: String {
    case dictation
    case microphone
    case livePreview
}

struct MenuBarView: View {
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared
    @State private var selectedTab: MenuTab = .status
    @State private var settingsScrollTarget: SettingsScrollTarget?
    @State private var showAboutPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient
            headerView

            // Tab bar
            tabBar

            // Content area - scrollable
            ScrollView(showsIndicators: false) {
                tabContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }

            // Footer
            footerView
        }
        .frame(width: 360, height: 580)
        .tahoeTextFix()
        .background(MBColors.background)
        .background(MenuBarWindowConfigurator())
        .environment(\.colorScheme, .dark)
        .onAppear {
            PermissionManager.shared.recheckAccessibilityIfNeeded()
        }
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

                // About button
                Button(action: { showAboutPopover.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(MBColors.accent)
                            .font(.system(size: 12))
                        Text("About")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(MBColors.textPrimary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(MBColors.pill)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAboutPopover, arrowEdge: .top) {
                    AboutPopoverContent()
                        .frame(width: 320)
                        .background(MBColors.background)
                        .environment(\.colorScheme, .dark)
                }
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
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .status:
            StatusTabView(selectedTab: $selectedTab, settingsScrollTarget: $settingsScrollTarget)
        case .models:
            ModelsTabView()
        case .settings:
            SettingsTabView(scrollTarget: $settingsScrollTarget)
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
    @Binding var selectedTab: MenuTab
    @Binding var settingsScrollTarget: SettingsScrollTarget?
    @ObservedObject var appState = AppState.shared
    @ObservedObject var permissionManager = PermissionManager.shared

    /// Whether to show permission warnings (mode-aware)
    private var showPermissionWarning: Bool {
        if permissionManager.microphoneStatus != .granted { return true }
        if appState.autoPasteEnabled && permissionManager.accessibilityStatus != .granted { return true }
        return false
    }

    private var activeModelName: String {
        switch appState.selectedBackendType {
        case .whisperCpp: return appState.selectedModel.displayName
        case .parakeet: return appState.selectedParakeetModel.displayName
        case .speechAnalyzer: return "On-Device"
        }
    }

    private var activeModelDetail: String? {
        switch appState.selectedBackendType {
        case .whisperCpp: return appState.selectedModel.sizeDescription
        case .parakeet: return nil
        case .speechAnalyzer: return nil
        }
    }

    private var activeModelColor: Color {
        switch appState.selectedBackendType {
        case .whisperCpp: return .blue
        case .parakeet: return .green
        case .speechAnalyzer: return .cyan
        }
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
                        icon: appState.selectedBackendType.iconName,
                        title: appState.selectedBackendType.displayName,
                        value: activeModelName,
                        detail: activeModelDetail,
                        color: activeModelColor,
                        navigateTo: .models
                    )

                    infoCard(
                        icon: "mic",
                        title: "Microphone",
                        value: AudioDeviceManager.shared.selectedDevice?.name ?? "System Default",
                        detail: nil,
                        color: .cyan,
                        navigateTo: .settings,
                        scrollTo: .microphone
                    )

                    infoCard(
                        icon: "text.bubble",
                        title: "Live Preview",
                        value: appState.liveTranscriptionEnabled ? "On" : "Off",
                        detail: nil,
                        color: .purple,
                        navigateTo: .settings,
                        scrollTo: .livePreview
                    )

                }

                // System-Wide Dictation card with toggle and shortcut flow
                systemWideDictationCard
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

    private func infoCard(icon: String, title: String, value: String, detail: String?, color: Color, navigateTo tab: MenuTab, scrollTo target: SettingsScrollTarget? = nil) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                settingsScrollTarget = target
                selectedTab = tab
            }
        } label: {
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

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MBColors.textTertiary)
            }
            .padding(12)
            .background(MBColors.cardSurface)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MBColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }

    }

    private var systemWideDictationCard: some View {
        let isEnabled = appState.systemWideDictationEnabled
        let shortcutKey = appState.keyListener?.shortcutConfig.displayString ?? "Fn"

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                settingsScrollTarget = .dictation
                selectedTab = .settings
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: "globe")
                        .font(.system(size: 16))
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("System-Wide Dictation")
                        .font(.caption)
                        .foregroundColor(MBColors.textTertiary)
                    if isEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("\(shortcutKey) → Speak → Release", systemImage: "mic.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Label("⌥+V", systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                        }
                    } else {
                        Text("Disabled")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(MBColors.textPrimary)
                    }
                }

                Spacer()

                Text(isEnabled ? "On" : "Off")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isEnabled ? .green : MBColors.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((isEnabled ? Color.green : Color.white).opacity(0.1))
                    .cornerRadius(6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(MBColors.textTertiary)
            }
            .padding(12)
            .background(MBColors.cardSurface)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(MBColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
                // Only show Accessibility as missing when auto-paste is enabled
                if appState.autoPasteEnabled && permissionManager.accessibilityStatus != .granted {
                    missingPermissionBadge("Accessibility", icon: "accessibility")
                }
            }

            Button(action: {
                if permissionManager.microphoneStatus != .granted {
                    permissionManager.requestMicrophonePermission()
                }
                if appState.autoPasteEnabled && permissionManager.accessibilityStatus != .granted {
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
            // Language picker — here because language support depends on the selected engine
            languageSection

            // Engine picker + models
            engineSection
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Engine header + segmented control
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "cpu")
                        .foregroundColor(.purple)
                        .font(.system(size: 12, weight: .medium))
                }

                Text("Engine")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()
            }

            HStack(spacing: 0) {
                ForEach(Array(BackendType.allCases.enumerated()), id: \.element.id) { index, backend in
                    let isSelected = appState.selectedBackendType == backend

                    Button(action: {
                        appState.selectBackend(backend)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: backend.iconName)
                                .font(.system(size: 10, weight: .medium))
                            Text(backend.displayName)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(isSelected ? .white : MBColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? MBColors.accent : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(MBColors.elevated.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(MBColors.border, lineWidth: 1)
            )

            // Models for selected engine
            if appState.selectedBackendType == .whisperCpp {
                modelSection(
                    title: "Recommended",
                    icon: "sparkles",
                    color: MBColors.accent,
                    models: [.largeTurboQ5],
                    sectionId: "recommended"
                )

                modelSection(
                    title: "Turbo & Optimized",
                    icon: "bolt.fill",
                    color: .orange,
                    models: [.largeTurbo, .largeV3Q5],
                    sectionId: "turbo"
                )

                modelSection(
                    title: "Standard",
                    icon: "cube.fill",
                    color: .blue,
                    models: [.tiny, .base, .small, .medium, .largeV3],
                    sectionId: "standard"
                )

                modelSection(
                    title: "Distilled",
                    icon: "wand.and.stars",
                    color: .red,
                    models: WhisperModel.allCases.filter { $0.isDistilled },
                    sectionId: "distilled"
                )
            } else if appState.selectedBackendType == .parakeet {
                parakeetModelSection
            } else if appState.selectedBackendType == .speechAnalyzer {
                speechAnalyzerSection
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

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "globe")
                        .foregroundColor(.blue)
                        .font(.system(size: 12, weight: .medium))
                }

                Text("Language")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)
            }

            LanguagePickerView()
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

    private var parakeetModelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "bird.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12, weight: .medium))
                }

                Text("Parakeet Models")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()
            }

            VStack(spacing: 4) {
                ForEach(ParakeetModelVariant.allCases) { model in
                    ParakeetModelRow(model: model)
                }
            }

            if appState.isDownloadingParakeet || appState.isLoadingParakeet {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text(appState.parakeetDownloadStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(MBColors.textSecondary)
                    }

                    if appState.isDownloadingParakeet {
                        // Indeterminate progress bar
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(MBColors.accent)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    private var speechAnalyzerSection: some View {
        let isActive = appState.isModelLoaded && appState.selectedBackendType == .speechAnalyzer
        let isLoading = appState.isLoadingSpeechAnalyzer
        let isHighlighted = isActive || isLoading

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "apple.logo")
                        .foregroundColor(.cyan)
                        .font(.system(size: 12, weight: .medium))
                }

                Text("Apple Speech")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()
            }

            // Clickable model row
            Button(action: {
                if !isActive && !isLoading {
                    appState.preloadModel()
                }
            }) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-Device Model")
                            .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                            .foregroundColor(isHighlighted ? MBColors.textPrimary : MBColors.textSecondary)

                        Text("System-managed \u{2022} macOS 26+")
                            .font(.caption2)
                            .foregroundColor(MBColors.textTertiary)
                    }

                    Spacer()

                    if isLoading {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                            Text("Loading")
                                .font(.caption2)
                                .foregroundColor(MBColors.accent)
                        }
                    } else if isActive {
                        Text("Active")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(MBColors.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(MBColors.accent.opacity(0.15)))
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHighlighted ? MBColors.accent.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isHighlighted ? MBColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
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
                VStack(spacing: 4) {
                    ForEach(models, id: \.self) { model in
                        ModelMenuItem(model: model)
                    }
                }
            }
        }
    }
}

// MARK: - Settings Tab

struct SettingsTabView: View {
    @Binding var scrollTarget: SettingsScrollTarget?
    @ObservedObject var appState = AppState.shared

    var body: some View {
        ScrollViewReader { proxy in
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

                            Toggle("", isOn: $appState.systemWideDictationEnabled)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                        }

                        if appState.systemWideDictationEnabled {
                            // Shortcut recorder inline
                            ShortcutRecorderView()

                            HStack(spacing: 8) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.cyan.opacity(0.15))
                                        .frame(width: 24, height: 24)
                                    Image(systemName: "doc.on.doc.fill")
                                        .foregroundColor(.cyan)
                                        .font(.system(size: 10, weight: .medium))
                                }

                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Quick Paste")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(MBColors.textPrimary)
                                    Text("Access recent transcriptions instantly")
                                        .font(.system(size: 10))
                                        .foregroundColor(MBColors.textSecondary)
                                }

                                Spacer()

                                Text("⌥+V")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.6))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(5)
                            }
                            .padding(8)
                            .background(MBColors.accent.opacity(0.06))
                            .cornerRadius(6)
                        } else {
                            Text("Enable to hold a shortcut key and dictate text into any app.")
                                .font(.system(size: 10))
                                .foregroundColor(MBColors.textSecondary)
                                .padding(8)
                                .background(MBColors.accent.opacity(0.08))
                                .cornerRadius(6)
                        }
                    }
                }
                .id(SettingsScrollTarget.dictation)

                // Auto-Paste
                settingsCard(title: "Auto-Paste", icon: "doc.on.clipboard", color: .purple) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Auto-paste text")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(MBColors.textPrimary)
                                Text(appState.autoPasteEnabled
                                     ? "Text is pasted automatically where you type"
                                     : "Text is copied to clipboard — press ⌘V to paste")
                                    .font(.system(size: 11))
                                    .foregroundColor(MBColors.textSecondary)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { appState.autoPasteEnabled },
                                set: { newValue in
                                    appState.autoPasteEnabled = newValue
                                    if newValue && PermissionManager.shared.accessibilityStatus != .granted {
                                        PermissionManager.shared.requestAccessibilityPermission()
                                    }
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
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

                // Live Preview
                settingsCard(title: "Live Preview", icon: "text.bubble", color: .purple) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Show live transcription")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Display words as you speak")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.liveTranscriptionEnabled)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                    }
                }
                .id(SettingsScrollTarget.livePreview)

                // Prompt Words
                settingsCard(title: "Prompt Words", icon: "text.word.spacing", color: .cyan) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Recognition hints")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(MBColors.textPrimary)
                                Text("Bias transcription toward specific words (\(appState.promptWords.count) words)")
                                    .font(.system(size: 11))
                                    .foregroundColor(MBColors.textSecondary)
                            }

                            Spacer()

                            Toggle("", isOn: $appState.promptWordsEnabled)
                                .toggleStyle(.switch)
                                .tint(MBColors.accent)
                                .labelsHidden()
                        }

                        if !appState.promptWords.isEmpty && appState.promptWordsEnabled {
                            FlowLayout(spacing: 5) {
                                ForEach(appState.promptWords.prefix(12), id: \.self) { word in
                                    Text(word)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(MBColors.textSecondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Capsule().fill(MBColors.accent.opacity(0.12)))
                                }
                                if appState.promptWords.count > 12 {
                                    Text("+\(appState.promptWords.count - 12) more")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(MBColors.textTertiary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                }
                            }
                        }
                    }
                }

                // Vocabulary Boosting (Parakeet CTC rescoring)
                settingsCard(title: "Vocabulary Boosting", icon: "text.magnifyingglass", color: .green) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("CTC rescoring")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Boost dictionary terms in Parakeet final pass")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.vocabularyBoostingEnabled)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                            .disabled(appState.selectedBackendType != .parakeet)
                    }
                }

                // Filler Word Removal
                settingsCard(title: "Filler Words", icon: "text.redaction", color: .orange) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Remove filler words")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Strip um, uh, er from output")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.fillerWordRemovalEnabled)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                    }
                }

                // Add Space After Text
                settingsCard(title: "Text Output", icon: "character.cursor.ibeam", color: .teal) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Add space after text")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Insert a trailing space so you can keep typing")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.appendTrailingSpace)
                            .toggleStyle(.switch)
                            .tint(MBColors.accent)
                            .labelsHidden()
                    }
                }

                // Launch at Login
                settingsCard(title: "Launch at Login", icon: "arrow.right.to.line", color: .cyan) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Start automatically")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(MBColors.textPrimary)
                            Text("Launch Whisperer when you log in")
                                .font(.system(size: 11))
                                .foregroundColor(MBColors.textSecondary)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { SMAppService.mainApp.status == .enabled },
                            set: { newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    Logger.error("Launch at login failed: \(error.localizedDescription)", subsystem: .app)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .tint(MBColors.accent)
                        .labelsHidden()
                    }
                }

                // Microphone Settings
                settingsCard(title: "Microphone", icon: "mic.fill", color: .green) {
                    MicrophonePickerView()
                }
                .id(SettingsScrollTarget.microphone)

                // Permissions
                settingsCard(title: "Permissions", icon: "lock.shield.fill", color: .red) {
                    PermissionsView()
                }

                // AI Post-Processing
                settingsCard(title: "AI Post-Processing", icon: "sparkles", color: .purple) {
                    LLMSettingsView()
                }

                // Diagnostics
                settingsCard(title: "Diagnostics", icon: "ladybug.fill", color: .gray) {
                    DiagnosticsView()
                }

            }
            }
            .onAppear {
                if let target = scrollTarget {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        scrollTarget = nil
                    }
                }
            }
            .onChange(of: scrollTarget) { target in
                if let target = target {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scrollTarget = nil
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

    var isActive: Bool { appState.selectedModel == model && appState.isModelLoaded && appState.selectedBackendType == .whisperCpp }
    var isHighlighted: Bool { isActive }
    var isSelected: Bool { appState.selectedModel == model }
    var isDownloaded: Bool { appState.isModelDownloaded(model) }
    var isDownloading: Bool { appState.downloadingModel == model }

    var body: some View {
        Button(action: { handleTap() }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                        .foregroundColor(isHighlighted ? MBColors.textPrimary : MBColors.textSecondary)

                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                            .font(.caption2)
                        Text("\u{2022}")
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
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? MBColors.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHighlighted ? MBColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .disabled(isDownloading || appState.downloadingModel != nil)
    }

    @ViewBuilder var statusBadge: some View {
        if isDownloading {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.5)
                    Text("\(Int(appState.downloadProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(MBColors.accent)
                }
                if let retryInfo = appState.downloadRetryInfo {
                    Text(retryInfo)
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }
        } else if isActive {
            Text("Active")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(MBColors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(MBColors.accent.opacity(0.15)))
        } else if isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(MBColors.accent.opacity(0.5))
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

// MARK: - Parakeet Model Row

struct ParakeetModelRow: View {
    let model: ParakeetModelVariant
    @ObservedObject var appState = AppState.shared

    var isActive: Bool { appState.selectedParakeetModel == model && appState.isModelLoaded && appState.selectedBackendType == .parakeet }
    var isLoading: Bool { appState.selectedParakeetModel == model && appState.selectedBackendType == .parakeet && (appState.isDownloadingParakeet || appState.isLoadingParakeet) }
    var isHighlighted: Bool { isActive || isLoading }
    var isSelected: Bool { appState.selectedParakeetModel == model }
    var isCached: Bool { appState.isParakeetModelCached(model) }

    var body: some View {
        Button(action: {
            if isCached {
                appState.selectParakeetModel(model)
            } else {
                appState.downloadParakeetModel(model)
            }
        }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 12, weight: isHighlighted ? .semibold : .regular))
                        .foregroundColor(isHighlighted ? MBColors.textPrimary : MBColors.textSecondary)

                    Text(model.languageDescription)
                        .font(.caption2)
                        .foregroundColor(MBColors.textTertiary)
                }
        

                Spacer()

                if isLoading {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                        Text("Loading")
                            .font(.caption2)
                            .foregroundColor(MBColors.accent)
                    }
                } else if isActive {
                    Text("Active")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(MBColors.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(MBColors.accent.opacity(0.15)))
                } else if isCached {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(MBColors.accent.opacity(0.5))
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
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHighlighted ? MBColors.accent.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isHighlighted ? MBColors.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .disabled(appState.isDownloadingParakeet)
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

                        if let hint = appState.languageCompatibilityHint {
                            HStack(spacing: 5) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.orange)
                                Text(hint)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.orange.opacity(0.85))
                                    .lineLimit(2)
                            }
                            .padding(.top, 2)
                        }
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
                } else if appState.selectedBackendType != .whisperCpp && !appState.selectedBackendType.supportsLanguage(
                    language,
                    parakeetVariant: appState.selectedParakeetModel,
                    speechAnalyzerLanguageCodes: appState.speechAnalyzerSupportedLanguageCodes
                ) {
                    Text("Unsupported")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.7))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
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
    @ObservedObject var appState = AppState.shared
    @State private var isExpanded = false

    private var visiblePermissions: [PermissionType] {
        return [.microphone, .accessibility]
    }

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

                        if permissionManager.microphoneStatus == .granted && (!appState.autoPasteEnabled || permissionManager.accessibilityStatus == .granted) {
                            Text(appState.autoPasteEnabled ? "All permissions granted" : "Microphone granted · Accessibility optional")
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
                    if permissionManager.microphoneStatus == .granted && (!appState.autoPasteEnabled || permissionManager.accessibilityStatus == .granted) {
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

                    ForEach(visiblePermissions, id: \.self) { permission in
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
        let isAccessibilityNotRequired = permission == .accessibility && !appState.autoPasteEnabled

        return HStack(spacing: 10) {
            // Icon
            Image(systemName: permission.icon)
                .foregroundColor(isAccessibilityNotRequired ? MBColors.textTertiary : (status == .granted ? .green : .orange))
                .font(.system(size: 12))
                .frame(width: 20)

            // Name and description
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isAccessibilityNotRequired ? MBColors.textTertiary : (status == .granted ? MBColors.textPrimary : MBColors.textSecondary))

                Text(isAccessibilityNotRequired ? "Enable Auto-Paste to use" : permission.description)
                    .font(.system(size: 10))
                    .foregroundColor(MBColors.textTertiary)
            }

            Spacer()

            // Status badge
            if isAccessibilityNotRequired {
                Text("Optional")
                    .font(.caption2)
                    .foregroundColor(MBColors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(4)
            } else if status == .granted {
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
        if appState.autoPasteEnabled && permissionManager.accessibilityStatus != .granted {
            permissionManager.requestAccessibilityPermission()
        }
    }
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @State private var logFileSize: String = "..."
    @State private var verboseLogging: Bool = Logger.isVerbose

    private let diagnosticSubsystems: [LogSubsystem] = [.audio, .transcription, .textInjection, .model]

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
                    Text("Today's log")
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

            // Per-subsystem debug channels
            VStack(alignment: .leading, spacing: 6) {
                Text("Debug Channels")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                Text("Enable debug logs for specific subsystems")
                    .font(.system(size: 11))
                    .foregroundColor(MBColors.textSecondary)

                ForEach(diagnosticSubsystems, id: \.self) { subsystem in
                    SubsystemToggleRow(subsystem: subsystem)
                }
            }

            Divider()
                .opacity(0.3)

            // SpeechAnalyzer test (macOS 26+)
            if #available(macOS 26.0, *) {
                SpeechAnalyzerTestSection()
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

private struct SubsystemToggleRow: View {
    let subsystem: LogSubsystem
    @State private var isVerbose: Bool

    init(subsystem: LogSubsystem) {
        self.subsystem = subsystem
        self._isVerbose = State(initialValue: Logger.isSubsystemVerbose(subsystem))
    }

    var body: some View {
        HStack {
            Text(subsystem.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(MBColors.textSecondary)
            Spacer()
            Toggle("", isOn: $isVerbose)
                .toggleStyle(.switch)
                .tint(MBColors.accent)
                .labelsHidden()
                .controlSize(.mini)
                .onChange(of: isVerbose) { _, newValue in
                    Logger.setSubsystemVerbose(newValue, for: subsystem)
                }
        }
    }
}

// MARK: - SpeechAnalyzer Test Section

@available(macOS 26.0, *)
private struct SpeechAnalyzerTestSection: View {
    @StateObject private var diagnostics = SpeechAnalyzerDiagnostics()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SpeechAnalyzer Test")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()

                Button(action: { diagnostics.runDiagnostics() }) {
                    HStack(spacing: 4) {
                        if diagnostics.isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                        }
                        Text(diagnostics.isRunning ? "Running..." : "Run Test")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(MBColors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(MBColors.pill)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(diagnostics.isRunning)
            }

            if !diagnostics.status.isEmpty {
                Text(diagnostics.status)
                    .font(.system(size: 11))
                    .foregroundColor(MBColors.textSecondary)
            }

            ForEach(diagnostics.results) { result in
                HStack(spacing: 6) {
                    Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.passed ? .green : .red)
                        .font(.system(size: 10))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.actualText.isEmpty ? "[empty]" : result.actualText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(MBColors.textPrimary)
                            .lineLimit(1)
                        Text("\(String(format: "%.1f", result.duration))s, \(String(format: "%.0f", result.latencyMs))ms")
                            .font(.system(size: 9.5))
                            .foregroundColor(MBColors.textSecondary)
                    }
                }
            }
        }
    }
}

// MARK: - About Popover

struct AboutPopoverContent: View {
    @ObservedObject var storeManager = StoreManager.shared
    @State private var isLoadingProducts = false

    private static let accent = Color(red: 0.357, green: 0.424, blue: 0.969)
    private static let accentPurple = Color(red: 0.545, green: 0.361, blue: 0.965)

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header with gradient background
                headerSection
                    .padding(16)
                    .background(
                        LinearGradient(
                            colors: [Self.accent.opacity(0.08), Self.accentPurple.opacity(0.04), Color.clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Pro section
                proSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                // Thin separator
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.horizontal, 16)

                // Links + copyright
                VStack(alignment: .leading, spacing: 10) {
                    linksSection

                    Text("© 2026 Whisperer. All rights reserved.")
                        .font(.system(size: 10))
                        .foregroundColor(MBColors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
                .padding(16)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Self.accent.opacity(0.25), Self.accentPurple.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                LinearGradient(colors: [Self.accent.opacity(0.3), Self.accentPurple.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 1
                            )
                    )

                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [Self.accent, Self.accentPurple], startPoint: .leading, endPoint: .trailing)
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Whisperer")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(MBColors.textPrimary)

                    Text(storeManager.isPro ? "Pro" : "Basic")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .textCase(.uppercase)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                storeManager.isPro
                                    ? LinearGradient(colors: [.green, .green.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                                    : LinearGradient(colors: [Self.accent, Self.accentPurple], startPoint: .leading, endPoint: .trailing)
                            )
                        )
                }

                Text("Offline Voice Transcription")
                    .font(.system(size: 11))
                    .foregroundColor(MBColors.textSecondary)

                Text(appVersion)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(MBColors.textTertiary)
            }

            Spacer()
        }
    }

    // MARK: - Pro Section

    private var proSection: some View {
        Group {
            if storeManager.isPro {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 18))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pro Pack Active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(MBColors.textPrimary)
                        Text("All Pro features unlocked — thank you!")
                            .font(.system(size: 11))
                            .foregroundColor(MBColors.textSecondary)
                    }

                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.green.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.green.opacity(0.15), lineWidth: 1)
                        )
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // Feature list with per-element colorful icons
                    VStack(alignment: .leading, spacing: 8) {
                        proFeatureRow(icon: "keyboard", color: .orange, title: "Code Mode", description: "Speak parentheses, brackets, and use casing commands")
                        proFeatureRow(icon: "app.badge", color: .cyan, title: "Per-App Profiles", description: "Auto-switch settings for Slack, VS Code, and more")
                        proFeatureRow(icon: "book.closed", color: .green, title: "Personal Dictionary", description: "Custom words, names, and technical terms")
                        proFeatureRow(icon: "arrow.up.doc", color: .indigo, title: "Pro Text Entry", description: "Clipboard-safe paste with app-specific fallbacks")
                    }

                    // Purchase button
                    Button(action: {
                        Task {
                            if storeManager.products.isEmpty {
                                isLoadingProducts = true
                                await storeManager.loadProducts()
                                isLoadingProducts = false
                            }
                            if !storeManager.products.isEmpty {
                                try? await storeManager.purchase()
                            }
                        }
                    }) {
                        HStack(spacing: 8) {
                            if storeManager.isPurchasing || isLoadingProducts {
                                ProgressView()
                                    .scaleEffect(0.7)
                            }

                            Text(storeManager.isPurchasing ? "Processing..." : isLoadingProducts ? "Loading..." : "Upgrade to Pro")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer()

                            if let price = storeManager.proPackPrice, !storeManager.isPurchasing && !isLoadingProducts {
                                Text(price)
                                    .font(.system(size: 13, weight: .bold))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(
                                colors: [Self.accent, Self.accentPurple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(10)
                        .shadow(color: Self.accent.opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(storeManager.isPurchasing || isLoadingProducts)

                    // Restore + one-time note
                    HStack {
                        Button(action: {
                            Task { await storeManager.restorePurchases() }
                        }) {
                            Text("Restore Purchases")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(Self.accent)
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                            Text("One-time purchase")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(MBColors.textTertiary)
                    }

                    // Error
                    if let error = storeManager.errorMessage {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundColor(.red)
                            .padding(8)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(6)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(MBColors.cardSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    LinearGradient(
                                        colors: [Self.accent.opacity(0.2), Self.accentPurple.opacity(0.2), MBColors.border],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                )
            }
        }
    }

    // MARK: - Links

    private var linksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            linkButton(icon: "hand.raised", color: .orange, title: "Privacy Policy") {
                if let url = URL(string: "https://whispererapp.com/privacy") {
                    NSWorkspace.shared.open(url)
                }
            }

            linkButton(icon: "globe", color: .blue, title: "Website") {
                if let url = URL(string: "https://whispererapp.com") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func linkButton(icon: String, color: Color, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color.opacity(0.15))
                        .frame(width: 22, height: 22)
                    Image(systemName: icon)
                        .foregroundColor(color)
                        .font(.system(size: 10, weight: .medium))
                }

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(MBColors.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(MBColors.elevated.opacity(0.5))
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func proFeatureRow(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.system(size: 12, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(MBColors.textPrimary)
                Text(description)
                    .font(.system(size: 10.5))
                    .foregroundColor(MBColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - About View (used in workspace window)

struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (Build \(build))"
    }
}

// MARK: - LLM Settings View

struct LLMSettingsView: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Enable toggle
            HStack {
                Text("Post-process with AI")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(MBColors.textPrimary)
                Spacer()
                Toggle("", isOn: $appState.llmEnabled)
                    .toggleStyle(.switch)
                    .tint(MBColors.accent)
                    .labelsHidden()
            }

            if appState.llmEnabled {
                // Model picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(MBColors.textSecondary)

                    ForEach(LLMModelVariant.allCases) { variant in
                        Button(action: {
                            appState.selectedLLMModel = variant
                        }) {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .stroke(appState.selectedLLMModel == variant ? MBColors.accent : MBColors.textTertiary, lineWidth: 2)
                                        .frame(width: 14, height: 14)
                                    if appState.selectedLLMModel == variant {
                                        Circle()
                                            .fill(MBColors.accent)
                                            .frame(width: 8, height: 8)
                                    }
                                }

                                Text(variant.displayName)
                                    .font(.system(size: 11, weight: appState.selectedLLMModel == variant ? .semibold : .regular))
                                    .foregroundColor(appState.selectedLLMModel == variant ? MBColors.textPrimary : MBColors.textSecondary)

                                Spacer()

                                Text(variant.sizeDescription)
                                    .font(.caption2)
                                    .foregroundColor(MBColors.textTertiary)

                                Text(variant.speedDescription)
                                    .font(.caption2)
                                    .foregroundColor(MBColors.accent.opacity(0.8))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Task picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(MBColors.textSecondary)

                    HStack(spacing: 6) {
                        ForEach(LLMTask.allCases) { task in
                            Button(action: {
                                appState.selectedLLMTask = task
                            }) {
                                Text(task.displayName)
                                    .font(.system(size: 10, weight: appState.selectedLLMTask == task ? .semibold : .medium))
                                    .foregroundColor(appState.selectedLLMTask == task ? .white : MBColors.textSecondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(appState.selectedLLMTask == task ? MBColors.accent : Color.clear)
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(appState.selectedLLMTask == task ? Color.clear : MBColors.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Custom prompt field
                if appState.selectedLLMTask == .custom {
                    TextField("Custom prompt...", text: $appState.llmCustomPrompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(MBColors.textPrimary)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(MBColors.elevated)
                        )
                }

                // Translation language
                if appState.selectedLLMTask == .translate {
                    HStack {
                        Text("Target language")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(MBColors.textSecondary)
                        Spacer()
                        TextField("English", text: $appState.llmTranslateLanguage)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundColor(MBColors.textPrimary)
                            .frame(width: 100)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(MBColors.elevated)
                            )
                    }
                }

                // Load/status button
                if let processor = appState.llmPostProcessor, processor.isModelLoaded {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 12))
                        Text("\(appState.selectedLLMModel.displayName) loaded")
                            .font(.caption2)
                            .foregroundColor(MBColors.textSecondary)
                    }
                } else {
                    Button(action: {
                        appState.preloadLLM()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 12))
                            Text("Load Model")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(MBColors.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
