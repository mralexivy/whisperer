//
//  AcknowledgementsView.swift
//  Whisperer
//
//  Open-source model and library acknowledgements.
//

import AppKit
import SwiftUI

/// Owns the single Acknowledgements window so repeated clicks focus it rather than
/// stacking copies.
@MainActor
final class AcknowledgementsWindowManager: NSObject, NSWindowDelegate {
    static let shared = AcknowledgementsWindowManager()

    private var window: NSWindow?

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: AcknowledgementsView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "Acknowledgements"
        win.styleMask = [.titled, .closable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Acknowledgements")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Whisperer is built on open-source AI models and libraries.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Models section
                sectionHeader("AI Models")

                modelEntry(
                    name: "Qwen3-ASR-1.7B",
                    author: "Alibaba Cloud",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-8bit"
                )

                modelEntry(
                    name: "Qwen3.5-4B / 2B / 9B",
                    author: "Alibaba Cloud",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/Qwen"
                )

                modelEntry(
                    name: "Qwen3.5-4B MTPLX (Optimized Speed)",
                    author: "Youssofal",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed"
                )

                modelEntry(
                    name: "Qwen2.5-1.5B-Instruct",
                    author: "Alibaba Cloud",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-8bit"
                )

                modelEntry(
                    name: "Whisper Large V3 Turbo (Hebrew)",
                    author: "ivrit.ai",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml"
                )

                modelEntry(
                    name: "Nemotron-3 Diarization",
                    author: "NVIDIA",
                    license: "OpenMDW License v1.1",
                    url: "https://huggingface.co/FluidInference/nemotron-3-diarization-coreml"
                )

                modelEntry(
                    name: "Nemotron-3.5 ASR Streaming (Hebrew fine-tune)",
                    author: "NVIDIA, fine-tuned by Alex Ivy",
                    license: "OpenMDW License v1.1",
                    url: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b"
                )

                modelEntry(
                    name: "Parakeet TDT 0.6B (v2 / v3)",
                    author: "NVIDIA",
                    license: "CC-BY-4.0",
                    url: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3"
                )

                modelEntry(
                    name: "Aawaaz Qwen3-0.6B Transcriber",
                    author: "Shantanu Goel",
                    license: "Apache License 2.0",
                    url: "https://huggingface.co/shantanugoel/aawaaz-qwen3-0.6b-transcriber-4bit"
                )

                modelEntry(
                    name: "mmBERT-small (transcript polish base)",
                    author: "JHU CLSP",
                    license: "MIT License",
                    url: "https://huggingface.co/jhu-clsp/mmBERT-small"
                )

                modelEntry(
                    name: "Whisper (GGML)",
                    author: "OpenAI / Georgi Gerganov",
                    license: "MIT License",
                    url: "https://github.com/ggerganov/whisper.cpp"
                )

                modelEntry(
                    name: "WhisperKit",
                    author: "Argmax, Inc.",
                    license: "MIT License",
                    url: "https://github.com/argmaxinc/WhisperKit"
                )

                modelEntry(
                    name: "Silero VAD",
                    author: "Silero Team",
                    license: "MIT License",
                    url: "https://github.com/snakers4/silero-vad"
                )

                Divider()
                    .padding(.vertical, 8)

                // Libraries section
                sectionHeader("Libraries")

                libraryEntry(
                    name: "MLX Swift",
                    author: "Apple Machine Learning Research",
                    license: "MIT License",
                    url: "https://github.com/ml-explore/mlx-swift"
                )

                libraryEntry(
                    name: "MCP Swift SDK",
                    author: "Anthropic",
                    license: "MIT License",
                    url: "https://github.com/modelcontextprotocol/swift-sdk"
                )

                Spacer(minLength: 40)
            }
            .padding(24)
        }
        .frame(width: 680, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.top, 8)
    }

    private func modelEntry(name: String, author: String, license: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.body)
                .fontWeight(.medium)
            HStack(spacing: 4) {
                Text(author)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(license)
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
            Link(url, destination: URL(string: url)!)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }

    private func libraryEntry(name: String, author: String, license: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.body)
                .fontWeight(.medium)
            HStack(spacing: 4) {
                Text(author)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(license)
                    .font(.callout)
                    .foregroundStyle(.blue)
            }
            Link(url, destination: URL(string: url)!)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    AcknowledgementsView()
}
