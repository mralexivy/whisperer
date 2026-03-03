//
//  FileTranscriptionView.swift
//  Whisperer
//
//  File transcription tab for the workspace window
//

import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var manager = FileTranscriptionManager()
    @ObservedObject private var appState = AppState.shared
    @State private var selectedLanguage: TranscriptionLanguage = .english
    @State private var isDragOver = false
    @State private var appearedSections: Set<Int> = []
    @State private var pulseAnimation = false
    @State private var copiedFeedback = false
    @State private var ringRotation: Double = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                fileTranscriptionHeader
                    .padding(.bottom, 28)
                    .sectionFadeIn(index: 0, appeared: $appearedSections)

                VStack(alignment: .leading, spacing: 16) {
                    switch manager.state {
                    case .idle:
                        idleContent

                    case .fileSelected:
                        fileSelectedContent

                    case .loading:
                        loadingContent

                    case .transcribing:
                        transcribingContent

                    case .complete:
                        completeContent

                    case .error(let message):
                        errorContent(message: message)
                    }
                }
                .sectionFadeIn(index: 1, appeared: $appearedSections)

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .onAppear {
            selectedLanguage = appState.selectedLanguage
            for i in 0..<6 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * 0.08) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        _ = appearedSections.insert(i)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var fileTranscriptionHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                WhispererColors.accentBlue.opacity(0.18),
                                WhispererColors.accentPurple.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: WhispererColors.accentBlue.opacity(0.08), radius: 4, y: 1)

                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundColor(WhispererColors.accentBlue)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("File Transcription")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Transcribe audio and video files offline")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Idle Content

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroDropZone
            featureCards
                .sectionFadeIn(index: 2, appeared: $appearedSections)
            transcriptionResultSection
                .sectionFadeIn(index: 3, appeared: $appearedSections)
        }
    }

    // MARK: - Hero Drop Zone

    private var heroDropZone: some View {
        VStack(spacing: 0) {
            // Decorative visual area
            ZStack {
                // Concentric rings
                Circle()
                    .stroke(WhispererColors.accentPurple.opacity(0.04), lineWidth: 1)
                    .frame(width: 240, height: 240)
                    .rotationEffect(.degrees(ringRotation))

                Circle()
                    .stroke(WhispererColors.accentBlue.opacity(0.06), lineWidth: 1.5)
                    .frame(width: 180, height: 180)

                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [WhispererColors.accentBlue.opacity(0.10), WhispererColors.accentPurple.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 120, height: 120)

                // Radial glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [WhispererColors.accentPurple.opacity(0.10), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 120
                        )
                    )
                    .frame(width: 240, height: 240)

                // Central icon
                ZStack {
                    RoundedRectangle(cornerRadius: 22)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.purple.opacity(isDragOver ? 0.30 : 0.14),
                                    WhispererColors.accentBlue.opacity(isDragOver ? 0.24 : 0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 80, height: 80)
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.purple.opacity(isDragOver ? 0.45 : 0.16),
                                            WhispererColors.accentBlue.opacity(isDragOver ? 0.35 : 0.10)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                        .shadow(color: Color.purple.opacity(isDragOver ? 0.25 : 0.08), radius: 16, y: 4)

                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.purple, WhispererColors.accentBlue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Orbiting decorative icons
                decorativeOrbitIcon("waveform", color: WhispererColors.accentBlue, angle: -40, radius: 108)
                decorativeOrbitIcon("mic.fill", color: .red, angle: 35, radius: 104)
                decorativeOrbitIcon("text.cursor", color: Color(hex: "22C55E"), angle: 110, radius: 106)
                decorativeOrbitIcon("globe", color: .blue, angle: 185, radius: 102)
                decorativeOrbitIcon("clock.fill", color: Color(hex: "F97316"), angle: 250, radius: 108)
            }
            .frame(height: 260)
            .padding(.top, 20)

            // Text content
            VStack(spacing: 6) {
                Text("Drop your files here")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("or choose a file to transcribe")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
            }
            .padding(.top, 4)

            // Format pills
            formatPillsRow
                .padding(.top, 16)

            // Choose File button
            Button(action: openFilePicker) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .medium))
                    Text("Choose File")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(Capsule().fill(WhispererColors.accentGradient))
                .shadow(color: WhispererColors.accentBlue.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isDragOver
                        ? LinearGradient(colors: [WhispererColors.accentBlue, WhispererColors.accentPurple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [WhispererColors.border(colorScheme), WhispererColors.border(colorScheme)], startPoint: .leading, endPoint: .trailing),
                    style: isDragOver ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1.5, dash: [10, 7])
                )
        )
        .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
        .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in
            handleDrop(providers: providers)
        }
        .animation(.easeInOut(duration: 0.25), value: isDragOver)
        .onAppear {
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                ringRotation = 360
            }
        }
    }

    // MARK: - Feature Cards (How It Works)

    private var featureCards: some View {
        HStack(spacing: 10) {
            FeatureHighlightCard(
                icon: "doc.badge.plus",
                label: "SELECT",
                title: "Choose File",
                subtitle: "Drop or pick an audio or video file",
                color: .purple,
                colorScheme: colorScheme
            )

            FeatureHighlightCard(
                icon: "waveform",
                label: "TRANSCRIBE",
                title: "AI Processing",
                subtitle: "Offline transcription with Whisper AI",
                color: WhispererColors.accentBlue,
                colorScheme: colorScheme
            )

            FeatureHighlightCard(
                icon: "doc.text",
                label: "RESULT",
                title: "Get Text",
                subtitle: "Copy text or save to your history",
                color: Color(hex: "22C55E"),
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - Decorative Helpers

    private func decorativeOrbitIcon(_ name: String, color: Color, angle: Double, radius: CGFloat) -> some View {
        let radians = angle * .pi / 180
        let x = cos(radians) * radius
        let y = sin(radians) * radius

        return ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(color.opacity(0.10))
                .frame(width: 32, height: 32)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(color.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: color.opacity(0.06), radius: 4, y: 1)

            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(color.opacity(0.6))
        }
        .offset(x: x, y: y)
    }

    // MARK: - Format Pills

    private var formatPillsRow: some View {
        HStack(spacing: 8) {
            formatPill("MP3", color: Color(hex: "F97316"))
            formatPill("WAV", color: WhispererColors.accentBlue)
            formatPill("M4A", color: Color(hex: "22C55E"))
            formatPill("FLAC", color: Color(hex: "06B6D4"))
            formatPill("MP4", color: .red)
            formatPill("MOV", color: .purple)
            formatPill("AIFF", color: .pink)
        }
    }

    private func formatPill(_ format: String, color: Color) -> some View {
        Text(format)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .tracking(0.4)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(color.opacity(0.12), lineWidth: 0.5)
            )
    }

    // MARK: - File Selected Content

    private var fileSelectedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(colorScheme: colorScheme) {
                VStack(spacing: 0) {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.purple.opacity(0.15), WhispererColors.accentBlue.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 48, height: 48)
                                .shadow(color: Color.purple.opacity(0.06), radius: 4, y: 1)

                            Image(systemName: fileIcon)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.purple)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Text(manager.fileName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))
                                .lineLimit(1)

                            HStack(spacing: 12) {
                                if manager.fileDuration > 0 {
                                    fileMetaPill(icon: "clock", text: manager.formatDuration(manager.fileDuration), color: Color(hex: "06B6D4"))
                                }
                                if !manager.fileSize.isEmpty {
                                    fileMetaPill(icon: "doc", text: manager.fileSize, color: Color(hex: "F97316"))
                                }
                                fileMetaPill(icon: "waveform", text: fileFormatLabel, color: .purple)
                            }
                        }

                        Spacer()

                        Button(action: openFilePicker) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                .frame(width: 34, height: 34)
                                .background(
                                    Circle()
                                        .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.6))
                                )
                                .overlay(Circle().stroke(WhispererColors.border(colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    // Divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [WhispererColors.accentBlue.opacity(0.15), WhispererColors.border(colorScheme), WhispererColors.border(colorScheme).opacity(0.3)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .padding(.vertical, 16)

                    HStack(spacing: 16) {
                        HStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color.blue.opacity(0.15))
                                    .frame(width: 28, height: 28)
                                    .shadow(color: Color.blue.opacity(0.06), radius: 2, y: 1)
                                Image(systemName: "globe")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                            languagePicker
                        }

                        Spacer()

                        Button(action: { manager.transcribeFile(language: selectedLanguage) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Transcribe File")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(WhispererColors.accentGradient))
                            .shadow(color: WhispererColors.accentBlue.opacity(0.3), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragOver) { providers in handleDrop(providers: providers) }

            transcriptionResultSection
        }
    }

    private func fileMetaPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
        }
        .foregroundColor(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    private var fileFormatLabel: String {
        guard let url = manager.selectedFileURL else { return "" }
        return url.pathExtension.uppercased()
    }

    // MARK: - Loading Content

    private var loadingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(colorScheme: colorScheme) {
                VStack(spacing: 20) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.3)
                        .tint(WhispererColors.accentBlue)

                    VStack(spacing: 6) {
                        Text("Loading audio...")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text(manager.fileName)
                            .font(.system(size: 12))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }

            transcriptionResultSection
        }
    }

    // MARK: - Transcribing Content

    private var transcribingContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(colorScheme: colorScheme, borderColor: WhispererColors.accentBlue.opacity(0.15)) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(WhispererColors.accentBlue.opacity(0.12))
                                .frame(width: 40, height: 40)
                                .shadow(color: WhispererColors.accentBlue.opacity(0.08), radius: 3, y: 1)

                            Image(systemName: "waveform")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(WhispererColors.accentBlue)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(manager.fileName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))
                                .lineLimit(1)

                            Text("Transcribing...")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(WhispererColors.accentBlue)
                        }

                        Spacer()

                        Button(action: { manager.cancelTranscription() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.red)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.red.opacity(0.10)))
                                .overlay(Circle().stroke(Color.red.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }

                    // Progress bar
                    VStack(alignment: .leading, spacing: 8) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                                    .frame(height: 8)

                                RoundedRectangle(cornerRadius: 5)
                                    .fill(WhispererColors.accentGradient)
                                    .frame(width: max(0, geometry.size.width * manager.progress), height: 8)
                                    .animation(.easeInOut(duration: 0.4), value: manager.progress)
                            }
                        }
                        .frame(height: 8)

                        HStack {
                            Text("\(Int(manager.progress * 100))%")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(WhispererColors.accentBlue)
                            Spacer()
                            if manager.totalChunks > 1 {
                                Text("Chunk \(manager.currentChunk) of \(manager.totalChunks)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            }
                        }
                    }
                    .padding(.top, 18)

                    if !manager.transcriptionResult.isEmpty {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [WhispererColors.accentBlue.opacity(0.2), WhispererColors.accentPurple.opacity(0.2), Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1)
                            .padding(.top, 16)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 6, height: 6)
                                    .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulseAnimation)

                                Text("LIVE PREVIEW")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(WhispererColors.accentGradient)
                                    .tracking(1.2)
                            }

                            Text(manager.transcriptionResult)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(WhispererColors.primaryText(colorScheme).opacity(0.85))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(maxHeight: 100)
                        }
                        .padding(.top, 14)
                        .onAppear { pulseAnimation = true }
                    }
                }
            }

            transcriptionResultSection
        }
    }

    // MARK: - Complete Content

    private var completeContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Stats summary row
            completionStatsRow
                .sectionFadeIn(index: 0, appeared: $appearedSections)

            // Transcription result with text
            transcriptionResultSection
                .sectionFadeIn(index: 1, appeared: $appearedSections)
        }
        .onAppear {
            appearedSections = []
            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * 0.1) {
                    withAnimation(.easeOut(duration: 0.4)) { _ = appearedSections.insert(i) }
                }
            }
        }
    }

    private var completionStatsRow: some View {
        HStack(spacing: 10) {
            CompletionStatCard(
                icon: "checkmark.circle.fill",
                label: "FILE",
                value: manager.fileName,
                isFileName: true,
                color: Color(hex: "22C55E"),
                colorScheme: colorScheme
            )
            CompletionStatCard(
                icon: "clock",
                label: "DURATION",
                value: manager.formatDuration(manager.fileDuration),
                color: Color(hex: "06B6D4"),
                colorScheme: colorScheme
            )
            CompletionStatCard(
                icon: "text.word.spacing",
                label: "WORDS",
                value: "\(manager.transcriptionResult.split(separator: " ").count)",
                color: WhispererColors.accentBlue,
                colorScheme: colorScheme
            )
            CompletionStatCard(
                icon: "speedometer",
                label: "SPEED",
                value: "\(wpmValue) wpm",
                color: Color(hex: "F97316"),
                colorScheme: colorScheme
            )
        }
    }

    // MARK: - Error Content

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(colorScheme: colorScheme, borderColor: Color.red.opacity(0.15)) {
                VStack(spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.red.opacity(0.10))
                            .frame(width: 56, height: 56)
                            .shadow(color: Color.red.opacity(0.06), radius: 4, y: 1)

                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.red)
                    }

                    VStack(spacing: 6) {
                        Text("Transcription Failed")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        Text(message)
                            .font(.system(size: 13))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }

                    HStack(spacing: 12) {
                        Button(action: {
                            withAnimation(.spring(response: 0.3)) { manager.clearSelection() }
                        }) {
                            Text("Try Another File")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(WhispererColors.elevatedBackground(colorScheme)))
                                .overlay(Capsule().stroke(WhispererColors.border(colorScheme), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        if manager.selectedFileURL != nil {
                            Button(action: { manager.transcribeFile(language: selectedLanguage) }) {
                                Text("Retry")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Capsule().fill(WhispererColors.accentGradient))
                                    .shadow(color: WhispererColors.accentBlue.opacity(0.25), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            transcriptionResultSection
        }
    }

    // MARK: - Transcription Result Section

    private var transcriptionResultSection: some View {
        SettingsCard(colorScheme: colorScheme, borderColor: manager.state == .complete ? Color(hex: "22C55E").opacity(0.12) : nil) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SettingsSectionHeader(
                        icon: "text.alignleft",
                        title: "Transcription Result",
                        colorScheme: colorScheme,
                        color: Color(hex: "22C55E")
                    )

                    Spacer()

                    if manager.state == .complete && !manager.transcriptionResult.isEmpty {
                        resultActionButtons
                    }
                }

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "22C55E").opacity(0.12), WhispererColors.border(colorScheme), WhispererColors.border(colorScheme).opacity(0.3)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)
                    .padding(.top, 16)

                if manager.state == .complete && !manager.transcriptionResult.isEmpty {
                    Text(manager.transcriptionResult)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "text.page")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))

                        Text("Transcription will appear here")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    private var resultActionButtons: some View {
        HStack(spacing: 8) {
            // New File button
            Button(action: {
                withAnimation(.spring(response: 0.3)) { manager.clearSelection() }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("New")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(WhispererColors.accentBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(WhispererColors.accentBlue.opacity(0.10)))
                .overlay(Capsule().stroke(WhispererColors.accentBlue.opacity(0.12), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // Copy button
            Button(action: copyToClipboard) {
                HStack(spacing: 5) {
                    Image(systemName: copiedFeedback ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                    Text(copiedFeedback ? "Copied" : "Copy")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(copiedFeedback ? Color(hex: "22C55E") : WhispererColors.primaryText(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(copiedFeedback ? Color(hex: "22C55E").opacity(0.12) : WhispererColors.elevatedBackground(colorScheme)))
                .overlay(Capsule().stroke(copiedFeedback ? Color(hex: "22C55E").opacity(0.2) : WhispererColors.border(colorScheme), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Save button
            Button(action: {
                Task { await manager.saveToHistory() }
            }) {
                HStack(spacing: 5) {
                    Image(systemName: manager.savedToHistory ? "checkmark.circle.fill" : "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                    Text(manager.savedToHistory ? "Saved" : "Save")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(manager.savedToHistory
                              ? AnyShapeStyle(Color(hex: "22C55E"))
                              : AnyShapeStyle(WhispererColors.accentGradient))
                )
                .shadow(color: (manager.savedToHistory ? Color(hex: "22C55E") : WhispererColors.accentBlue).opacity(0.2), radius: 4, y: 1)
            }
            .buttonStyle(.plain)
            .disabled(manager.savedToHistory)
        }
    }

    // MARK: - Helpers

    private var wpmValue: String {
        let wordCount = manager.transcriptionResult.split(separator: " ").count
        guard manager.fileDuration > 0 else { return "0" }
        return "\(Int(Double(wordCount) / (manager.fileDuration / 60.0)))"
    }

    private var fileIcon: String {
        guard let url = manager.selectedFileURL else { return "doc.fill" }
        let ext = url.pathExtension.lowercased()
        if FileTranscriptionManager.videoExtensions.contains(ext) { return "film" }
        return "waveform"
    }

    private var languagePicker: some View {
        Picker("", selection: $selectedLanguage) {
            ForEach(TranscriptionLanguage.allCases, id: \.self) { lang in
                Text(lang.displayName).tag(lang)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 180)
        .tint(WhispererColors.accentBlue)
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .mpeg4Movie, .quickTimeMovie, .wav, .mp3, .aiff]
        panel.message = "Select an audio or video file to transcribe"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(.spring(response: 0.3)) {
                manager.selectFile(url: url)
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        _ = provider.loadObject(ofClass: URL.self) { url, error in
            guard let url = url, error == nil else { return }
            let ext = url.pathExtension.lowercased()
            guard FileTranscriptionManager.allExtensions.contains(ext) else { return }

            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3)) {
                    manager.selectFile(url: url)
                }
            }
        }

        return true
    }

    private func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(manager.transcriptionResult, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) { copiedFeedback = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.2)) { copiedFeedback = false }
        }
    }
}

// MARK: - Feature Highlight Card (How It Works)

private struct FeatureHighlightCard: View {
    let icon: String
    let label: String
    let title: String
    let subtitle: String
    let color: Color
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.9)

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)
                        .shadow(color: color.opacity(0.06), radius: 2, y: 1)

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color)
                }
            }
            .padding(.bottom, 14)

            Text(title)
                .font(.system(size: 18, weight: .light, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .padding(.bottom, 4)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)

            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(height: 2)
                .frame(width: isHovered ? 60 : 40, alignment: .leading)
                .animation(.spring(response: 0.3), value: isHovered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 6 : 4,
            y: isHovered ? 2 : 1
        )
        .overlay(
            Circle()
                .fill(color.opacity(0.06))
                .frame(width: 88, height: 88)
                .blur(radius: 24)
                .offset(x: 30, y: -30),
            alignment: .topTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Completion Stat Card

private struct CompletionStatCard: View {
    let icon: String
    let label: String
    let value: String
    var isFileName: Bool = false
    let color: Color
    let colorScheme: ColorScheme

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.9)

                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)

                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color)
                }
            }
            .padding(.bottom, 14)

            if isFileName {
                Text(value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(value)
                    .font(.system(size: 24, weight: .light, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .monospacedDigit()
            }

            Spacer(minLength: 10)

            // Accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(color.opacity(0.6))
                .frame(height: 2)
                .frame(width: isHovered ? 60 : 40, alignment: .leading)
                .animation(.spring(response: 0.3), value: isHovered)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(minHeight: 120)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(WhispererColors.cardBackground(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isHovered
                        ? color.opacity(0.2)
                        : WhispererColors.border(colorScheme),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 6 : 4,
            y: isHovered ? 2 : 1
        )
        .overlay(
            Circle()
                .fill(color.opacity(0.06))
                .frame(width: 88, height: 88)
                .blur(radius: 24)
                .offset(x: 30, y: -30),
            alignment: .topTrailing
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}
