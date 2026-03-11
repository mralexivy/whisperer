//
//  CommandModeView.swift
//  Whisperer
//
//  Chat-style command mode UI (non-sandboxed builds only)
//

#if !APP_STORE

import SwiftUI

struct CommandModeView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var commandService: CommandModeService
    @StateObject private var historyStore = ChatHistoryStore.shared

    @State private var textInput = ""
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            commandHeader
            Divider().background(WhispererColors.border(colorScheme))

            if commandService.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            // Pending command confirmation
            if let pending = commandService.pendingCommand {
                pendingCommandCard(pending)
            }

            Divider().background(WhispererColors.border(colorScheme))
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WhispererColors.background(colorScheme))
    }

    // MARK: - Header

    private var commandHeader: some View {
        HStack {
            SettingsSectionHeader(
                icon: "terminal.fill",
                title: "Command Mode",
                colorScheme: colorScheme,
                color: Color(hex: "22C55E")
            )

            Spacer()

            Button(action: {
                commandService.clearConversation()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                    Text("New Chat")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
            .buttonStyle(.plain).pointerOnHover()

            Button(action: {
                showHistory.toggle()
            }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13))
                    .foregroundColor(WhispererColors.secondaryText(colorScheme))
            }
            .buttonStyle(.plain).pointerOnHover()
            .popover(isPresented: $showHistory) {
                historyPopover
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(commandService.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: commandService.messages.count) { _ in
                if let last = commandService.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(message.role == .tool
                        ? .system(size: 12, weight: .regular, design: .monospaced)
                        : .system(size: 13, weight: .regular))
                    .foregroundColor(WhispererColors.primaryText(colorScheme))
                    .textSelection(.enabled)
                    .lineSpacing(4)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(bubbleColor(for: message.role))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(bubbleBorder(for: message.role), lineWidth: 1)
            )

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private func bubbleColor(for role: MessageRole) -> Color {
        switch role {
        case .user: return WhispererColors.accentBlue.opacity(0.12)
        case .assistant: return WhispererColors.cardBackground(colorScheme)
        case .tool: return WhispererColors.elevatedBackground(colorScheme)
        }
    }

    private func bubbleBorder(for role: MessageRole) -> Color {
        switch role {
        case .user: return WhispererColors.accentBlue.opacity(0.15)
        case .assistant: return WhispererColors.border(colorScheme)
        case .tool: return Color(hex: "22C55E").opacity(0.15)
        }
    }

    // MARK: - Pending Command

    private func pendingCommandCard(_ command: String) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(Color(hex: "F97316"))
                Text("Destructive command detected")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "F97316"))
            }

            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(WhispererColors.elevatedBackground(colorScheme))
                )

            HStack(spacing: 12) {
                Button("Cancel") {
                    commandService.cancelPendingCommand()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(WhispererColors.border(colorScheme)))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

                Button("Confirm") {
                    Task { await commandService.confirmPendingCommand() }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(hex: "EF4444")))
                .foregroundColor(.white)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(hex: "F97316").opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "F97316").opacity(0.2), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Type a command or use voice...", text: $textInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .onSubmit {
                    sendTextCommand()
                }

            if commandService.isProcessing {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
            } else {
                Button(action: sendTextCommand) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(textInput.isEmpty ? WhispererColors.tertiaryText(colorScheme) : WhispererColors.accentBlue)
                }
                .buttonStyle(.plain).pointerOnHover()
                .disabled(textInput.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color(hex: "22C55E").opacity(0.1))
                    .frame(width: 64, height: 64)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "22C55E"))
            }

            Text("Voice-Powered Terminal")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(WhispererColors.primaryText(colorScheme))

            Text("Hold the command shortcut and speak,\nor type a command below.")
                .font(.system(size: 13))
                .foregroundColor(WhispererColors.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - History Popover

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Chats")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(WhispererColors.primaryText(colorScheme))
                .padding(12)

            Divider()

            if historyStore.sessions.isEmpty {
                Text("No chat history")
                    .font(.system(size: 12))
                    .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(historyStore.sessions.prefix(10)) { session in
                            Button(action: {
                                commandService.messages = session.messages
                                showHistory = false
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(WhispererColors.primaryText(colorScheme))
                                        Text(session.createdAt, style: .relative)
                                            .font(.system(size: 10))
                                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                                    }
                                    Spacer()
                                    Button(action: {
                                        historyStore.deleteSession(session.id)
                                    }) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                            .foregroundColor(WhispererColors.tertiaryText(colorScheme))
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 240)
        .background(WhispererColors.cardBackground(colorScheme))
    }

    // MARK: - Actions

    private func sendTextCommand() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !commandService.isProcessing else { return }
        textInput = ""
        Task { await commandService.processVoiceCommand(text) }
    }
}

#endif
