//
//  MCPSessionRegistry.swift
//  Whisperer
//
//  Manages a bounded pool of concurrent MCP sessions — one per client.
//
//  The MCP HTTP transport (StatefulHTTPServerTransport) is single-session by design:
//  it holds one sessionID and hard-rejects re-initialization.  Instead of that being
//  a process-lifetime limit, this registry creates a *new* transport+server pair for
//  every initialize handshake and routes subsequent requests to the matching session
//  by Mcp-Session-Id header.
//
//  Session lifecycle:
//  - Created on the client's first POST initialize.
//  - Evicted on DELETE or when the server's waitUntilCompleted() returns.
//  - Idle sessions (no open SSE streams, lastActivity older than idleTimeout) are
//    reaped by a periodic background task.
//  - At most maxSessions sessions coexist; the oldest idle session is evicted to
//    make room, else 503 is returned.
//

import Foundation
import MCP

// MARK: - Fixed session ID generator

/// A SessionIDGenerator that returns a pre-minted id, allowing the registry to
/// assign the id before the transport validates requests against it.
private struct FixedSessionIDGenerator: SessionIDGenerator {
    let id: String
    func generateSessionID() -> String { id }
}

// MARK: - Session container

private final class MCPSession: @unchecked Sendable {
    let transport: StatefulHTTPServerTransport
    let server: Server
    let supervisor: Task<Void, Never>
    var lastActivity: Date = Date()
    var openStreams: Int = 0
    var clientName: String?

    init(transport: StatefulHTTPServerTransport,
         server: Server,
         supervisor: Task<Void, Never>) {
        self.transport = transport
        self.server = server
        self.supervisor = supervisor
    }
}

// MARK: - Registry

actor MCPSessionRegistry {

    // MARK: Configuration

    private let maxSessions: Int = 8
    private let idleTimeout: TimeInterval = 3600  // 60 minutes

    // MARK: State

    private var sessions: [String: MCPSession] = [:]
    private var reaperTask: Task<Void, Never>?

    /// Called once when the server listener starts.
    func startReaper() {
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { break }
                await self.reapIdle()
            }
        }
    }

    /// Called when the listener stops.  Tears down every live session.
    func shutdown() async {
        reaperTask?.cancel()
        reaperTask = nil

        for (id, session) in sessions {
            session.supervisor.cancel()
            await session.server.stop()
            Logger.info("MCP session evicted on shutdown: \(id)", subsystem: .app)
        }
        sessions.removeAll()
    }

    // MARK: - Routing

    /// Primary entry point: called once per HTTP request from handleConnection.
    func route(_ request: HTTPRequest,
               lanEnabled: Bool,
               port: Int) async -> HTTPResponse {

        let sessionID = request.header(HTTPHeaderName.sessionID)

        if let sid = sessionID {
            // Route to existing session.
            if let session = sessions[sid] {
                session.lastActivity = Date()
                let response = await session.transport.handleRequest(request)
                // Evict on DELETE after the transport has replied.
                if request.method.uppercased() == "DELETE" {
                    await evict(id: sid)
                }
                return response
            } else {
                // Unknown or expired session id — match SDK wording exactly.
                return makeErrorResponse(status: 404,
                    message: "Not Found: Invalid or expired session ID")
            }
        }

        // No session id: only allowed for POST initialize.
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeBody(body) {
            return await makeSession(request: request, lanEnabled: lanEnabled, port: port)
        }

        return makeErrorResponse(status: 400,
            message: "Bad Request: Session not initialized")
    }

    /// Called by the connection layer when an SSE stream opens.
    func streamOpened(id: String) {
        guard let session = sessions[id] else { return }
        session.openStreams += 1
        session.lastActivity = Date()
    }

    /// Called by the connection layer when an SSE stream closes.
    func streamClosed(id: String) {
        guard let session = sessions[id] else { return }
        session.openStreams = max(0, session.openStreams - 1)
        session.lastActivity = Date()
    }

    // MARK: - Session creation

    private func makeSession(request: HTTPRequest,
                             lanEnabled: Bool,
                             port: Int) async -> HTTPResponse {
        // Enforce cap: try to evict the oldest idle session.
        if sessions.count >= maxSessions {
            if let oldest = sessions.sorted(by: { $0.value.lastActivity < $1.value.lastActivity })
                                    .first(where: { $0.value.openStreams == 0 }) {
                await evict(id: oldest.key)
            } else {
                Logger.warning("MCP: session cap reached (\(maxSessions)), no idle slot — 503", subsystem: .app)
                return HTTPResponse.textBody(status: 503,
                    headers: ["Retry-After": "5"],
                    body: "Too many active MCP sessions")
            }
        }

        let id = UUID().uuidString

        let originValidator: OriginValidator = lanEnabled
            ? .disabled
            : .localhost(port: port)

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(id: id),
            validationPipeline: StandardValidationPipeline(validators: [
                originValidator,
                AcceptHeaderValidator(mode: .sseRequired),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
                SessionValidator(),
            ])
        )

        let server = await makeMCPServer()

        do {
            try await server.start(transport: transport)
        } catch {
            Logger.error("MCP: failed to start session \(id): \(error)", subsystem: .app)
            return makeErrorResponse(status: 500, message: "Internal error: could not start session")
        }

        let supervisor = Task { [weak self] in
            await server.waitUntilCompleted()
            await self?.remove(id: id)
        }

        let session = MCPSession(transport: transport, server: server, supervisor: supervisor)

        // Capture client name from initialize body for logging.
        if let body = request.body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let params = json["params"] as? [String: Any],
           let info = params["clientInfo"] as? [String: Any],
           let name = info["name"] as? String {
            session.clientName = name
        }

        sessions[id] = session
        Logger.info("MCP session created: \(id) client=\(session.clientName ?? "unknown") total=\(sessions.count)", subsystem: .app)

        return await transport.handleRequest(request)
    }

    // MARK: - Eviction

    private func evict(id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        session.supervisor.cancel()
        await session.server.stop()
        Logger.info("MCP session evicted: \(id) remaining=\(sessions.count)", subsystem: .app)
    }

    /// Called by the supervisor task when a server finishes naturally.
    private func remove(id: String) {
        guard sessions[id] != nil else { return }
        sessions.removeValue(forKey: id)
        Logger.info("MCP session removed: \(id) remaining=\(sessions.count)", subsystem: .app)
    }

    private func reapIdle() async {
        let threshold = Date().addingTimeInterval(-idleTimeout)
        for (id, session) in sessions
            where session.openStreams == 0 && session.lastActivity < threshold {
            await evict(id: id)
        }
    }

    // MARK: - Helpers

    /// Checks whether the request body contains `"method": "initialize"`.
    private func isInitializeBody(_ data: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else { return false }
        return method == "initialize"
    }

    /// Builds and returns a JSON-RPC error response without a session id.
    private func makeErrorResponse(status: Int, message: String) -> HTTPResponse {
        return HTTPResponse.textBody(status: status, body: message)
    }
}

// MARK: - MCP server factory (shared by registry and tests)

/// Constructs a Server with the Whisperer tool handlers registered.
/// Called once per session — creating multiple servers is cheap.
func makeMCPServer() async -> Server {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let s = Server(
        name: "Whisperer",
        version: version,
        capabilities: .init(tools: .init())
    )

    await s.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: MCPMeetingTools.toolDefinitions + MCPTranscriptionTools.toolDefinitions)
    }

    await s.withMethodHandler(CallTool.self) { params in
        if let result = try await MCPMeetingTools.handle(name: params.name, arguments: params.arguments) {
            return result
        }
        if let result = try await MCPTranscriptionTools.handle(name: params.name, arguments: params.arguments) {
            return result
        }
        return CallTool.Result(
            content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
            isError: true
        )
    }

    return s
}

// MARK: - HTTPResponse convenience

private extension HTTPResponse {
    /// A plain-text response for status codes that don't map to an SDK enum case.
    /// We abuse .error() since it sets the status code we want and serialises a body.
    static func textBody(status: Int, headers: [String: String] = [:], body: String) -> HTTPResponse {
        // .error takes an MCPError — use internalError for 503, invalidRequest for 400/404.
        // The body we really want is plain text, but the transport will re-serialise it as
        // JSON-RPC anyway.  Use a fabricated MCPError whose message is our text.
        let mcpErr: MCPError
        switch status {
        case 400: mcpErr = .invalidRequest(body)
        case 404: mcpErr = .invalidRequest(body)
        default:  mcpErr = .internalError(body)
        }
        return .error(statusCode: status, mcpErr, sessionID: nil,
                      extraHeaders: headers)
    }
}
