//
//  AddDictionaryEntryView.swift
//  Whisperer
//
//  Modal for adding new dictionary entries
//

import SwiftUI

struct AddDictionaryEntryView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var dictionaryManager = DictionaryManager.shared

    @State private var incorrectForm = ""
    @State private var correctForm = ""
    @State private var category = ""
    @State private var notes = ""
    @State private var showValidationError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Dictionary Entry")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))

                Spacer()

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(WhispererColors.secondaryText(colorScheme))
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(WhispererColors.cardBackground(colorScheme))
            .overlay(
                Rectangle()
                    .fill(WhispererColors.border(colorScheme))
                    .frame(height: 1),
                alignment: .bottom
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Instructions
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(WhispererColors.accent)

                        Text("Add terms that Whisper commonly mishears. The incorrect form should match what Whisper outputs.")
                            .font(.system(size: 13))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(WhispererColors.accent.opacity(0.1))
                    )

                    // Incorrect form
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Incorrect Form (as heard)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., post gress or cooper netties", text: $incorrectForm)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )

                        Text("Lowercase, exactly as Whisper transcribes it")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.7))
                    }

                    // Correct form
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Correct Form")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., PostgreSQL or Kubernetes", text: $correctForm)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )

                        Text("With proper capitalization")
                            .font(.system(size: 11))
                            .foregroundColor(WhispererColors.secondaryText(colorScheme).opacity(0.7))
                    }

                    // Category
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category (optional)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextField("e.g., Programming, DevOps, Cloud", text: $category)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .padding(14)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Notes (optional)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(WhispererColors.primaryText(colorScheme))

                        TextEditor(text: $notes)
                            .font(.system(size: 14))
                            .frame(height: 80)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WhispererColors.elevatedBackground(colorScheme))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                            )
                    }

                    // Preview
                    if !incorrectForm.isEmpty && !correctForm.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Preview")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(WhispererColors.primaryText(colorScheme))

                            HStack(spacing: 8) {
                                Text(incorrectForm)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
                                    .strikethrough()

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(WhispererColors.accent)

                                Text(correctForm)
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundColor(WhispererColors.accent)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(WhispererColors.accent.opacity(0.1))
                            )
                        }
                    }

                    // Error message
                    if showValidationError {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.red)

                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.red.opacity(0.1))
                        )
                    }
                }
                .padding(24)
            }

            // Footer buttons
            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(WhispererColors.primaryText(colorScheme))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(WhispererColors.elevatedBackground(colorScheme))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(WhispererColors.border(colorScheme), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button(action: addEntry) {
                    Text("Add Entry")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isValid ? WhispererColors.accent : WhispererColors.secondaryText(colorScheme).opacity(0.3))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isValid)
            }
            .padding(24)
            .background(WhispererColors.cardBackground(colorScheme))
            .overlay(
                Rectangle()
                    .fill(WhispererColors.border(colorScheme))
                    .frame(height: 1),
                alignment: .top
            )
        }
        .frame(width: 600, height: 700)
        .background(WhispererColors.background(colorScheme))
    }

    private var isValid: Bool {
        !incorrectForm.trimmingCharacters(in: .whitespaces).isEmpty &&
        !correctForm.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func addEntry() {
        guard isValid else {
            errorMessage = "Please fill in both incorrect and correct forms"
            showValidationError = true
            return
        }

        let entry = DictionaryEntry(
            incorrectForm: incorrectForm.trimmingCharacters(in: .whitespaces),
            correctForm: correctForm.trimmingCharacters(in: .whitespaces),
            category: category.trimmingCharacters(in: .whitespaces).isEmpty ? nil : category.trimmingCharacters(in: .whitespaces),
            isBuiltIn: false,
            notes: notes.trimmingCharacters(in: .whitespaces).isEmpty ? nil : notes.trimmingCharacters(in: .whitespaces)
        )

        Task {
            do {
                try await dictionaryManager.addEntry(entry)
                dismiss()
            } catch {
                errorMessage = "Failed to add entry: \(error.localizedDescription)"
                showValidationError = true
            }
        }
    }
}
