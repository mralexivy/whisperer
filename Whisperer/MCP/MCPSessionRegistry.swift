//
//  MCPSessionRegistry.swift
//  Whisperer
//
//  Routes every HTTP request the MCP listener receives, and manages a bounded pool of
//  concurrent MCP sessions — one per client.
//
//  Endpoints (query string ignored for routing):
//  - `/mcp`  Streamable HTTP (2025-03-26+). Stateful sessions keyed by Mcp-Session-Id; a
//            POST without a session that is not `initialize` is served by one shared
//            stateless transport, so plain HTTP clients / curl can call tools directly.
//            POST responses are SSE only when the client explicitly accepts
//            text/event-stream; otherwise they are collapsed to a single JSON body.
//  - `/sse` + `/messages?sessionId=`  legacy HTTP+SSE transport (2024-11-05).
//  - `/health`  unauthenticated liveness probe; reveals nothing sensitive.
//  - anything else → 404.
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
//    make room (falling back to the least-recently-active one).
//  - Legacy SSE sessions live exactly as long as their GET /sse stream, capped at
//    maxSessions as well (oldest evicted).
//
//  Authentication: see MCPAuthPolicy for the threat model. The token is optional on
//  loopback and always required when LAN access is on.
//

import Foundation
import MCP

// MARK: - Fixed session ID generator

/// A SessionIDGenerator that returns a pre-minted id, allowing the registry to
/// assign the id before the transport validates requests against it.
nonisolated private struct FixedSessionIDGenerator: SessionIDGenerator {
    let id: String
    func generateSessionID() -> String { id }
}

// MARK: - Session container

nonisolated private final class MCPSession: @unchecked Sendable {
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

nonisolated private final class LegacySSESession: @unchecked Sendable {
    let transport: LegacySSEServerTransport
    let server: Server
    var supervisor: Task<Void, Never>?
    let created = Date()

    init(transport: LegacySSEServerTransport, server: Server) {
        self.transport = transport
        self.server = server
    }
}

// MARK: - Registry

actor MCPSessionRegistry {

    // MARK: Configuration

    let maxSessions: Int = 8
    /// Reconnects from the same client reuse its own slots: past this many, the client's
    /// least-recently-active session is replaced rather than a new slot being taken.
    let maxSessionsPerClient: Int = 2
    private let idleTimeout: TimeInterval = 1800  // 30 minutes

    // MARK: State

    private var sessions: [String: MCPSession] = [:]
    private var legacySessions: [String: LegacySSESession] = [:]
    private var reaperTask: Task<Void, Never>?

    /// Shared transport for sessionless POSTs (plain HTTP clients). Created on first use.
    private var statelessTransport: StatelessHTTPServerTransport?
    private var statelessServer: Server?

    var legacySessionCount: Int { legacySessions.count }

    var sessionCount: Int { sessions.count }

    func sessionCount(forClient name: String) -> Int {
        sessions.values.filter { $0.clientName == name }.count
    }

    func sessionIDs(forClient name: String) -> Set<String> {
        Set(sessions.filter { $0.value.clientName == name }.keys)
    }

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

        for (_, session) in legacySessions {
            session.supervisor?.cancel()
            await session.server.stop()
        }
        legacySessions.removeAll()

        if let server = statelessServer { await server.stop() }
        statelessServer = nil
        statelessTransport = nil
    }

    // MARK: - Routing

    /// Primary entry point: called once per HTTP request from handleConnection.
    func route(_ request: HTTPRequest,
               lanEnabled: Bool,
               port: Int) async -> HTTPResponse {

        let target = MCPRequestTarget(request.path)
        let method = request.method.uppercased()
        let route = target.route

        guard route != .notFound else {
            return makeErrorResponse(status: 404, message: "Not Found: use /mcp (Streamable HTTP) or /sse (legacy SSE)")
        }

        // DNS-rebinding / browser protection for every endpoint (the SDK transports repeat
        // this check for /mcp; doing it here also covers /sse, /messages and /health).
        if let rejected = originValidator(lanEnabled: lanEnabled, port: port)
            .validate(request, context: HTTPValidationContext(httpMethod: method)) {
            return rejected
        }

        let (expectedToken, requireToken) = await MainActor.run {
            (AppState.shared.mcpBearerToken, AppState.shared.mcpRequireToken)
        }
        // LAN access always requires the token, whatever the toggle says.
        let tokenRequired = requireToken || lanEnabled

        if route == .health {
            guard method == "GET" else {
                return .error(statusCode: 405, .invalidRequest("Method Not Allowed"),
                              extraHeaders: [HTTPHeaderName.allow: "GET"])
            }
            return healthResponse(tokenRequired: tokenRequired)
        }

        guard MCPAuthPolicy.isAuthorized(headers: request.headers,
                                         path: request.path,
                                         expectedToken: expectedToken,
                                         required: tokenRequired) else {
            return HTTPResponse.textBody(
                status: 401,
                headers: ["WWW-Authenticate": "Bearer realm=\"Whisperer MCP\""],
                body: "Unauthorized: Invalid or missing bearer token"
            )
        }

        switch route {
        case .legacySSE:
            guard method == "GET" else {
                return .error(statusCode: 405, .invalidRequest("Method Not Allowed: open the SSE stream with GET /sse"),
                              extraHeaders: [HTTPHeaderName.allow: "GET"])
            }
            return await openLegacySession(target: target)
        case .legacyMessages:
            return await routeLegacyMessage(request, target: target)
        default:
            return await routeStreamable(request, lanEnabled: lanEnabled, port: port)
        }
    }

    // MARK: - Streamable HTTP

    private func routeStreamable(_ request: HTTPRequest,
                                 lanEnabled: Bool,
                                 port: Int) async -> HTTPResponse {
        let method = request.method.uppercased()
        let wantsSSE = MCPAcceptHeader(request.header(HTTPHeaderName.accept)).explicitlyWantsSSE

        if let sid = request.header(HTTPHeaderName.sessionID) {
            // Route to existing session.
            guard let session = sessions[sid] else {
                // Unknown or expired session id — match SDK wording exactly.
                return makeErrorResponse(status: 404,
                    message: "Not Found: Invalid or expired session ID")
            }
            session.lastActivity = Date()
            let response = await session.transport.handleRequest(request)
            // Evict on DELETE after the transport has replied.
            if method == "DELETE" {
                await evict(id: sid)
            }
            return method == "POST" ? await collapseIfNeeded(response, wantsSSE: wantsSSE) : response
        }

        guard method == "POST", let body = request.body, !body.isEmpty else {
            return makeErrorResponse(status: 400,
                message: "Bad Request: Session not initialized")
        }

        if isInitializeBody(body) {
            let response = await makeSession(request: request, lanEnabled: lanEnabled, port: port)
            return await collapseIfNeeded(response, wantsSSE: wantsSSE)
        }

        // Sessionless call (tools/list, tools/call… straight from curl or a plain HTTP client).
        return await handleStateless(request, lanEnabled: lanEnabled, port: port)
    }

    /// Turns a POST's SSE response into a single JSON body for clients that did not ask
    /// for text/event-stream.
    private func collapseIfNeeded(_ response: HTTPResponse, wantsSSE: Bool) async -> HTTPResponse {
        guard !wantsSSE, case .stream(let stream, let streamHeaders) = response else { return response }
        guard let json = await MCPSSECollapser.firstResponse(in: stream) else {
            return .error(statusCode: 500, .internalError("No response from MCP server"),
                          sessionID: streamHeaders[HTTPHeaderName.sessionID])
        }
        var headers = streamHeaders
        headers[HTTPHeaderName.contentType] = "application/json"
        headers[HTTPHeaderName.cacheControl] = nil
        headers[HTTPHeaderName.connection] = nil
        return .data(json, headers: headers)
    }

    private func handleStateless(_ request: HTTPRequest,
                                 lanEnabled: Bool,
                                 port: Int) async -> HTTPResponse {
        guard let transport = await sharedStatelessTransport(lanEnabled: lanEnabled, port: port) else {
            return makeErrorResponse(status: 500, message: "Internal error: could not start stateless server")
        }
        guard let body = request.body,
              let remapped = MCPJSONRPCIDRemapper.replaceID(in: body, with: "whisperer-\(UUID().uuidString)")
        else {
            // Notifications (no id) and malformed bodies go straight through.
            return await transport.handleRequest(request)
        }
        let rewritten = HTTPRequest(method: request.method, headers: request.headers,
                                    body: remapped.body, path: request.path)
        let response = await transport.handleRequest(rewritten)
        if case .data(let data, let headers) = response {
            return .data(MCPJSONRPCIDRemapper.restoreID(in: data, originalID: remapped.originalID),
                         headers: headers)
        }
        return response
    }

    private func sharedStatelessTransport(lanEnabled: Bool, port: Int) async -> StatelessHTTPServerTransport? {
        if let statelessTransport { return statelessTransport }
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                originValidator(lanEnabled: lanEnabled, port: port),
                LenientAcceptValidator(),
                ContentTypeValidator(),
                ProtocolVersionValidator(),
            ])
        )
        let server = await makeMCPServer()
        do {
            try await server.start(transport: transport)
        } catch {
            Logger.error("MCP: failed to start stateless server: \(error)", subsystem: .app)
            return nil
        }
        // Another request may have raced us across the awaits above.
        if let existing = statelessTransport {
            await server.stop()
            return existing
        }
        statelessTransport = transport
        statelessServer = server
        return transport
    }

    // MARK: - Legacy HTTP+SSE

    private func openLegacySession(target: MCPRequestTarget) async -> HTTPResponse {
        if legacySessions.count >= maxSessions,
           let oldest = legacySessions.min(by: { $0.value.created < $1.value.created }) {
            Logger.info("MCP: legacy SSE cap reached (\(maxSessions)), evicting \(oldest.key)", subsystem: .app)
            await evictLegacy(id: oldest.key)
        }

        let id = UUID().uuidString
        var endpoint = "/messages?sessionId=\(id)"
        // A client that authenticated with ?token= cannot add a header to its POSTs either.
        if let token = target.queryItems[MCPAuthPolicy.tokenQueryParameter],
           let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            endpoint += "&\(MCPAuthPolicy.tokenQueryParameter)=\(encoded)"
        }

        let (transport, eventStream) = LegacySSEServerTransport.make(sessionID: id, endpoint: endpoint)
        let server = await makeMCPServer()
        do {
            try await server.start(transport: transport)
        } catch {
            Logger.error("MCP: failed to start legacy SSE session \(id): \(error)", subsystem: .app)
            return makeErrorResponse(status: 500, message: "Internal error: could not start session")
        }

        let session = LegacySSESession(transport: transport, server: server)
        session.supervisor = Task { [weak self] in
            await server.waitUntilCompleted()
            await self?.removeLegacy(id: id)
        }
        legacySessions[id] = session
        Logger.info("MCP legacy SSE session created: \(id) total=\(legacySessions.count)", subsystem: .app)

        return .stream(eventStream, headers: LegacySSEServerTransport.responseHeaders)
    }

    private func routeLegacyMessage(_ request: HTTPRequest, target: MCPRequestTarget) async -> HTTPResponse {
        guard request.method.uppercased() == "POST" else {
            return .error(statusCode: 405, .invalidRequest("Method Not Allowed"),
                          extraHeaders: [HTTPHeaderName.allow: "POST"])
        }
        guard let id = target.queryItems["sessionId"] ?? target.queryItems["session_id"] else {
            return makeErrorResponse(status: 400, message: "Bad Request: missing sessionId")
        }
        guard let session = legacySessions[id] else {
            return makeErrorResponse(status: 404, message: "Not Found: Invalid or expired session ID")
        }
        return await session.transport.handlePost(request)
    }

    private func evictLegacy(id: String) async {
        guard let session = legacySessions.removeValue(forKey: id) else { return }
        session.supervisor?.cancel()
        await session.server.stop()
    }

    /// Called by the supervisor when the SSE stream closed and the server finished.
    private func removeLegacy(id: String) async {
        guard let session = legacySessions.removeValue(forKey: id) else { return }
        await session.server.stop()
        Logger.info("MCP legacy SSE session closed: \(id) remaining=\(legacySessions.count)", subsystem: .app)
    }

    // MARK: - Health

    private func healthResponse(tokenRequired: Bool) -> HTTPResponse {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let body: [String: Any] = [
            "ok": true,
            "name": "Whisperer",
            "version": version,
            "transports": ["streamable-http", "sse"],
            "endpoints": ["streamableHTTP": "/mcp", "sse": "/sse"],
            "tokenRequired": tokenRequired,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .data(data, headers: [HTTPHeaderName.contentType: "application/json"])
    }

    private func originValidator(lanEnabled: Bool, port: Int) -> OriginValidator {
        lanEnabled ? .disabled : .localhost(port: port)
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
        // Reuse: a client that reconnects replaces its own stale session instead of
        // growing the pool.
        let name = clientName(in: request)
        if let name {
            let mine = sessions.filter { $0.value.clientName == name }
                               .sorted { $0.value.lastActivity < $1.value.lastActivity }
            if mine.count >= maxSessionsPerClient, let stale = mine.first {
                Logger.info("MCP: client \(name) at per-client cap (\(maxSessionsPerClient)), replacing \(stale.key)", subsystem: .app)
                await evict(id: stale.key)
            }
        }

        // Enforce cap: evict the least-recently-active session, preferring ones with no
        // open streams.  Streams on dead client connections can stay "open" indefinitely
        // (the socket never errors), so refusing when every slot has a stream locks real
        // clients out.  An evicted live client just gets 404 and re-initializes.
        if sessions.count >= maxSessions {
            let byAge = sessions.sorted { $0.value.lastActivity < $1.value.lastActivity }
            if let victim = byAge.first(where: { $0.value.openStreams == 0 }) ?? byAge.first {
                Logger.info("MCP: session cap reached (\(maxSessions)), evicting LRU \(victim.key) streams=\(victim.value.openStreams)", subsystem: .app)
                await evict(id: victim.key)
            }
        }

        let id = UUID().uuidString

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedSessionIDGenerator(id: id),
            validationPipeline: StandardValidationPipeline(validators: [
                originValidator(lanEnabled: lanEnabled, port: port),
                LenientAcceptValidator(),
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
        session.clientName = name

        sessions[id] = session
        Logger.info("MCP session created: \(id) client=\(session.clientName ?? "unknown") total=\(sessions.count)", subsystem: .app)

        return await transport.handleRequest(request)
    }

    private func clientName(in request: HTTPRequest) -> String? {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let params = json["params"] as? [String: Any],
              let info = params["clientInfo"] as? [String: Any] else { return nil }
        return info["name"] as? String
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
        // Reads say so, which lets clients that gate tool calls on annotations (Codex, Claude)
        // run them without a prompt. The note tools are writes; delete is destructive.
        ListTools.Result(tools: (MCPMeetingTools.toolDefinitions + MCPTranscriptionTools.toolDefinitions).map { tool in
            var annotated = tool
            let writes = MCPMeetingTools.writeToolNames.contains(tool.name)
            annotated.annotations = .init(readOnlyHint: !writes,
                                          destructiveHint: MCPMeetingTools.destructiveToolNames.contains(tool.name),
                                          idempotentHint: !writes, openWorldHint: false)
            return annotated
        })
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
    nonisolated static func textBody(status: Int, headers: [String: String] = [:], body: String) -> HTTPResponse {
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
