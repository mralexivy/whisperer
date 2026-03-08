//
//  ChatHistoryStore.swift
//  Whisperer
//
//  Persists command mode chat sessions (non-sandboxed builds only)
//

#if !ENABLE_APP_SANDBOX

import Foundation
import Combine

struct CommandChatSession: Codable, Identifiable {
    let id: UUID
    var messages: [ChatMessage]
    let createdAt: Date
    var title: String

    init(messages: [ChatMessage] = [], title: String = "New Chat") {
        self.id = UUID()
        self.messages = messages
        self.createdAt = Date()
        self.title = title
    }
}

@MainActor
class ChatHistoryStore: ObservableObject {
    static let shared = ChatHistoryStore()

    @Published var sessions: [CommandChatSession] = []

    private let maxSessions = 50
    private var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("Whisperer/ChatHistory")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    private init() {
        loadSessions()
    }

    func saveSession(_ session: CommandChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }

        // Trim to max
        if sessions.count > maxSessions {
            sessions = Array(sessions.prefix(maxSessions))
        }

        persist()
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Private

    private func loadSessions() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            sessions = try JSONDecoder().decode([CommandChatSession].self, from: data)
        } catch {
            Logger.error("Failed to load chat sessions: \(error)", subsystem: .app)
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            Logger.error("Failed to save chat sessions: \(error)", subsystem: .app)
        }
    }
}

#endif
