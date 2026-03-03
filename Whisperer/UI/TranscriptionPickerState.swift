//
//  TranscriptionPickerState.swift
//  Whisperer
//
//  State management for the transcription picker overlay (Option+V).
//

import AppKit
import Combine

struct PickerItem: Identifiable {
    let id: UUID
    let text: String
    let timestamp: Date
    let wordCount: Int
}

@MainActor
class TranscriptionPickerState: ObservableObject {
    static let shared = TranscriptionPickerState()

    @Published var isVisible: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var items: [PickerItem] = []
    @Published var showCopiedFeedback: Bool = false

    private init() {}

    // MARK: - Public Methods

    func show() {
        let transcriptions = Array(HistoryManager.shared.transcriptions.prefix(10))
        guard !transcriptions.isEmpty else {
            Logger.debug("Picker: no transcriptions available", subsystem: .ui)
            return
        }

        items = transcriptions.map { record in
            PickerItem(
                id: record.id,
                text: record.displayText,
                timestamp: record.timestamp,
                wordCount: record.wordCount
            )
        }
        selectedIndex = 0
        showCopiedFeedback = false
        isVisible = true
        Logger.info("Transcription picker shown with \(items.count) items", subsystem: .ui)
    }

    func cycleNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
    }

    func confirmSelection() {
        guard isVisible, selectedIndex < items.count else {
            dismiss()
            return
        }

        let text = items[selectedIndex].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Logger.info("Picker: copied transcription to clipboard (\(text.prefix(40))...)", subsystem: .ui)

        showCopiedFeedback = true

        // Auto-dismiss after brief feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        isVisible = false
        showCopiedFeedback = false
        items = []
        selectedIndex = 0
    }
}
