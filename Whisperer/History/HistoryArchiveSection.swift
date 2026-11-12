//
//  HistoryArchiveSection.swift
//  Whisperer
//
//  Settings card: export all history to one file, import it into another workspace.
//  Engine and format: `HistoryArchive`.
//

import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor
final class HistoryArchiveModel: ObservableObject {
    enum State: Equatable {
        case idle
        case working(phase: String, fraction: Double)
        case finished(String)
        case failed(String)
    }

    @Published var state: State = .idle

    var isBusy: Bool { if case .working = state { return true } else { return false } }

    private static var archiveType: UTType { UTType(filenameExtension: HistoryArchive.fileExtension) ?? .data }

    func export() {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Export History"
        panel.message = "Saves every transcription and meeting, with their audio, in one file."
        panel.nameFieldStringValue = HistoryArchive.suggestedFileName()
        panel.allowedContentTypes = [Self.archiveType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        state = .working(phase: "Collecting", fraction: 0)
        Task {
            do {
                let summary = try await HistoryArchive.export(to: url) { [weak self] p in
                    Task { @MainActor in self?.state = .working(phase: p.phase, fraction: p.fraction) }
                }
                let size = ByteCountFormatter.string(fromByteCount: summary.archiveBytes, countStyle: .file)
                state = .finished("Exported \(Self.count(summary.transcriptions, "transcription")) and \(Self.count(summary.meetings, "meeting")) (\(size)).")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                Logger.error("History export failed: \(error.localizedDescription)", subsystem: .app)
                state = .failed(error.localizedDescription)
            }
        }
    }

    func importHistory() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Import History"
        panel.message = "Choose a history file exported from Whisperer. Nothing already here is replaced."
        panel.allowedContentTypes = [Self.archiveType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        state = .working(phase: "Reading archive", fraction: 0)
        Task {
            // A file picked in the sandbox is readable only while access is open.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let summary = try await HistoryArchive.importArchive(from: url) { [weak self] p in
                    Task { @MainActor in self?.state = .working(phase: p.phase, fraction: p.fraction) }
                }
                await MeetingManager.shared.loadMeetings()
                await HistoryManager.shared.loadTranscriptions()
                NotificationCenter.default.post(name: NSNotification.Name("TranscriptionSaved"), object: nil)
                var message = "Imported \(Self.count(summary.transcriptionsAdded, "transcription")) and \(Self.count(summary.meetingsAdded, "meeting"))"
                if summary.alreadyPresent > 0 { message += "; \(summary.alreadyPresent) already here" }
                if summary.audioMissing > 0 { message += "; \(Self.count(summary.audioMissing, "recording")) had no audio" }
                state = .finished(message + ".")
            } catch {
                Logger.error("History import failed: \(error.localizedDescription)", subsystem: .app)
                state = .failed(error.localizedDescription)
            }
        }
    }

    private static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

struct HistoryArchiveSection: View {
    let colorScheme: ColorScheme
    @StateObject private var model: HistoryArchiveModel

    @MainActor
    init(colorScheme: ColorScheme, model: HistoryArchiveModel? = nil) {
        self.colorScheme = colorScheme
        _model = StateObject(wrappedValue: model ?? HistoryArchiveModel())
    }

    var body: some View {
        SettingsCard(colorScheme: colorScheme) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSectionHeader(icon: "arrow.up.arrow.down.square", title: "Move History",
                                      colorScheme: colorScheme, color: WhispererColors.accentBlue)

                Text("Export every transcription and meeting, audio included, to one file. Import it in Whisperer on another Mac to bring your history along. Importing adds to what is already there and skips anything it already has.")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    archiveButton("Export History…", icon: "square.and.arrow.up", id: "history-export") { model.export() }
                    archiveButton("Import History…", icon: "square.and.arrow.down", id: "history-import") { model.importHistory() }
                    Spacer()
                }

                switch model.state {
                case .idle:
                    EmptyView()
                case .working(let phase, let fraction):
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: fraction)
                        Text(phase + "…")
                            .font(.system(size: 12))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                    }
                case .finished(let message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                        .fixedSize(horizontal: false, vertical: true)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func archiveButton(_ title: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(WhispererColors.accentBlue.opacity(model.isBusy ? 0.4 : 1)))
        }
        .buttonStyle(.plain)
        .pointerOnHover()
        .disabled(model.isBusy)
        .accessibilityIdentifier(id)
    }
}
