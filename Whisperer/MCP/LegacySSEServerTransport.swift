//
//  LegacySSEServerTransport.swift
//  Whisperer
//
//  Server side of the legacy MCP "HTTP+SSE" transport (protocol revision 2024-11-05),
//  still the only remote transport some clients and bridges speak:
//
//   1. Client opens `GET /sse`. The server keeps the response open as an event stream and
//      first sends   event: endpoint
//                    data: /messages?sessionId=<id>
//   2. Client POSTs each JSON-RPC message to that endpoint; the server answers 202 Accepted.
//   3. Every server → client message (responses, notifications) is sent on the SSE stream as
//                    event: message
//                    data: <json>
//
//  One transport (and one Server) exists per open GET /sse stream. When the client goes
//  away the stream's consumer stops, `onTermination` fires and the transport closes, which
//  ends the Server's receive loop so the registry's supervisor evicts the session.
//  A comment ping every 15 s makes a dead socket fail its write instead of hanging forever.
//

import Foundation
import Logging
import MCP

actor LegacySSEServerTransport: Transport {
    nonisolated let logger: Logging.Logger
    nonisolated let sessionID: String

    private let incoming: AsyncThrowingStream<Data, Error>
    private let incomingContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private let outgoingContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private var closed = false
    private var pingTask: Task<Void, Never>?

    /// Creates a transport and the SSE body for its GET /sse response.
    ///
    /// The event stream is handed out rather than stored: once the HTTP writer drops it
    /// (client gone), its storage is released, `onTermination` fires and the session ends.
    /// Keeping a reference here would keep it alive forever.
    ///
    /// - Parameter endpoint: the URL (usually relative) the client must POST messages to.
    nonisolated static func make(sessionID: String,
                     endpoint: String,
                     pingInterval: Duration = .seconds(15)) -> (LegacySSEServerTransport, AsyncThrowingStream<Data, Error>) {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let transport = LegacySSEServerTransport(sessionID: sessionID, endpoint: endpoint,
                                                 outgoing: continuation, pingInterval: pingInterval)
        return (transport, stream)
    }

    private init(sessionID: String,
                 endpoint: String,
                 outgoing: AsyncThrowingStream<Data, Error>.Continuation,
                 pingInterval: Duration) {
        self.sessionID = sessionID
        self.logger = Logging.Logger(label: "whisperer.mcp.legacy-sse",
                                     factory: { _ in SwiftLogNoOpLogHandler() })
        let inPair = AsyncThrowingStream<Data, Error>.makeStream()
        incoming = inPair.stream
        incomingContinuation = inPair.continuation
        outgoingContinuation = outgoing

        outgoing.yield(Self.event(name: "endpoint", data: endpoint))

        let incomingCont = inPair.continuation
        outgoing.onTermination = { _ in
            // The HTTP writer stopped consuming (client disconnected or server stopping).
            incomingCont.finish()
        }

        pingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                guard !Task.isCancelled else { break }
                if case .terminated = outgoing.yield(Data(": ping\n\n".utf8)) { break }
            }
        }
    }

    nonisolated static var responseHeaders: [String: String] {
        [
            HTTPHeaderName.contentType: "text/event-stream",
            HTTPHeaderName.cacheControl: "no-cache, no-transform",
            HTTPHeaderName.connection: "keep-alive",
        ]
    }

    /// Formats one SSE event. JSON never needs raw newlines, so any are stripped to keep the
    /// payload on a single `data:` line.
    nonisolated static func event(name: String, data: String) -> Data {
        let oneLine = data.replacingOccurrences(of: "\r", with: "")
                          .replacingOccurrences(of: "\n", with: "")
        return Data("event: \(name)\ndata: \(oneLine)\n\n".utf8)
    }

    // MARK: Transport

    func connect() async throws {}

    func disconnect() async {
        guard !closed else { return }
        closed = true
        pingTask?.cancel()
        pingTask = nil
        incomingContinuation.finish()
        outgoingContinuation.finish()
    }

    func send(_ data: Data) async throws {
        guard !closed else { throw MCPError.connectionClosed }
        let text = String(decoding: data, as: UTF8.self)
        if case .terminated = outgoingContinuation.yield(Self.event(name: "message", data: text)) {
            throw MCPError.connectionClosed
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> { incoming }

    // MARK: HTTP

    /// Handles a POST to the message endpoint.
    func handlePost(_ request: HTTPRequest) -> HTTPResponse {
        guard !closed else {
            return .error(statusCode: 404, .invalidRequest("Not Found: SSE session closed"))
        }
        guard let body = request.body, !body.isEmpty,
              (try? JSONSerialization.jsonObject(with: body)) != nil else {
            return .error(statusCode: 400, .parseError("Invalid JSON-RPC message"))
        }
        incomingContinuation.yield(body)
        return .accepted()
    }
}
