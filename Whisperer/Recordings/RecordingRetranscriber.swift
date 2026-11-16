//
//  RecordingRetranscriber.swift
//  Whisperer
//
//  Re-transcribes a dictation or an imported file from its saved audio, in the language the user picks.
//  One engine for both: the chunked decode an import uses, so a file keeps real paragraph times. The
//  recognizer's original text stays in the row; the new text is stored as the edited version, as
//  `HistoryManager.retranscribe` always did. Meetings re-transcribe through `MeetingTranscriptRefiner`.
//

import Combine
import Foundation

@MainActor
final class RecordingRetranscriber: ObservableObject {
    static let shared = RecordingRetranscriber()

    @Published private(set) var runningID: RecordingID?
    @Published private(set) var failure: String?

    private init() {}

    /// Why the action is unavailable, or nil when it can run.
    func unavailableReason(for document: TranscriptDocument) -> String? {
        if document.audioURL == nil { return "This recording has no audio on this Mac." }
        if AppState.shared.fileTranscriptionBridge == nil { return "The transcription model is still loading." }
        if AppState.shared.state != .idle { return "Finish the current recording first." }
        if runningID != nil { return "Another recording is being re-transcribed." }
        return nil
    }

    func start(_ document: TranscriptDocument, language: TranscriptionLanguage) {
        guard unavailableReason(for: document) == nil, document.id.store == .transcription,
              let audioURL = document.audioURL, let bridge = AppState.shared.fileTranscriptionBridge,
              let record = HistoryManager.shared.record(id: document.id.uuid) else { return }
        failure = nil
        runningID = document.id
        let manager = AppState.shared.fileTranscriptionManager
        let isFile = document.kind == .file

        Task { [weak self] in
            do {
                let samples = try await manager.loadAudioSamples(from: audioURL)
                let result = await Self.transcribe(samples: samples, bridge: bridge, language: language, manager: manager)
                guard !result.text.isEmpty else { throw FileTranscriptionError.transcriptionFailed }
                let corrected = DictionaryManager.shared.correctTextCapturing(result.text).text
                let detected = language == .auto ? bridge.lastDetectedLanguage : nil
                try await HistoryManager.shared.retranscribe(
                    record, newText: corrected, language: detected ?? language.rawValue,
                    modelUsed: AppState.shared.activeModelDisplayName)
                if isFile {
                    let paragraphs = FileTranscriptParagraphs.split(corrected, anchors: result.anchors)
                    let stored = paragraphs.map { StoredParagraph(text: $0.text, start: $0.start, end: nil) }
                    let json = (try? JSONEncoder().encode(stored)).flatMap { String(data: $0, encoding: .utf8) }
                    HistoryManager.shared.update(id: record.id) { $0.paragraphsJSON = json }
                }
                self?.runningID = nil
                NotificationCenter.default.post(name: .recordingDidChange, object: document.id.uuid)
            } catch {
                Logger.error("Re-transcription failed: \(error.localizedDescription)", subsystem: .transcription)
                self?.failure = "Re-transcription failed."
                self?.runningID = nil
            }
        }
    }

    /// The import's chunked decode: 30 s windows with a half-second overlap, the previous text as context.
    private static func transcribe(samples: [Float], bridge: any TranscriptionBackend, language: TranscriptionLanguage,
                                   manager: FileTranscriptionManager) async -> (text: String, anchors: [FileTranscriptAnchor]) {
        let rate = manager.sampleRate
        let chunkSamples = Int(manager.chunkDuration * rate), overlap = Int(manager.overlapDuration * rate)
        let contextMax = manager.contextMaxLength
        let prompt = AppState.shared.promptWordsString
        return await Task.detached(priority: .userInitiated) {
            var text = "", words = 0
            var anchors: [FileTranscriptAnchor] = []
            let chunks = max(1, Int(ceil(Double(samples.count) / Double(chunkSamples))))
            for index in 0..<chunks {
                let start = index * chunkSamples
                anchors.append(FileTranscriptAnchor(word: words, seconds: Double(start) / rate))
                let slice = Array(samples[max(0, start - overlap)..<min(start + chunkSamples, samples.count)])
                let context = text.isEmpty ? nil : String(text.suffix(contextMax))
                let combined = [prompt, context].compactMap { $0 }.joined(separator: " ")
                let piece = bridge.transcribe(samples: slice, initialPrompt: combined.isEmpty ? nil : combined,
                                              language: language, singleSegment: false, maxTokens: 0)
                let deduped = await manager.deduplicateOverlap(previousText: text, newText: piece)
                guard !deduped.isEmpty else { continue }
                text += text.isEmpty ? deduped : " " + deduped
                words += FileTranscriptParagraphs.wordCount(deduped)
            }
            anchors.append(FileTranscriptAnchor(word: words, seconds: Double(samples.count) / rate))
            return (text, anchors)
        }.value
    }
}

extension Notification.Name {
    /// A recording's stored content changed in a way the open reader should pick up. `object` is the UUID.
    static let recordingDidChange = Notification.Name("recordingDidChange")
}
