//
//  MCPHTTPCompat.swift
//  Whisperer
//
//  Compatibility shims that let MCP clients connect however they speak HTTP:
//
//  • LenientAcceptValidator — the SDK's AcceptHeaderValidator(.sseRequired) rejects any POST
//    whose Accept header does not list BOTH application/json and text/event-stream (406).
//    Plenty of clients (curl, simple HTTP clients, some IDEs) send only one, `*/*`, or none.
//  • MCPSSECollapser — StatefulHTTPServerTransport always answers a POST with an SSE stream.
//    A client that did not ask for text/event-stream gets the JSON-RPC response as a plain
//    application/json body instead (the spec allows either).
//  • MCPJSONRPCIDRemapper — sessionless requests all share one stateless transport, which
//    matches responses to waiters by JSON-RPC id. Two clients both sending `"id": 1` would
//    collide, so each request gets a unique id on the way in and its own id back on the way out.
//

import Foundation
import MCP

// MARK: - Lenient Accept validator

nonisolated struct LenientAcceptValidator: HTTPRequestValidator {

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let accept = MCPAcceptHeader(request.header(HTTPHeaderName.accept))
        switch context.httpMethod {
        case "POST":
            guard accept.allowsJSONResponse || accept.allowsSSE else {
                return .error(statusCode: 406,
                              .invalidRequest("Not Acceptable: Client must accept application/json or text/event-stream"),
                              sessionID: context.sessionID)
            }
        case "GET":
            guard accept.allowsSSE else {
                return .error(statusCode: 406,
                              .invalidRequest("Not Acceptable: Client must accept text/event-stream"),
                              sessionID: context.sessionID)
            }
        default:
            break
        }
        return nil
    }
}

/// Parsed Accept header. An absent or empty header means "anything".
nonisolated struct MCPAcceptHeader: Equatable {
    let types: [String]

    init(_ raw: String?) {
        types = (raw ?? "")
            .split(separator: ",")
            .map { $0.split(separator: ";").first.map(String.init) ?? "" }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var isWildcard: Bool { types.isEmpty || types.contains("*/*") }

    var allowsSSE: Bool { isWildcard || types.contains("text/event-stream") || types.contains("text/*") }
    var allowsJSONResponse: Bool {
        isWildcard || types.contains("application/json") || types.contains("application/*")
    }
    /// True when the client explicitly listed text/event-stream — only then do we stream a
    /// POST response. A wildcard or JSON-only client gets a single JSON body.
    var explicitlyWantsSSE: Bool { types.contains("text/event-stream") }
}

// MARK: - SSE → JSON collapser

nonisolated enum MCPSSECollapser {

    struct Event: Equatable {
        var event: String?
        var data: String
    }

    /// Splits complete SSE events off the front of `buffer`. Incomplete trailing text is
    /// returned as `remainder`. Handles `\n` and `\r\n` line endings, multi-line `data:`,
    /// and comment lines (`:`).
    static func parseEvents(_ buffer: String) -> (events: [Event], remainder: String) {
        let normalized = buffer.replacingOccurrences(of: "\r\n", with: "\n")
        var events: [Event] = []
        var blocks = normalized.components(separatedBy: "\n\n")
        let remainder = blocks.removeLast()   // text after the last blank line (maybe empty)
        for block in blocks {
            var name: String?
            var dataLines: [String] = []
            for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix(":") { continue }
                if line.hasPrefix("data:") {
                    var v = line.dropFirst(5)
                    if v.hasPrefix(" ") { v = v.dropFirst() }
                    dataLines.append(String(v))
                } else if line.hasPrefix("event:") {
                    name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                }
            }
            if !dataLines.isEmpty || name != nil {
                events.append(Event(event: name, data: dataLines.joined(separator: "\n")))
            }
        }
        return (events, remainder)
    }

    /// True when `data` is a JSON-RPC response object (has an id and a result or error).
    static func isJSONRPCResponse(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        guard let id = obj["id"], !(id is NSNull) else { return false }
        return obj["result"] != nil || obj["error"] != nil
    }

    /// Returns the first JSON-RPC response carried by the SSE stream, or nil if the stream
    /// ends (or `timeout` passes) without one.
    static func firstResponse(in stream: AsyncThrowingStream<Data, Error>,
                              timeout: Duration = .seconds(60)) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var buffer = ""
                do {
                    for try await chunk in stream {
                        buffer += String(decoding: chunk, as: UTF8.self)
                        let (events, rest) = parseEvents(buffer)
                        buffer = rest
                        for e in events {
                            let d = Data(e.data.utf8)
                            if isJSONRPCResponse(d) { return d }
                        }
                    }
                } catch {
                    return nil
                }
                // Stream ended — a final event may lack the trailing blank line.
                let (events, _) = parseEvents(buffer + "\n\n")
                return events.map { Data($0.data.utf8) }.first(where: isJSONRPCResponse)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - JSON-RPC id remapping

nonisolated enum MCPJSONRPCIDRemapper {

    /// Replaces the request's `id` with `newID`. Returns the rewritten body and the original id
    /// (as a JSON fragment), or nil when the body is not a JSON-RPC request with an id.
    static func replaceID(in body: Data, with newID: String) -> (body: Data, originalID: Data)? {
        guard var obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = obj["id"], !(id is NSNull),
              let original = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed)
        else { return nil }
        obj["id"] = newID
        guard let rewritten = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return (rewritten, original)
    }

    /// Puts `originalID` back into a JSON-RPC response body.
    static func restoreID(in body: Data, originalID: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let id = try? JSONSerialization.jsonObject(with: originalID, options: .fragmentsAllowed),
              obj["id"] != nil
        else { return body }
        obj["id"] = id
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? body
    }
}
