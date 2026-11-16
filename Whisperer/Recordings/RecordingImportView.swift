//
//  RecordingImportView.swift
//  Whisperer
//
//  The import flow, launched from the Recordings list: choose a file, pick the language, watch progress.
//  It is a flow, not a destination: when the file is saved, the recording opens in the shared reader.
//

import SwiftUI

struct RecordingImportView: View {
    @ObservedObject var model: RecordingsWorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.isImporting = false } label: {
                    Label("Recordings", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 4)
            FileTranscriptionView(onFinished: { id in model.open(.dictation(id)) })
        }
        .background(Color(hex: "0C0C1A"))
    }
}
