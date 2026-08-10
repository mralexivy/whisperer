//
//  MeetingChatStore.swift
//  Whisperer
//
//  Persists Ask AI conversation history per meeting as a JSON file alongside
//  the meeting audio: <Meetings>/<meetingID>-chat.json
//

import Foundation

// MARK: - Message model

struct MeetingChatMessage: Codable, Identifiable {
    let id: UUID
    let role: String       // "user" | "assistant"
    let text: String
    let sources: [RAGChunk]?   // only populated for assistant messages
    let createdAt: Date

    init(id: UUID = UUID(), role: String, text: String,
         sources: [RAGChunk]? = nil, createdAt: Date = Date()) {
        self.id        = id
        self.role      = role
        self.text      = text
        self.sources   = sources
        self.createdAt = createdAt
    }
}

// MARK: - Store

actor MeetingChatStore {
    static let shared = MeetingChatStore()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static var meetingsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Whisperer/Meetings", isDirectory: true)
    }

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public API

    func load(meetingID: UUID) async -> [MeetingChatMessage] {
        let url = chatURL(for: meetingID)
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([MeetingChatMessage].self, from: data)) ?? []
    }

    func append(_ message: MeetingChatMessage, meetingID: UUID) async {
        var messages = await load(meetingID: meetingID)
        messages.append(message)
        write(messages, to: chatURL(for: meetingID))
    }

    func clear(meetingID: UUID) async {
        try? FileManager.default.removeItem(at: chatURL(for: meetingID))
    }

    // MARK: - Private

    private func chatURL(for meetingID: UUID) -> URL {
        Self.meetingsDir.appendingPathComponent("\(meetingID)-chat.json")
    }

    private func write(_ messages: [MeetingChatMessage], to url: URL) {
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
