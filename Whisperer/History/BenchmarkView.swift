//
//  BenchmarkView.swift
//  Whisperer
//
//  In-app benchmark tab for comparing transcription backend performance
//

import SwiftUI

struct BenchmarkView: View {
    @Environment(\.colorScheme) var colorScheme
    @StateObject private var benchmarkManager = BenchmarkManager()
    @ObservedObject private var appState = AppState.shared

    @State private var appearedSections: Set<Int> = []
    @State private var selectedBackends: Set<BackendType> = [.whisperCpp]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                benchmarkHeader
                    .padding(.bottom, 24)

                configurationSection
                    .padding(.bottom, 16)
                    .sectionFadeIn(index: 0, appeared: $appearedSections)

                if benchmarkManager.isRunning {
                    progressSection
                        .padding(.bottom, 16)
                        .sectionFadeIn(index: 1, appeared: $appearedSections)
                }

                if !benchmarkManager.results.isEmpty && !benchmarkManager.isRunning {
                    resultsSection
                        .sectionFadeIn(index: 1, appeared: $appearedSections)
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
        .onAppear {
            // Initialize available backends
            selectedBackends = Set(BackendType.allCases.filter(\.isAvailable))

            // Load recordings for real-speech benchmarking
            benchmarkManager.loadAvailableRecordings()

            for i in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 + Double(i) * 0.08) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        _ = appearedSections.insert(i)
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var benchmarkHeader: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "22C55E").opacity(0.18),
                                WhispererColors.accentBlue.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .shadow(color: Color(hex: "22C55E").opacity(0.08), radius: 4, y: 1)

                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "22C55E"))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Benchmark")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Text("Compare transcription backend performance")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }

            Spacer()
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 20) {
                SettingsSectionHeader(
                    icon: "slider.horizontal.3",
                    title: "Configuration",
                    colorScheme: colorScheme,
                    color: WhispererColors.accentBlue
                )

                // Backend selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("BACKENDS")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .tracking(0.9)

                    HStack(spacing: 12) {
                        ForEach(BackendType.allCases) { backend in
                            backendToggle(backend)
                        }
                    }
                }

                // Audio source selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("AUDIO SOURCE")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .tracking(0.9)

                    HStack(spacing: 6) {
                        ForEach(BenchmarkAudioSource.allCases) { source in
                            FilterTab(
                                title: source.rawValue,
                                isSelected: benchmarkManager.audioSource == source,
                                colorScheme: colorScheme,
                                color: Color(hex: "22C55E")
                            ) {
                                withAnimation(.spring(response: 0.3)) {
                                    benchmarkManager.audioSource = source
                                    if source == .recording {
                                        benchmarkManager.loadAvailableRecordings()
                                    }
                                }
                            }
                        }
                    }
                }

                // Recording picker (when using real recordings)
                if benchmarkManager.audioSource == .recording {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECORDING")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            .tracking(0.9)

                        if benchmarkManager.availableRecordings.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("No recordings found — record some audio first")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            )
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(benchmarkManager.availableRecordings) { recording in
                                        recordingPill(recording)
                                    }
                                }
                            }
                        }
                    }
                }

                // Duration selector (only for synthetic audio)
                if benchmarkManager.audioSource == .synthetic {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AUDIO DURATION")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            .tracking(0.9)

                        HStack(spacing: 6) {
                            ForEach(BenchmarkDuration.allCases) { duration in
                                FilterTab(
                                    title: duration.rawValue,
                                    isSelected: benchmarkManager.selectedDuration == duration,
                                    colorScheme: colorScheme,
                                    color: Color(hex: "22C55E")
                                ) {
                                    withAnimation(.spring(response: 0.3)) {
                                        benchmarkManager.selectedDuration = duration
                                    }
                                }
                            }
                        }
                    }
                }

                // Iterations
                VStack(alignment: .leading, spacing: 8) {
                    Text("ITERATIONS")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                        .tracking(0.9)

                    HStack(spacing: 6) {
                        ForEach([1, 3, 5], id: \.self) { count in
                            FilterTab(
                                title: "\(count)x",
                                isSelected: benchmarkManager.iterations == count,
                                colorScheme: colorScheme,
                                color: Color(hex: "22C55E")
                            ) {
                                withAnimation(.spring(response: 0.3)) {
                                    benchmarkManager.iterations = count
                                }
                            }
                        }
                    }
                }

                // whisper.cpp model picker
                if selectedBackends.contains(.whisperCpp) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WHISPER.CPP MODEL")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                            .tracking(0.9)

                        let downloaded = benchmarkManager.downloadedWhisperModels
                        if downloaded.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                                Text("No whisper.cpp models downloaded")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                            )
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(downloaded) { model in
                                        modelPill(
                                            title: model.displayName,
                                            isSelected: benchmarkManager.benchmarkWhisperModel == model,
                                            color: WhispererColors.accentBlue
                                        ) {
                                            withAnimation(.spring(response: 0.3)) {
                                                benchmarkManager.benchmarkWhisperModel = model
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Parakeet model picker
                if selectedBackends.contains(.parakeet) {
                    if !benchmarkManager.isParakeetReady {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                            Text("Parakeet requires Apple Silicon")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.orange)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("PARAKEET MODEL")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                                .tracking(0.9)

                            HStack(spacing: 6) {
                                ForEach(ParakeetModelVariant.allCases) { variant in
                                    modelPill(
                                        title: variant.displayName,
                                        isSelected: benchmarkManager.benchmarkParakeetVariant == variant,
                                        color: Color(hex: "22C55E")
                                    ) {
                                        withAnimation(.spring(response: 0.3)) {
                                            benchmarkManager.benchmarkParakeetVariant = variant
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Run button
                HStack {
                    Spacer()

                    Button(action: {
                        let backends = Array(selectedBackends).sorted { $0.rawValue < $1.rawValue }
                        benchmarkManager.runBenchmark(backends: backends)
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 12))
                            Text("Run Benchmark")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [WhispererColors.accentBlue, WhispererColors.accentPurple],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .shadow(color: WhispererColors.accentBlue.opacity(0.25), radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedBackends.isEmpty || benchmarkManager.isRunning || (benchmarkManager.audioSource == .recording && benchmarkManager.selectedRecording == nil) || (selectedBackends.contains(.whisperCpp) && benchmarkManager.downloadedWhisperModels.isEmpty))
                    .opacity(selectedBackends.isEmpty || (benchmarkManager.audioSource == .recording && benchmarkManager.selectedRecording == nil) || (selectedBackends.contains(.whisperCpp) && benchmarkManager.downloadedWhisperModels.isEmpty) ? 0.5 : 1.0)
                }
            }
        }
    }

    private func backendToggle(_ backend: BackendType) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3)) {
                if selectedBackends.contains(backend) {
                    selectedBackends.remove(backend)
                } else {
                    selectedBackends.insert(backend)
                }
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: selectedBackends.contains(backend) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(
                        selectedBackends.contains(backend)
                            ? (backend == .whisperCpp ? WhispererColors.accentBlue : Color(hex: "22C55E"))
                            : WhispererColors.tertiaryText(colorScheme)
                    )

                Text(backend.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(
                        backend.isAvailable
                            ? WhispererColors.primaryText(colorScheme)
                            : WhispererColors.tertiaryText(colorScheme)
                    )

                if !backend.isAvailable {
                    Text("(Apple Silicon only)")
                        .font(.system(size: 11))
                        .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        selectedBackends.contains(backend)
                            ? (backend == .whisperCpp ? WhispererColors.accentBlue : Color(hex: "22C55E")).opacity(0.1)
                            : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!backend.isAvailable)
    }

    private func recordingPill(_ recording: BenchmarkRecording) -> some View {
        let isSelected = benchmarkManager.selectedRecording == recording
        let color = Color(hex: "22C55E")

        return Button(action: {
            withAnimation(.spring(response: 0.3)) {
                benchmarkManager.selectedRecording = recording
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .white : WhispererColors.primaryText(colorScheme))
                    .lineLimit(1)

                Text(recording.formattedDuration)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : WhispererColors.tertiaryText(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? color : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? color : WhispererColors.border(colorScheme), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func modelPill(title: String, isSelected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : WhispererColors.primaryText(colorScheme))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? color : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? color : WhispererColors.border(colorScheme), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress

    private var progressSection: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Running",
                    colorScheme: colorScheme,
                    color: .orange
                )

                HStack(spacing: 12) {
                    ProgressView(value: benchmarkManager.progress)
                        .tint(WhispererColors.accentBlue)

                    Text(String(format: "%.0f%%", benchmarkManager.progress * 100))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .monospacedDigit()
                }

                Text(benchmarkManager.currentStatus)
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))

                HStack {
                    Spacer()
                    Button(action: { benchmarkManager.cancelBenchmark() }) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.red)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Summary cards
            summaryCards

            // Per-iteration detail
            iterationDetailCard

            // Transcription output
            if let lastResult = benchmarkManager.results.last, !lastResult.transcribedText.isEmpty {
                transcriptionOutputCard(lastResult)
            }
        }
    }

    private var summaryCards: some View {
        let backends = Array(Set(benchmarkManager.results.map(\.backendType)))

        return HStack(spacing: 10) {
            ForEach(backends, id: \.rawValue) { backend in
                let avgLatency = benchmarkManager.averageLatency(for: backend)
                let avgRTF = benchmarkManager.averageRTF(for: backend)
                let avgMemory = benchmarkManager.averageMemory(for: backend)
                let color: Color = backend == .whisperCpp ? WhispererColors.accentBlue : Color(hex: "22C55E")
                let modelName = benchmarkManager.results.first(where: { $0.backendType == backend })?.modelName ?? ""

                VStack(spacing: 10) {
                    backendSummaryCard(
                        backend: backend,
                        modelName: modelName,
                        color: color,
                        latency: avgLatency,
                        rtf: avgRTF,
                        memory: avgMemory
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func backendSummaryCard(backend: BackendType, modelName: String, color: Color, latency: Double, rtf: Double, memory: Double) -> some View {
        SettingsCard(colorScheme: colorScheme, borderColor: color.opacity(0.3)) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(color.opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: backend == .whisperCpp ? "c.square.fill" : "m.square.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(color)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(backend.displayName)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        if !modelName.isEmpty {
                            Text(modelName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                        }
                    }

                    Spacer()

                    if let comparison = benchmarkManager.comparison, comparison.winner == backend {
                        winnerBadge(text: comparison.winnerSpeedupText)
                    }
                }

                HStack(spacing: 16) {
                    metricColumn(label: "LATENCY", value: benchmarkManager.formattedLatency(latency), icon: "speedometer", color: .orange)
                    metricColumn(label: "RTF", value: benchmarkManager.formattedRTF(rtf), icon: "timer", color: .cyan)
                    metricColumn(label: "MEMORY", value: benchmarkManager.formattedMemory(memory), icon: "memorychip", color: .red)
                }
            }
        }
    }

    private func metricColumn(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.8)
            }

            Text(value)
                .font(.system(size: 20, weight: .light, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .monospacedDigit()
        }
    }

    private func winnerBadge(text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "crown.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color(hex: "22C55E"))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color(hex: "22C55E"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(hex: "22C55E").opacity(0.12))
        )
    }

    // MARK: - Iteration Detail

    private var iterationDetailCard: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsSectionHeader(
                    icon: "list.number",
                    title: "Per-Iteration Results",
                    colorScheme: colorScheme,
                    color: .purple
                )

                VStack(spacing: 0) {
                    // Header row
                    HStack {
                        Text("#")
                            .frame(width: 30, alignment: .leading)
                        Text("Backend")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Latency")
                            .frame(width: 80, alignment: .trailing)
                        Text("RTF")
                            .frame(width: 60, alignment: .trailing)
                        Text("Words")
                            .frame(width: 60, alignment: .trailing)
                        Text("Memory")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .tracking(0.5)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)

                    Rectangle()
                        .fill(WhispererColors.border(colorScheme))
                        .frame(height: 1)

                    // Data rows
                    ForEach(Array(benchmarkManager.results.enumerated()), id: \.element.id) { index, result in
                        let color: Color = result.backendType == .whisperCpp ? WhispererColors.accentBlue : Color(hex: "22C55E")

                        HStack {
                            Text("\(index + 1)")
                                .frame(width: 30, alignment: .leading)
                                .foregroundColor(WhispererColors.tertiaryText(colorScheme))

                            HStack(spacing: 6) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 6, height: 6)
                                Text(result.backendType.displayName)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                            Text(benchmarkManager.formattedLatency(result.totalLatencyMs))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundColor(.orange)

                            Text(benchmarkManager.formattedRTF(result.realTimeFactor))
                                .frame(width: 60, alignment: .trailing)
                                .foregroundColor(.cyan)

                            Text("\(result.wordCount)")
                                .frame(width: 60, alignment: .trailing)
                                .foregroundColor(WhispererColors.secondaryText(colorScheme))

                            Text(benchmarkManager.formattedMemory(result.memoryDeltaMB))
                                .frame(width: 80, alignment: .trailing)
                                .foregroundColor(.red)
                        }
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)

                        if index < benchmarkManager.results.count - 1 {
                            Rectangle()
                                .fill(WhispererColors.border(colorScheme))
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.3))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Transcription Output

    private func transcriptionOutputCard(_ result: BenchmarkResult) -> some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 12) {
                SettingsSectionHeader(
                    icon: "text.quote",
                    title: "Last Transcription Output",
                    colorScheme: colorScheme,
                    color: WhispererColors.accentBlue
                )

                Text(result.transcribedText.isEmpty ? "No speech detected" : result.transcribedText)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(
                        result.transcribedText.isEmpty
                            ? WhispererColors.tertiaryText(colorScheme)
                            : WhispererColors.primaryText(colorScheme)
                    )
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
