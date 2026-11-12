//
//  HistoryArchiveSection.swift
//  Whisperer
//
//  Settings → Move History: take everything the app has recorded to another Mac, or bring it in.
//  Engine and format: `HistoryArchive`. This file is the model and the card; the card follows the
//  Choice List pattern (DESIGN.md): two rows, the chosen one unfolds in place — no sheets.
//

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

@MainActor
final class HistoryArchiveModel: ObservableObject {

    enum Panel: Equatable { case none, export, `import`, cloud }

    enum RangePreset: String, CaseIterable, Identifiable {
        case all = "All time", lastYear = "Past year", last30 = "Past 30 days", custom = "Custom"
        var id: String { rawValue }
    }

    enum SplitPreset: String, CaseIterable, Identifiable {
        case single = "One file", gb4 = "4 GB parts", gb1 = "1 GB parts", mb250 = "250 MB parts"
        var id: String { rawValue }
        var bytes: Int64? {
            switch self {
            case .single: return nil
            case .gb4: return 4_000_000_000
            case .gb1: return 1_000_000_000
            case .mb250: return 250_000_000
            }
        }
    }

    enum State: Equatable {
        case idle
        case working(phase: String, fraction: Double, detail: String?)
        case finished(lines: [String], revealing: [URL])
        case failed(String)
    }

    struct ImportFile: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var manifest: HistoryArchive.Manifest?
        var error: String?
    }

    @Published var panel: Panel = .none
    @Published var state: State = .idle

    // Export
    @Published var categories: Set<HistoryArchive.Category> = Set(HistoryArchive.Category.allCases) { didSet { exportChanged() } }
    @Published var includeAudio = true { didSet { exportChanged() } }
    @Published var range: RangePreset = .all { didSet { exportChanged() } }
    @Published var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date() { didSet { exportChanged() } }
    @Published var customTo = Date() { didSet { exportChanged() } }
    @Published var split: SplitPreset = .single { didSet { exportChanged() } }
    @Published private(set) var estimate: HistoryArchive.Estimate?
    @Published private(set) var isEstimating = false

    // Import
    @Published var files: [ImportFile] = []
    @Published var importCategories: Set<HistoryArchive.Category> = Set(HistoryArchive.Category.allCases)
    @Published var importAudio = true

    private var cancelFlag = HistoryArchive.CancelFlag()
    private var estimateTask: Task<Void, Never>?
    private let environment: HistoryArchive.Environment

    init(environment: HistoryArchive.Environment? = nil) {
        self.environment = environment ?? .app
    }

    /// Whisperer Cloud (paid sync) is not live yet: the row is built and tested, and shown only where
    /// the feature may be mentioned — never in the App Store build until it works (App Review rejects
    /// placeholders). Flip when the service ships (docs/exec-plans/cloud-sync.md).
    static var cloudRowVisible: Bool {
        #if APP_STORE
        return false
        #else
        return true
        #endif
    }

    var isBusy: Bool { if case .working = state { return true } else { return false } }

    private static var archiveType: UTType { UTType(filenameExtension: HistoryArchive.fileExtension) ?? .data }

    // MARK: Panels

    func toggle(_ target: Panel) {
        guard !isBusy else { return }
        panel = panel == target ? .none : target
        if panel != .none, case .finished = state { state = .idle }
        if panel == .export { refreshEstimate() }
    }

    // MARK: Export

    var exportOptions: HistoryArchive.ExportOptions {
        var options = HistoryArchive.ExportOptions()
        options.categories = categories
        options.includeAudio = includeAudio
        let now = Date()
        switch range {
        case .all: break
        case .lastYear: options.from = Calendar.current.date(byAdding: .year, value: -1, to: now)
        case .last30: options.from = Calendar.current.date(byAdding: .day, value: -30, to: now)
        case .custom:
            options.from = Calendar.current.startOfDay(for: min(customFrom, customTo))
            options.to = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: max(customFrom, customTo)))
        }
        options.maxPartBytes = split.bytes
        return options
    }

    private func exportChanged() {
        guard panel == .export else { return }
        refreshEstimate()
    }

    /// Recounts for the current choices. Reads ids and file sizes only; debounced because a toggle
    /// held down or a date wheel fires many changes.
    func refreshEstimate() {
        estimateTask?.cancel()
        let options = exportOptions
        guard !options.categories.isEmpty else { estimate = nil; isEstimating = false; return }
        isEstimating = true
        let env = environment
        estimateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let result = try? await HistoryArchive.estimate(options, env: env)
            guard !Task.isCancelled else { return }
            self?.estimate = result
            self?.isEstimating = false
        }
    }

    func chooseExportDestination() {
        guard !isBusy, !categories.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.message = split == .single
            ? "Saves your history in one file."
            : "Saves your history in several files named “… – part 1 of N”. Each one can be imported on its own."
        panel.nameFieldStringValue = HistoryArchive.suggestedFileName()
        panel.allowedContentTypes = [Self.archiveType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        startExport(to: url)
    }

    func startExport(to url: URL) {
        guard !isBusy else { return }
        cancelFlag = HistoryArchive.CancelFlag()
        let flag = cancelFlag
        let options = exportOptions
        let env = environment
        state = .working(phase: "Counting", fraction: 0, detail: nil)
        Task {
            do {
                let result = try await HistoryArchive.export(options, to: url, env: env, cancel: flag) { [weak self] p in
                    Task { @MainActor in self?.progressed(p) }
                }
                state = .finished(lines: Self.exportLines(result), revealing: result.files)
                NSWorkspace.shared.activateFileViewerSelecting(result.files)
            } catch HistoryArchive.ArchiveError.cancelled {
                state = .idle
            } catch {
                Logger.error("History export failed: \(error.localizedDescription)", subsystem: .app)
                state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Import

    func chooseImportFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import History"
        panel.message = "Choose one or more history files exported from Whisperer."
        panel.allowedContentTypes = [Self.archiveType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        Task { await add(panel.urls) }
    }

    /// Reads each file's manifest (not its contents) so the list can say what is in it.
    func add(_ urls: [URL]) async {
        panel = .import
        if case .finished = state { state = .idle }
        for url in urls where !files.contains(where: { $0.url == url }) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var file = ImportFile(url: url)
            do { file.manifest = try await HistoryArchive.preview(of: url) }
            catch { file.error = error.localizedDescription }
            files.append(file)
        }
        files.sort { ($0.manifest?.setID.uuidString ?? "", $0.manifest?.part ?? 0) < ($1.manifest?.setID.uuidString ?? "", $1.manifest?.part ?? 0) }
        let present = presentCategories
        importCategories = importCategories.intersection(present).isEmpty ? present : importCategories.intersection(present)
    }

    func remove(_ file: ImportFile) { files.removeAll { $0.id == file.id } }

    var readableFiles: [ImportFile] { files.filter { $0.manifest != nil } }

    var presentCategories: Set<HistoryArchive.Category> {
        Set(HistoryArchive.Category.allCases.filter { c in readableFiles.contains { $0.manifest!.count(c) > 0 } })
    }

    func importTotal(_ category: HistoryArchive.Category) -> Int {
        readableFiles.reduce(0) { $0 + $1.manifest!.count(category) }
    }

    var importHasAudio: Bool { readableFiles.contains { $0.manifest!.includesAudio && $0.manifest!.audioFiles > 0 } }
    var importAudioBytes: Int64 { readableFiles.reduce(0) { $0 + $1.manifest!.audioBytes } }

    /// Sets that are missing parts, so the list can say "2 of 3 chosen" — informational: a part
    /// imports fine alone.
    var incompleteSets: [(setID: UUID, have: Int, of: Int)] {
        Dictionary(grouping: readableFiles, by: { $0.manifest!.setID }).compactMap { id, group in
            let total = group[0].manifest!.parts
            return group.count < total ? (id, group.count, total) : nil
        }
    }

    func startImport() {
        guard !isBusy, !readableFiles.isEmpty else { return }
        cancelFlag = HistoryArchive.CancelFlag()
        let flag = cancelFlag
        var options = HistoryArchive.ImportOptions()
        options.categories = importCategories
        options.includeAudio = importAudio
        let urls = readableFiles.map(\.url)
        let env = environment
        state = .working(phase: "Reading", fraction: 0, detail: nil)
        Task {
            let scoped = urls.map { $0.startAccessingSecurityScopedResource() }
            defer { for (url, ok) in zip(urls, scoped) where ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await HistoryArchive.importArchives(urls, options: options, env: env, cancel: flag) { [weak self] p in
                    Task { @MainActor in self?.progressed(p) }
                }
                await MeetingManager.shared.loadMeetings()
                await HistoryManager.shared.loadTranscriptions()
                await DictionaryManager.shared.loadEntries()
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionSaved"), object: nil)
                files = []
                state = .finished(lines: Self.importLines(summary), revealing: [])
            } catch HistoryArchive.ArchiveError.cancelled {
                // What was merged stays; running the import again skips it.
                state = .failed("Import stopped. What was already added is kept — import again to continue.")
            } catch {
                Logger.error("History import failed: \(error.localizedDescription)", subsystem: .app)
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() { cancelFlag.cancel() }

    #if DEBUG
    func setEstimateForTesting(_ estimate: HistoryArchive.Estimate) { self.estimate = estimate; isEstimating = false }
    func setFilesForTesting(_ files: [ImportFile]) { self.files = files; importCategories = presentCategories }
    #endif

    private func progressed(_ p: HistoryArchive.Progress) {
        guard isBusy else { return }
        state = .working(phase: p.phase, fraction: p.fraction, detail: p.detail)
    }

    // MARK: Wording

    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? noun : (plural ?? noun + "s"))"
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func exportLines(_ result: HistoryArchive.ExportResult) -> [String] {
        var parts: [String] = []
        if let n = result.counts[.dictations], n > 0 { parts.append(count(n, "dictation")) }
        if let n = result.counts[.meetings], n > 0 { parts.append(count(n, "meeting")) }
        if let n = result.counts[.dictionary], n > 0 { parts.append(count(n, "dictionary word")) }
        if let n = result.counts[.commandChats], n > 0 { parts.append(count(n, "chat")) }
        var lines = ["Exported " + (parts.isEmpty ? "your settings records" : parts.joined(separator: ", ")) + "."]
        lines.append(result.files.count == 1
                     ? "\(size(result.archiveBytes)) in 1 file. Copy it to your other Mac, then choose Import history there."
                     : "\(size(result.archiveBytes)) in \(result.files.count) files. Copy them all to your other Mac and choose Import history there — in any order.")
        return lines
    }

    static func importLines(_ s: HistoryArchive.ImportSummary) -> [String] {
        var added: [String] = []
        if s.dictationsAdded > 0 { added.append(count(s.dictationsAdded, "dictation")) }
        if s.meetingsAdded > 0 { added.append(count(s.meetingsAdded, "meeting")) }
        if s.dictionaryAdded > 0 { added.append(count(s.dictionaryAdded, "dictionary word")) }
        if s.chatsAdded > 0 { added.append(count(s.chatsAdded, "chat")) }
        var lines = [added.isEmpty ? "Nothing new to add." : "Added " + added.joined(separator: ", ") + "."]
        if s.alreadyPresent > 0 { lines.append("\(count(s.alreadyPresent, "item")) were already here and were left as they are.") }
        if s.statisticsMerged { lines.append("Records such as your best streak were kept at the higher value.") }
        if s.audioMissing > 0 { lines.append("\(count(s.audioMissing, "recording")) had no audio in the file.") }
        return lines
    }
}

// MARK: - Card

struct HistoryArchiveSection: View {
    let colorScheme: ColorScheme
    @StateObject private var model: HistoryArchiveModel
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(colorScheme: ColorScheme, model: HistoryArchiveModel? = nil) {
        self.colorScheme = colorScheme
        _model = StateObject(wrappedValue: model ?? HistoryArchiveModel())
    }

    private var primary: Color { WhispererColors.primaryText(colorScheme) }
    private var secondary: Color { WhispererColors.secondaryText(colorScheme) }
    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }

    var body: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(icon: "arrow.up.arrow.down.square", title: "Move History",
                                      colorScheme: colorScheme, color: WhispererColors.accentBlue)
                Text("Move everything Whisperer has recorded to another Mac — dictations, meetings, recordings, dictionary and records. Export to a file, copy it across, and import it there. Importing only adds: nothing already here is replaced.")
                    .font(.system(size: 12)).foregroundColor(secondary)
                    .fixedSize(horizontal: false, vertical: true)

                choiceRow(.export, icon: "square.and.arrow.up", tint: WhispererColors.accentBlue,
                          title: "Export history", subtitle: "Save to a file, then copy it to another Mac")
                if model.panel == .export { exportPanel.transition(.move(edge: .top).combined(with: .opacity)) }

                choiceRow(.import, icon: "square.and.arrow.down", tint: .cyan,
                          title: "Import history", subtitle: "Add a history file from another Mac")
                if model.panel == .import { importPanel.transition(.move(edge: .top).combined(with: .opacity)) }

                if HistoryArchiveModel.cloudRowVisible {
                    choiceRow(.cloud, icon: "icloud.and.arrow.up", tint: .purple,
                              title: "Whisperer Cloud", subtitle: "Keep your history in sync across your Macs, automatically",
                              pill: "Coming soon")
                    if model.panel == .cloud { cloudPanel.transition(.move(edge: .top).combined(with: .opacity)) }
                }

                statusView
            }
        }
        .environment(\.uiTestScope, "transfer")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !model.isBusy else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.fileURL(from: provider), url.pathExtension.lowercased() == HistoryArchive.fileExtension { urls.append(url) }
                }
                await model.add(urls)
            }
            return true
        }
        .animation(spring, value: model.panel)
        .animation(spring, value: model.state)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    // MARK: Rows

    private func choiceRow(_ panel: HistoryArchiveModel.Panel, icon: String, tint: Color, title: String, subtitle: String,
                           pill: String? = nil) -> some View {
        let selected = model.panel == panel
        return Button { withAnimation(spring) { model.toggle(panel) } } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.15)).frame(width: 36, height: 36)
                    Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundColor(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(primary)
                        if let pill {
                            Text(pill).font(.system(size: 10, weight: .semibold)).foregroundColor(secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(secondary.opacity(0.15)))
                        }
                    }
                    Text(subtitle).font(.system(size: 12)).foregroundColor(secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(secondary)
                    .rotationEffect(.degrees(selected ? 90 : 0))
            }
            .padding(12)
            .contentShape(Rectangle())
            // Selection ring lives in the background so it can never swallow a click (DESIGN.md).
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(WhispererColors.elevatedBackground(colorScheme).opacity(selected ? 0.8 : 0.45))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? tint.opacity(0.5) : .clear, lineWidth: 1).allowsHitTesting(false))
            )
        }
        .buttonStyle(.plain).pointerOnHover()
        .disabled(model.isBusy)
        .uiTestFrame("transfer.row.\(rowName(panel))")
        .accessibilityIdentifier("history-\(rowName(panel))-row")
    }

    private func rowName(_ panel: HistoryArchiveModel.Panel) -> String {
        switch panel {
        case .export: return "export"
        case .import: return "import"
        case .cloud: return "cloud"
        case .none: return "none"
        }
    }

    private func sectionLabel(_ text: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.2)
                .foregroundColor(secondary.opacity(0.8))
            if let hint {
                Text(hint).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Cloud panel

    /// The shape of the paid sync offer, ready for the service (docs/exec-plans/cloud-sync.md). Nothing
    /// here can be bought or started yet, so the one action says so rather than doing nothing.
    private var cloudPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach([("lock.shield.fill", "End-to-end encrypted", "Your recordings and transcripts are encrypted on your Mac before they leave it. We cannot read them."),
                     ("arrow.triangle.2.circlepath", "Seamless sync", "New dictations and meetings appear on your other Macs in the background — nothing to export or copy."),
                     ("macbook.and.iphone", "A new Mac, instantly", "Sign in to the same Apple ID and your history is there, text first, recordings as you play them.")],
                    id: \.1) { icon, title, text in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7).fill(Color.purple.opacity(0.15)).frame(width: 28, height: 28)
                        Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                        Text(text).font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 12) {
                Text("Whisperer Cloud is a subscription and is not available yet. Until then, Export and Import move your history by file.")
                    .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                actionButton("Not available yet", icon: "icloud.and.arrow.up", id: "transfer.cloud.subscribe", enabled: false) { }
            }
        }
        .padding(.leading, 50)
    }

    // MARK: Export panel

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("What to include")
                VStack(spacing: 6) {
                    categoryRow(.dictations, "Dictations", "Every transcription", "mic.fill", WhispererColors.accentBlue, binding: exportBinding(.dictations))
                    categoryRow(.meetings, "Meetings", "Transcripts, summaries, notes, Ask-AI threads", "person.2.fill", .purple, binding: exportBinding(.meetings))
                    categoryRow(.dictionary, "Dictionary", "Your own words and corrections", "character.book.closed.fill", .orange, binding: exportBinding(.dictionary))
                    #if !APP_STORE
                    categoryRow(.commandChats, "Command chats", "Command Mode conversations", "bubble.left.and.bubble.right.fill", .pink, binding: exportBinding(.commandChats))
                    #endif
                    categoryRow(.statistics, "Records", "Best streak and typing speed. The rest of your statistics follow the history.", "chart.bar.fill", .teal, binding: exportBinding(.statistics))
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Time range", hint: "Only dictations and meetings recorded in this period.")
                chips(HistoryArchiveModel.RangePreset.allCases, selection: $model.range, id: "range")
                if model.range == .custom {
                    HStack(spacing: 10) {
                        DatePicker("From", selection: $model.customFrom, displayedComponents: .date).labelsHidden()
                        Text("to").font(.system(size: 12)).foregroundColor(secondary)
                        DatePicker("To", selection: $model.customTo, displayedComponents: .date).labelsHidden()
                    }
                    .transition(.opacity)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Recordings")
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include audio").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                        Text(audioHint).font(.system(size: 12)).foregroundColor(secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $model.includeAudio).toggleStyle(.switch).tint(WhispererColors.accentBlue).labelsHidden()
                        .uiTestFrame("transfer.export.audio")
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
            }

            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("File size", hint: "A large history can be split into smaller files — for a USB drive, a shared folder or a slow disk. Each file imports on its own, in any order.")
                chips(HistoryArchiveModel.SplitPreset.allCases, selection: $model.split, id: "split")
            }

            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(estimateHeadline).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                        .contentTransition(.numericText())
                    Text(estimateDetail).font(.system(size: 12)).foregroundColor(secondary)
                }
                Spacer()
                actionButton(model.isEstimating ? "Counting…" : "Export…", icon: "square.and.arrow.up", id: "transfer.export.run",
                             enabled: !model.categories.isEmpty && !model.isBusy) { model.chooseExportDestination() }
            }
            .padding(.top, 2)
        }
        .padding(.leading, 50)
    }

    private func exportBinding(_ c: HistoryArchive.Category) -> Binding<Bool> {
        Binding(get: { model.categories.contains(c) },
                set: { on in if on { model.categories.insert(c) } else { model.categories.remove(c) } })
    }

    private var audioHint: String {
        guard let e = model.estimate else { return "Recordings are the bulk of a history." }
        return model.includeAudio ? "\(HistoryArchiveModel.size(e.audioBytes)) of recordings" : "Text only — a fraction of the size, nothing to play back"
    }

    private var estimateHeadline: String {
        guard let e = model.estimate else { return model.categories.isEmpty ? "Nothing selected" : "Counting…" }
        let files = e.parts == 1 ? "1 file" : "\(e.parts) files"
        return "About \(HistoryArchiveModel.size(e.totalBytes)) · \(files)"
    }

    private var estimateDetail: String {
        guard let e = model.estimate else { return model.categories.isEmpty ? "Choose at least one thing to include." : " " }
        var parts: [String] = []
        if let n = e.counts[.dictations], model.categories.contains(.dictations) { parts.append(HistoryArchiveModel.count(n, "dictation")) }
        if let n = e.counts[.meetings], model.categories.contains(.meetings) { parts.append(HistoryArchiveModel.count(n, "meeting")) }
        if let n = e.counts[.dictionary], n > 0, model.categories.contains(.dictionary) { parts.append(HistoryArchiveModel.count(n, "dictionary word")) }
        return parts.joined(separator: " · ")
    }

    private func categoryRow(_ c: HistoryArchive.Category, _ title: String, _ subtitle: String, _ icon: String, _ tint: Color,
                             binding: Binding<Bool>) -> some View {
        let count = model.estimate?.counts[c]
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                Text(subtitle).font(.system(size: 11)).foregroundColor(secondary).lineLimit(2)
            }
            Spacer()
            if let count, c != .statistics {
                Text(count.formatted()).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(secondary)
                    .contentTransition(.numericText())
            }
            Toggle("", isOn: binding).toggleStyle(.switch).tint(WhispererColors.accentBlue).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
        .uiTestFrame("transfer.export.category.\(c.rawValue)")
    }

    private func chips<T: Identifiable & RawRepresentable & Hashable>(_ options: [T], selection: Binding<T>, id: String) -> some View where T.RawValue == String {
        HStack(spacing: 6) {
            ForEach(options) { option in
                let on = selection.wrappedValue == option
                Button { withAnimation(spring) { selection.wrappedValue = option } } label: {
                    Text(option.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(on ? .white : secondary)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(on ? WhispererColors.accentBlue : WhispererColors.elevatedBackground(colorScheme).opacity(0.6)))
                }
                .buttonStyle(.plain).pointerOnHover()
                .uiTestFrame("transfer.\(id).\(option.rawValue)")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Import panel

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.files.isEmpty {
                dropZone
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Files")
                    ForEach(model.files) { file in fileRow(file) }
                    Button { model.chooseImportFiles() } label: {
                        Label("Add more files…", systemImage: "plus").font(.system(size: 12, weight: .semibold))
                            .foregroundColor(WhispererColors.accentBlue)
                    }
                    .buttonStyle(.plain).pointerOnHover().disabled(model.isBusy)
                    if !model.incompleteSets.isEmpty {
                        Label(model.incompleteSets.map { "\($0.have) of \($0.of) files of one export chosen — the rest can be imported later." }.first ?? "",
                              systemImage: "info.circle")
                            .font(.system(size: 12)).foregroundColor(secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !model.readableFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("What to bring in", hint: "Anything already here is skipped, never replaced.")
                        ForEach(HistoryArchive.Category.allCases.filter { model.presentCategories.contains($0) }, id: \.self) { c in
                            importCategoryRow(c)
                        }
                        if model.importHasAudio {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Recordings").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
                                    Text("\(HistoryArchiveModel.size(model.importAudioBytes)) of audio").font(.system(size: 12)).foregroundColor(secondary)
                                }
                                Spacer()
                                Toggle("", isOn: $model.importAudio).toggleStyle(.switch).tint(WhispererColors.accentBlue).labelsHidden()
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
                        }
                    }
                    HStack {
                        Spacer()
                        actionButton("Import \(model.readableFiles.count == 1 ? "file" : "\(model.readableFiles.count) files")",
                                     icon: "square.and.arrow.down", id: "transfer.import.run",
                                     enabled: !model.importCategories.isEmpty && !model.isBusy) { model.startImport() }
                    }
                }
            }
        }
        .padding(.leading, 50)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 22)).foregroundColor(WhispererColors.accentBlue)
            Text("Drop history files here").font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
            Button { model.chooseImportFiles() } label: {
                Text("Choose files…").font(.system(size: 12, weight: .semibold)).foregroundColor(WhispererColors.accentBlue)
            }
            .buttonStyle(.plain).pointerOnHover().uiTestFrame("transfer.import.choose")
            Text("A file ending in .aar, made by Export history. Several files from one split export can be chosen together.")
                .font(.system(size: 11)).foregroundColor(secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .foregroundColor(dropTargeted ? WhispererColors.accentBlue : secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.accentBlue.opacity(dropTargeted ? 0.08 : 0)))
        )
    }

    private func fileRow(_ file: HistoryArchiveModel.ImportFile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: file.error == nil ? "doc.zipper" : "exclamationmark.triangle.fill")
                .font(.system(size: 15)).foregroundColor(file.error == nil ? WhispererColors.accentBlue : .red).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).foregroundColor(primary).lineLimit(1).truncationMode(.middle)
                Text(file.error ?? fileSummary(file.manifest!)).font(.system(size: 11)).foregroundColor(file.error == nil ? secondary : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { model.remove(file) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundColor(secondary.opacity(0.7))
            }
            .buttonStyle(.plain).pointerOnHover().disabled(model.isBusy)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
    }

    private func fileSummary(_ m: HistoryArchive.Manifest) -> String {
        var bits: [String] = []
        if m.parts > 1 { bits.append("Part \(m.part) of \(m.parts)") }
        if m.count(.dictations) > 0 { bits.append(HistoryArchiveModel.count(m.count(.dictations), "dictation")) }
        if m.count(.meetings) > 0 { bits.append(HistoryArchiveModel.count(m.count(.meetings), "meeting")) }
        if m.count(.dictionary) > 0 { bits.append("\(m.count(.dictionary)) dictionary words") }
        if m.audioBytes > 0 { bits.append(HistoryArchiveModel.size(m.audioBytes) + " audio") }
        if let a = m.oldest, let b = m.newest {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none
            bits.append("\(f.string(from: a)) – \(f.string(from: b))")
        }
        if let device = m.device, !device.isEmpty { bits.append("from \(device)") }
        return bits.joined(separator: " · ")
    }

    private func importCategoryRow(_ c: HistoryArchive.Category) -> some View {
        let title: String, icon: String, tint: Color
        switch c {
        case .dictations: (title, icon, tint) = ("Dictations", "mic.fill", WhispererColors.accentBlue)
        case .meetings: (title, icon, tint) = ("Meetings", "person.2.fill", .purple)
        case .dictionary: (title, icon, tint) = ("Dictionary", "character.book.closed.fill", .orange)
        case .commandChats: (title, icon, tint) = ("Command chats", "bubble.left.and.bubble.right.fill", .pink)
        case .statistics: (title, icon, tint) = ("Records", "chart.bar.fill", .teal)
        }
        let binding = Binding(get: { model.importCategories.contains(c) },
                              set: { on in if on { model.importCategories.insert(c) } else { model.importCategories.remove(c) } })
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.15)).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundColor(tint)
            }
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(primary)
            Spacer()
            if c != .statistics {
                Text(model.importTotal(c).formatted()).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(secondary)
            }
            Toggle("", isOn: binding).toggleStyle(.switch).tint(WhispererColors.accentBlue).labelsHidden()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
    }

    // MARK: Status

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle:
            EmptyView()
        case .working(let phase, let fraction, let detail):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(max(fraction, 0), 1)).tint(WhispererColors.accentBlue)
                HStack {
                    Text(phase + "…").font(.system(size: 12, weight: .semibold)).foregroundColor(primary)
                    if let detail { Text(detail).font(.system(size: 12)).foregroundColor(secondary) }
                    Spacer()
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold)).foregroundColor(WhispererColors.accentBlue)
                        .pointerOnHover().uiTestFrame("transfer.cancel")
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(WhispererColors.elevatedBackground(colorScheme).opacity(0.5)))
            .transition(.opacity)
        case .finished(let lines, let revealing):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index == 0 {
                        Label(line, systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(.green)
                    } else {
                        Text(line).font(.system(size: 12)).foregroundColor(secondary)
                    }
                }
                if !revealing.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(revealing) } label: {
                        Text("Show in Finder").font(.system(size: 12, weight: .semibold)).foregroundColor(WhispererColors.accentBlue)
                    }.buttonStyle(.plain).pointerOnHover()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.scale(scale: 0.98).combined(with: .opacity))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func actionButton(_ title: String, icon: String, id: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.accentBlue.opacity(enabled ? 1 : 0.4)))
        }
        .buttonStyle(.plain).pointerOnHover().disabled(!enabled)
        .uiTestFrame(id)
        .accessibilityIdentifier(id)
    }
}
