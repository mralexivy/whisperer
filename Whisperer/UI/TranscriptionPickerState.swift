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
    /// Bumped only when the hotkey moves the selection. The list scrolls to follow Option+V
    /// cycling, but must not yank itself around under a pointer that is already on a row.
    @Published private(set) var scrollToken: Int = 0

    /// Called when the picker is dismissed — use to sync external state (e.g. GlobalKeyListener.pickerVisible).
    var onDismiss: (() -> Void)?
    /// Called when the picker actually appears. Paired with `onDismiss`, this brackets the
    /// window in which Escape is claimed — both hooks fire however the picker was opened,
    /// by Option+V or by the Island launcher.
    var onShow: (() -> Void)?

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
        scrollToken &+= 1
        onShow?()
        Logger.info("Transcription picker shown with \(items.count) items", subsystem: .ui)
    }

    func cycleNext() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        scrollToken &+= 1
    }

    /// Pointer moved onto a row. Moves the highlight without scrolling the list.
    func highlight(index: Int) {
        guard isVisible, items.indices.contains(index) else { return }
        selectedIndex = index
    }

    /// Pointer clicked a row — select and copy in one step.
    func choose(index: Int) {
        guard isVisible, items.indices.contains(index) else { return }
        selectedIndex = index
        confirmSelection()
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
        onDismiss?()
    }
}
