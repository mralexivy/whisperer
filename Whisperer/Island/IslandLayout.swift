//
//  IslandLayout.swift
//  Whisperer
//
//  The live-activity chain — three-tier layout for the bottom-anchored Island.
//
//  Tier routing by vm.presentation:
//   .peek     → peekBody  (pulsing dot + level glow, ~120×10 pt)
//   .compact  → compactBody (state-branching recording/status rows)
//   .expanded → compactBody + secondaryRow
//
//  Compact recording row (always visible while recording):
//    [● pulse] [~~~waveform~~~] [0:06] [⏸ pause] [■ stop]
//
//  Expanded secondary row (added by tap / hover dwell / scroll):
//    [🎤 Mic] [🔈 Speaker] [↗ Open]
//
//  There is no camera-housing dead zone — the Island is bottom-anchored with no notch.
//

import SwiftUI

// MARK: - Root layout view

struct IslandLayout: View {

    @ObservedObject var coordinator: IslandCoordinator
    @ObservedObject var levelBridge: IslandLevelBridge
    @ObservedObject var clock: IslandElapsedTimer

    /// Row metrics for the compact strip.
    var metrics: IslandRowMetrics

    /// True while the idle Island is resting as the handle rather than the launcher row.
    var isIdleHandle: Bool = false

    private var vm: IslandViewModel    { coordinator.currentViewModel }
    private var isExpanded: Bool       { vm.presentation == .expanded }
    private var isPeek: Bool           { vm.presentation == .peek }
    private var isVertical: Bool       { coordinator.placement.isVertical }
    private var isHovering: Bool       { coordinator.isHovering }

    // Swap transition between capture states
    private var swapTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.965, anchor: .center))
                .animation(.spring(response: 0.34, dampingFraction: 0.88)),
            removal:   .opacity.combined(with: .scale(scale: 0.92, anchor: .center))
                .animation(.smooth(duration: 0.22))
        )
    }

    var body: some View {
        if isIdleHandle {
            handleBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isPeek {
            peekBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isVertical {
            verticalStack
        } else {
            horizontalStack
        }
    }

    // MARK: - Tier stacks
    //
    // The compact strip must always be sized on the pill's THICK axis, and the expanded
    // controls must grow along it. For a horizontal pill the thick axis is height, so the
    // strip is framed by height and the secondary row stacks under it. For a vertical pill
    // the thick axis is width — framing that one by height instead squeezed the 147 pt
    // four-glyph launcher column into a 32 pt slot, and `.clipped()` then ate the first two
    // glyphs. That is why left/right placement was showing only Paste Bin and Workspace.

    private var horizontalStack: some View {
        VStack(spacing: 0) {
            compactBody
                .frame(height: IslandContentSizer.compactHeight(for: vm.capture))

            if isExpanded {
                secondaryRow
                    .frame(maxWidth: .infinity)
                    .frame(height: IslandContentSizer.expandedExtraHeight)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(IC.secondary.opacity(0.16))
                            .frame(height: 1)
                            .padding(.horizontal, 18)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// Vertical pill. The strip hugs the anchored edge and the controls open inward, which
    /// is the direction `IslandContentSizer` actually grows the pill: leftCenter widens
    /// rightward, rightCenter widens leftward.
    private var verticalStack: some View {
        let anchorTrailing = coordinator.placement == .rightCenter
        return HStack(spacing: 0) {
            if anchorTrailing, isExpanded { verticalSecondary }

            compactBody
                .frame(width: IslandContentSizer.compactHeight(for: vm.capture))

            if !anchorTrailing, isExpanded { verticalSecondary }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: anchorTrailing ? .trailing : .leading)
        .clipped()
    }

    private var verticalSecondary: some View {
        let anchorTrailing = coordinator.placement == .rightCenter
        return secondaryRow
            .frame(maxHeight: .infinity)
            .frame(width: IslandContentSizer.expandedExtraHeight)
            .overlay(alignment: anchorTrailing ? .trailing : .leading) {
                Rectangle()
                    .fill(IC.secondary.opacity(0.16))
                    .frame(width: 1)
                    .padding(.vertical, 18)
            }
            .transition(.opacity.combined(
                with: .move(edge: anchorTrailing ? .leading : .trailing)))
    }

    // MARK: - Idle handle (always-on resting affordance)

    /// The resting state is an empty solid capsule — no glyph, no line, no progress track.
    ///
    /// The iPhone Dynamic Island at rest is a single unbroken shape; anything drawn inside it
    /// at this size (a hairline, a dwell bar) reads as a scrollbar grabber rather than a
    /// surface waiting to open. The surface itself carries the whole affordance, and
    /// `IslandContentView` handles the tonal hover response.
    private var handleBody: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // MARK: - Peek body (recording only — idle always shows the compact launcher bar)

    private var peekBody: some View { recordingNubBody }

    private var recordingNubBody: some View {
        HStack(spacing: 8) {
            RecordingDot(isPaused: vm.isPaused)

            PeekLevelMeter(level: levelBridge.peekLevel,
                           isPaused: vm.isPaused || vm.isMicMuted)
                .frame(maxWidth: .infinity)

            Text(clock.displayText)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(IC.primary.opacity(0.82))
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: clock.displayText)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Compact body (state-branching)

    @ViewBuilder
    private var compactBody: some View {
        switch vm.capture {
        case .recording:
            recordingRow(isPaused: false).transition(swapTransition)
        case .paused:
            recordingRow(isPaused: true).transition(swapTransition)
        case .starting:
            statusRow(IslandProgressRule(tint: IC.accent,
                                         label: vm.statusLabel.isEmpty ? "Starting…" : vm.statusLabel,
                                         fraction: vm.preparationProgress))
                .transition(swapTransition)
        case .permissionRequired:
            statusRow(permissionRow).transition(swapTransition)
        case .finalizing:
            statusRow(IslandProgressRule(tint: IC.processing, label: "Finishing…", fraction: nil))
                .transition(swapTransition)
        case .failed(let msg):
            statusRow(failedRow(msg)).transition(swapTransition)
        case .idle:
            idleLauncherRow.transition(swapTransition)
        }
    }

    // MARK: - Idle launcher row

    /// Four bare glyphs, grouped: the two that *start* a capture, a hairline, then the two
    /// that *open* a surface. Horizontal by default; stacks vertically for left/right placements.
    private var idleLauncherRow: some View {
        Group {
            if isVertical {
                VStack(spacing: 2) { launcherItems }
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 2) { launcherItems }
                    .padding(.horizontal, 8)
                    .environment(\.layoutDirection, .leftToRight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var launcherItems: some View {
        launcherItem(
            icon: "mic.fill",
            title: "Dictate",
            tint: IC.dictate,
            help: "Start dictation — click the stop button in the recording bar to finish"
        ) {
            coordinator.send(.dictateRequested)
        }

        launcherItem(
            icon: "person.2.fill",
            title: "Meeting",
            tint: IC.meeting,
            help: "Start a meeting recording"
        ) {
            coordinator.send(.startMeetingRequested)
        }

        if isVertical { launcherDividerV } else { launcherDivider }

        launcherItem(
            icon: "list.clipboard.fill",
            title: "Paste Bin",
            tint: IC.pasteBin,
            help: "Open recent transcriptions"
        ) {
            coordinator.send(.openPasteBinRequested)
        }

        launcherItem(
            icon: "square.grid.2x2.fill",
            title: "Workspace",
            tint: IC.workspace,
            help: "Open the Whisperer workspace"
        ) {
            coordinator.send(.openWorkspaceRequested)
        }
    }

    private func launcherItem(
        icon: String,
        title: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        LauncherItem(
            coordinator: coordinator,
            icon: icon,
            title: title,
            tint: tint,
            help: help,
            action: action
        )
    }

    private var launcherDivider: some View {
        Rectangle()
            .fill(IC.primary.opacity(0.18))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 5)
            .accessibilityHidden(true)
    }

    private var launcherDividerV: some View {
        Rectangle()
            .fill(IC.primary.opacity(0.18))
            .frame(width: 16, height: 1)
            .padding(.vertical, 5)
            .accessibilityHidden(true)
    }

    /// Simplified strip without the notch dead zone — content spans the full width.
    private func strip<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(width: metrics.rowHeight, height: metrics.rowHeight)
                .padding(.leading, 10)

            trailing()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: metrics.rowHeight)
                .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusRow<Content: View>(_ content: Content) -> some View {
        strip(leading: { Color.clear }, trailing: { content })
    }

    // MARK: - Recording / Paused row

    @ViewBuilder
    private func recordingRow(isPaused: Bool) -> some View {
        if isVertical {
            verticalRecordingRow(isPaused: isPaused)
        } else {
            horizontalRecordingRow(isPaused: isPaused)
        }
    }

    private func horizontalRecordingRow(isPaused: Bool) -> some View {
        strip {
            RecordingDot(isPaused: isPaused)
        } trailing: {
            HStack(spacing: 8) {
                IslandWaveform(levelBridge: levelBridge,
                               isPaused: isPaused || vm.isMicMuted)
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.rowHeight)

                Text(clock.displayText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(IC.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 40, alignment: .trailing)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: clock.displayText)

                IslandHoverButton(
                    icon: isPaused ? "play.fill" : "pause.fill",
                    diameter: metrics.controlSize,
                    iconColor: IC.primary
                ) {
                    coordinator.send(.pauseResumeRequested(sessionID: vm.sessionID))
                }
                .help(isPaused ? "Resume recording" : "Pause recording")
                .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

                inlineStopButton
            }
        }
    }

    private func verticalRecordingRow(isPaused: Bool) -> some View {
        VStack(spacing: 8) {
            RecordingDot(isPaused: isPaused)
                .padding(.top, 10)

            // Waveform rotated -90° so bars run along the pill's long axis.
            IslandWaveform(levelBridge: levelBridge,
                           isPaused: isPaused || vm.isMicMuted)
                .frame(maxHeight: .infinity)
                .frame(width: metrics.rowHeight)
                .rotationEffect(.degrees(-90))

            Text(clock.displayText)
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .fixedSize()
                .contentTransition(.numericText())
                .rotationEffect(.degrees(-90))

            IslandHoverButton(
                icon: isPaused ? "play.fill" : "pause.fill",
                diameter: metrics.controlSize,
                // Same colour logic as the HUD's pause control: blue while running, orange
                // once paused, so the state is legible from the colour alone.
                iconColor: isPaused ? IC.attention : IC.accent,
                tinted: true
            ) {
                coordinator.send(.pauseResumeRequested(sessionID: vm.sessionID))
            }
            .help(isPaused ? "Resume recording" : "Pause recording")
            .accessibilityLabel(isPaused ? "Resume recording" : "Pause recording")

            inlineStopButton
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Inline stop button

    private var inlineStopButton: some View {
        Button {
            coordinator.send(.stopRequested(sessionID: vm.sessionID))
        } label: {
            ZStack {
                // Red disc + red ring, the way the HUD draws its cancel control.
                Circle()
                    .fill(IC.error.opacity(vm.capture == .finalizing ? 0.06 : 0.12))

                Circle()
                    .strokeBorder(
                        IC.error.opacity(vm.capture == .finalizing ? 0.45 : 0.85),
                        lineWidth: 1.6
                    )

                RoundedRectangle(cornerRadius: max(3, metrics.controlSize * 0.1),
                                 style: .continuous)
                    .fill(IC.error)
                    .frame(width: metrics.controlSize * 0.38,
                           height: metrics.controlSize * 0.38)
                    .scaleEffect(vm.capture == .finalizing ? 0.84 : 1.0)
            }
            .frame(width: metrics.controlSize, height: metrics.controlSize)
            .contentShape(Circle())
        }
        .buttonStyle(IslandInlineStopStyle())
        .disabled(vm.capture == .finalizing)
        .help("Stop recording")
        .accessibilityLabel("Stop recording")
    }

    // MARK: - Permission row

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IC.attention)

            Text("Microphone access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Failed row

    private func failedRow(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(IC.error)

            Text(msg.isEmpty ? "Recording failed" : msg)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(IC.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 6)

            // Offered only for verdicts the app can actually act on (input muted, gain at
            // zero). A "Retry" that just rebuilds the same dead engine is what produced the
            // four useless rebuilds on 2026-09-14 — don't put that button in front of the user.
            if vm.captureCanRepair {
                IslandHoverButton(icon: "mic.fill", iconColor: IC.dictate, tinted: true) {
                    coordinator.send(.repairCaptureRequested)
                }
                .help("Turn the microphone back on")
                .accessibilityLabel("Turn the microphone back on")
            }

            IslandHoverButton(icon: "xmark", iconColor: IC.secondary) {
                coordinator.send(.dismissFailure)
            }
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
    }

    // MARK: - Secondary (expanded) row

    @ViewBuilder
    private var secondaryRow: some View {
        if isVertical {
            VStack(spacing: 18) { secondaryItems }
                .frame(maxHeight: .infinity)
        } else {
            HStack(spacing: 24) { secondaryItems }
                .frame(maxWidth: .infinity)
                .environment(\.layoutDirection, .leftToRight)
        }
    }

    @ViewBuilder
    private var secondaryItems: some View {
        Group {
            IslandHoverButton(
                icon: vm.isMicMuted ? "mic.slash.fill" : "mic.fill",
                label: vm.isMicMuted ? "Unmute" : "Mic",
                scale: .large,
                // Green for `mic.fill`, as everywhere else; orange once muted, which is the
                // HUD's convention for a control that is currently suppressing audio.
                iconColor: vm.isMicMuted ? IC.attention : IC.dictate,
                tinted: true
            ) {
                coordinator.send(.micMuteRequested(sessionID: vm.sessionID))
            }
            .help(vm.isMicMuted ? "Unmute microphone" : "Mute microphone")

            IslandHoverButton(
                icon: vm.isOutputMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: vm.isOutputMuted ? "Muted" : "Speaker",
                scale: .large,
                // The menu bar's "Audio" card is `speaker.wave.2.fill` in `.orange`, but orange
                // is already this row's muted state — so the live state takes the HUD's blue and
                // orange stays reserved for "currently muted".
                iconColor: vm.isOutputMuted ? IC.attention : IC.accent,
                tinted: true
            ) {
                coordinator.send(.outputMuteRequested(sessionID: vm.sessionID))
            }
            .help(vm.isOutputMuted ? "Capture system audio" : "Mute system audio")

            IslandHoverButton(
                icon: "rectangle.on.rectangle",
                label: "Open",
                scale: .large,
                // Opens the meeting window — same cyan the sidebar gives Meeting Studio.
                iconColor: IC.meeting,
                tinted: true
            ) {
                coordinator.send(.openWindowRequested)
            }
            .help("Open the meeting window")
        }
    }
}

// MARK: - Launcher item

/// One glyph in the idle launcher bar, wired to the floating hint label.
///
/// The glyph tracks its own centre in panel coordinates so the label can sit directly over
/// it rather than over the middle of the bar. `.help` is deliberately not used: the system
/// tooltip would fade in a second later on top of the hint and say the same thing twice.
private struct LauncherItem: View {
    @ObservedObject var coordinator: IslandCoordinator
    let icon: String
    let title: String
    let tint: Color
    let help: String
    let action: () -> Void

    private var isVertical: Bool { coordinator.placement.isVertical }

    var body: some View {
        IslandHoverButton(
            icon: icon,
            diameter: IslandContentSizer.launcherItemWidth,
            iconColor: tint,
            tinted: true,
            action: action
        )
        // Published every layout pass rather than snapshotted on hover. A snapshot taken at
        // hover time is either unset (the bar had not laid out yet — the chip then rendered
        // at the panel's far edge) or mid-spring stale, and neither can be corrected until
        // the next geometry callback lands.
        .background(
            GeometryReader { geo in
                let f = geo.frame(in: .named(IslandPanelSpace.name))
                Color.clear.preference(
                    key: LauncherAnchorKey.self,
                    value: [title: isVertical ? f.midY : f.midX]
                )
            }
        )
        .onHover { hovering in
            if hovering {
                coordinator.setLauncherHint(title)
            } else {
                coordinator.clearLauncherHint(ifTitleIs: title)
            }
        }
        .accessibilityLabel(help)
    }
}

// MARK: - Launcher anchor plumbing

/// Named coordinate space covering the whole Island panel. The hint chip and the glyphs must
/// measure against the same origin; the glyphs used `.global` while the chip offset itself
/// against a *computed* envelope width, so the two only agreed by coincidence.
enum IslandPanelSpace {
    static let name = "islandPanel"
}

/// Live centre of every launcher glyph, keyed by title.
struct LauncherAnchorKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Launcher hint label

/// The floating name of the hovered glyph. Deliberately tiny: a hairline-bordered glass
/// chip with one word in it, so it reads as a caption for the bar rather than as a second
/// piece of chrome competing with it.
struct IslandLauncherHintLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(IC.primary.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                ZStack {
                    Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    Capsule().fill(IC.surface.opacity(0.42))
                }
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 8, y: 2)
            .allowsHitTesting(false)
    }
}

// MARK: - Peek level meter

/// Five bars driven by the 12 Hz `peekLevel` — the nub's cheap stand-in for the 20-bar,
/// 60 Hz waveform that only runs once the compact row is open.
private struct PeekLevelMeter: View {
    var level: Float
    var isPaused: Bool

    private static let weights: [CGFloat] = [0.45, 0.75, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(IC.primary.opacity(isPaused ? 0.22 : 0.78))
                    .frame(width: 2.5,
                           height: max(3, CGFloat(level) * 14 * weight + 3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.easeOut(duration: 0.12), value: level)
        .animation(.easeOut(duration: 0.2), value: isPaused)
    }
}

// MARK: - Waveform

private struct IslandWaveform: View {
    @ObservedObject var levelBridge: IslandLevelBridge
    var isPaused: Bool

    var body: some View {
        WaveformView(waveformState: levelBridge.waveform)
            .opacity(isPaused ? 0.35 : 1)
            .animation(.easeOut(duration: 0.2), value: isPaused)
    }
}

// MARK: - Color palette

/// The Island's palette, drawn from the same dark-navy system as the Overlay HUD
/// (`DESIGN.md` §1). The Island used to be built from neutral blacks and greys, which read as a
/// different product sitting next to the navy HUD; every surface below is now a navy token and
/// every accent is the exact value `OverlayView` uses.
enum IC {
    /// Deepest navy — `#0C0C1A`, the DESIGN "Background" token.
    static let surface   = Color(red: 0.047, green: 0.047, blue: 0.102)
    /// `#14142B` — the DESIGN "Card surface" token, and literally the HUD capsule's fill.
    /// This is the Island's own body colour at rest and open alike.
    static let raised    = Color(red: 0.078, green: 0.078, blue: 0.169)
    /// `#1C1C3A` — the DESIGN "Elevated" token. Hover states lift to this.
    static let elevated  = Color(red: 0.110, green: 0.110, blue: 0.227)
    static let primary   = Color(red: 0.961, green: 0.961, blue: 0.969)
    static let secondary = Color(red: 0.631, green: 0.631, blue: 0.671)
    /// `#5B6CF7` — matches `OverlayView.blueAccent`.
    static let accent    = Color(red: 0.357, green: 0.424, blue: 0.969)
    /// `#8B5CF6` — matches `OverlayView.purpleAccent`. The HUD uses purple for its
    /// "Processing" / "Loading model" capsules, so the Island's finalizing tier uses it too.
    static let processing = Color(red: 0.545, green: 0.361, blue: 0.965)
    /// `#49D281` — matches `OverlayView.accentGreen` (the done/checkmark state).
    static let success   = Color(red: 0.286, green: 0.824, blue: 0.506)
    /// The HUD's destructive affordance is plain `Color.red`; the Island used a softer salmon,
    /// which made the same action look like two different severities across the two surfaces.
    static let error     = Color.red
    /// The launcher bar only exists on screen while the pointer is over it, so its glyphs
    /// are legible from the moment they appear; the per-button hover state is what picks
    /// one out of the row, not a rest-vs-active brightness jump for the whole bar.
    ///
    /// All four glyphs share one colour on purpose. Tinting Dictate blue to mark it as the
    /// default action just made one icon look mismatched against the glass — the divider
    /// already carries the grouping, so the row reads better as a single neutral set.
    static let glyph            = Color(red: 0.961, green: 0.961, blue: 0.969).opacity(0.72)
    static let glyphHover       = Color(red: 0.961, green: 0.961, blue: 0.969)
    /// The HUD marks the paused / muted state with `Color.orange`; the Island's custom amber
    /// was close enough to look like a mistake rather than a distinction.
    static let attention = Color.orange

    // MARK: Per-element launcher colours
    //
    // DESIGN.md §1 "Per-Element Colorful Icons". The launcher row used to be four identical
    // white glyphs, which made four unrelated actions read as one control group.
    //
    // These are NOT new colours. Each one is lifted from wherever the app already renders the
    // same concept, so the Island agrees with the menu bar and the workspace sidebar instead of
    // inventing a fifth palette:

    /// `mic.fill` — the menu bar's Transcribe card, which is the same action this button fires,
    /// draws its `mic.fill` in `MBColors.accent` (`WhispererApp.swift:1080-1085`). The old
    /// `Color.green` came from the *Microphone device* settings card, a different concept.
    static let dictate   = accent
    /// The workspace sidebar's "Meeting Studio" section is `Color(hex: "06B6D4")`
    /// (`HistoryWindowView.swift:123`).
    static let meeting   = Color(hex: "06B6D4")
    /// The Paste Bin opens recent transcriptions. The sidebar paints that section in
    /// `accentBlue`, but Dictate already owns the accent here, so it takes the app's green
    /// token — `Color(hex: "22C55E")` (`HistoryWindowView.swift:129`) — not SwiftUI's raw
    /// `.green`, which is a brighter, more saturated hue that does not belong to this palette.
    static let pasteBin  = Color(hex: "22C55E")
    /// The menu bar's Workspace button (`square.grid.2x2.fill`) is a blue→purple gradient
    /// (`WhispererApp.swift:775`). A single glyph takes the purple end.
    static let workspace = processing
}

// MARK: - Stop button style

private struct IslandInlineStopStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
    }
}

// MARK: - Pulsing dot

struct PulsingModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pulsing ? 1.3 : 0.8)
            .opacity(pulsing ? 1.0 : 0.55)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

struct RecordingDot: View {
    var isPaused: Bool
    var body: some View {
        if isPaused {
            Circle().fill(Color.red.opacity(0.6)).frame(width: 8, height: 8)
        } else {
            Circle().fill(Color.red).frame(width: 8, height: 8).modifier(PulsingModifier())
        }
    }
}

// MARK: - Progress rule

struct IslandProgressRule: View {
    var tint: Color
    var label: String
    /// nil = indeterminate sweep; 0–1 = determinate fill
    var fraction: Double?

    private let ruleHeight: CGFloat = 3

    var body: some View {
        HStack(spacing: 10) {
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tint.opacity(0.18)).frame(height: ruleHeight)
                        Capsule()
                            .fill(tint)
                            .frame(width: geo.size.width * min(max(fraction, 0), 1),
                                   height: ruleHeight)
                            .animation(.smooth(duration: 0.4), value: fraction)
                    }
                    .frame(height: geo.size.height, alignment: .center)
                }
                .frame(height: ruleHeight)
            } else {
                rule(fadingTowards: .leading)
            }

            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.5)
                .foregroundStyle(tint)
                .lineLimit(1)
                .fixedSize()

            if fraction == nil {
                rule(fadingTowards: .trailing)
            }
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func rule(fadingTowards edge: UnitPoint) -> some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.5), tint.opacity(0.12)],
                    startPoint: edge == .leading ? .trailing : .leading,
                    endPoint: edge
                )
            )
            .frame(height: ruleHeight)
    }
}
