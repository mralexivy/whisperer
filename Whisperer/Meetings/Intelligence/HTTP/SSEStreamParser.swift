//
//  SSEStreamParser.swift
//  Whisperer
//
//  Incremental Server-Sent Events parser for streaming model APIs.
//
//  Works on bytes, not strings: a network chunk can end in the middle of a multibyte UTF-8
//  character (every Hebrew letter is two bytes), so only complete lines are decoded.
//

import Foundation

nonisolated struct SSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

nonisolated struct SSEStreamParser: Sendable {
    private var buffer = Data()
    private var eventName: String?
    private var dataLines: [String] = []

    init() {}

    /// Feeds raw bytes, returning every event completed by them.
    mutating func feed(_ chunk: Data) -> [SSEEvent] {
        buffer.append(chunk)
        var events: [SSEEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if let event = handle(line: line) { events.append(event) }
        }
        return events
    }

    /// Flushes a final event that was not followed by a blank line.
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !buffer.isEmpty {
            let line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if let event = handle(line: line) { events.append(event) }
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func handle(line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }                      // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data":  dataLines.append(String(value))
        default:      break                                         // id, retry
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer { eventName = nil; dataLines.removeAll() }
        guard !dataLines.isEmpty else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}
