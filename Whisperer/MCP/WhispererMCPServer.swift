//
//  WhispererMCPServer.swift
//  Whisperer
//
//  Local MCP server exposing meeting notes and transcription search.
//  HTTP transport via NWListener; multiple concurrent clients are supported via
//  MCPSessionRegistry — each client gets its own MCP session identified by the
//  Mcp-Session-Id header.
//
//  Connection lifecycle notes:
//  - MCP clients (Claude Desktop, Claude Code, Cursor, ChatGPT Desktop…) open a
//    GET /mcp SSE stream, then POST JSON-RPC requests on the same or separate
//    connections. When done they often RST rather than FIN.
//  - Network.framework logs nw_socket_* / nw_protocol_socket_reset_linger messages
//    for RST internally via os_log — these cannot be suppressed at the application
//    level. They are expected and harmless; we classify ECONNRESET / EPIPE as silent
//    lifecycle events.
//  - TCP keepalive detects dead peers within ~20 s so idle SSE streams don't
//    accumulate.
//

import Foundation
import Network
import MCP

actor WhispererMCPServer {
    static let shared = WhispererMCPServer()

    private var listener: NWListener?
    private let registry = MCPSessionRegistry()
    private var listeningPort: Int = 0

    // MARK: - Lifecycle

    func start(port: Int) async {
        guard listener == nil else { return }

        listeningPort = port

        // TCP keepalive: detect dead peers without waiting for RST.
        // noDelay: send JSON-RPC responses immediately (no Nagle buffering).
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15       // seconds idle before first probe
        tcpOptions.keepaliveInterval = 5    // seconds between probes
        tcpOptions.keepaliveCount = 3       // probes before declaring dead
        tcpOptions.noDelay = true

        let params = NWParameters(tls: nil, tcp: tcpOptions)
        params.allowLocalEndpointReuse = true

        // Restrict to loopback unless the user has explicitly enabled LAN access.
        let lanEnabled = await MainActor.run { AppState.shared.mcpLANEnabled }
        if !lanEnabled {
            params.requiredInterfaceType = .loopback
        }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            Logger.error("MCP: invalid port \(port)", subsystem: .app)
            return
        }

        do {
            let l = try NWListener(using: params, on: nwPort)
            listener = l

            l.newConnectionHandler = { [weak self] conn in
                Task { [weak self] in await self?.handleConnection(conn) }
            }

            if await MainActor.run(body: { AppState.shared.mcpLANEnabled }) {
                l.service = NWListener.Service(
                    name: "Whisperer MCP",
                    type: "_whisperer-mcp._tcp",
                    domain: nil,
                    txtRecord: NWTXTRecord(["path": "/mcp"])
                )
            }

            l.stateUpdateHandler = { [weak self] state in
                Task { [weak self] in await self?.listenerStateChanged(state) }
            }

            l.start(queue: .global(qos: .utility))

            await registry.startReaper()
            await MainActor.run { AppState.shared.mcpServerRunning = true }
            Logger.info("MCP server started on port \(port)", subsystem: .app)
        } catch {
            Logger.error("MCP server failed to bind port \(port): \(error)", subsystem: .app)
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        await registry.shutdown()
        await MainActor.run { AppState.shared.mcpServerRunning = false }
        Logger.info("MCP server stopped", subsystem: .app)
    }

    func restart(port: Int) async {
        await stop()
        try? await Task.sleep(for: .milliseconds(200))
        await start(port: port)
    }

    // MARK: - Listener state

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .failed(let error):
            if !isCancelledError(error) {
                Logger.error("MCP listener failed: \(error.localizedDescription)", subsystem: .app)
            }
        case .cancelled:
            break  // Expected on stop() — no log needed.
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection) async {
        let connID = UUID().uuidString.prefix(8)

        conn.start(queue: .global(qos: .utility))

        let idleTimeout: TimeInterval = 120
        let port = listeningPort
        let lanEnabled = await MainActor.run { AppState.shared.mcpLANEnabled }

        var requestCount = 0
        loop: while !Task.isCancelled {
            guard let request = await readHTTPRequest(conn: conn, timeout: idleTimeout) else {
                break loop
            }
            requestCount += 1

            let response = await registry.route(request, lanEnabled: lanEnabled, port: port)

            // Extract session id from the response headers so we can bracket SSE streams.
            let sessionID = response.headers[HTTPHeaderName.sessionID]

            let isStream: Bool
            if case .stream = response { isStream = true } else { isStream = false }

            if isStream, let sid = sessionID {
                await registry.streamOpened(id: sid)
            }

            let keepAlive = await writeHTTPResponse(response, conn: conn, connID: String(connID))

            if isStream, let sid = sessionID {
                await registry.streamClosed(id: sid)
            }

            if !keepAlive { break loop }
        }

        conn.cancel()
    }

    // MARK: - HTTP Request Parsing

    private func readHTTPRequest(conn: NWConnection, timeout: TimeInterval) async -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        var accumulated = Data()

        let deadline = Date().addingTimeInterval(timeout)
        while accumulated.count < 1_048_576 {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            guard let chunk = await nwReceive(conn: conn) else { return nil }
            accumulated.append(chunk)
            if accumulated.range(of: separator) != nil { break }
        }

        guard let sepRange = accumulated.range(of: separator) else { return nil }
        let headerData = accumulated[..<sepRange.lowerBound]
        let bodyPreload = Data(accumulated[sepRange.upperBound...])

        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = headers.first(where: { $0.key.lowercased() == "content-length" })
            .flatMap { Int($0.value) } ?? 0

        var body: Data? = nil
        if contentLength > 0 {
            var bodyData = bodyPreload
            while bodyData.count < contentLength {
                guard let chunk = await nwReceive(conn: conn) else { return nil }
                bodyData.append(chunk)
            }
            body = Data(bodyData.prefix(contentLength))
        }

        return HTTPRequest(method: method, headers: headers, body: body, path: path)
    }

    // MARK: - HTTP Response Writing

    /// Returns true if the connection should be kept alive for a next request.
    private func writeHTTPResponse(_ response: HTTPResponse, conn: NWConnection, connID: String) async -> Bool {
        switch response {
        case .stream(let stream, let headers):
            var resp = "HTTP/1.1 200 OK\r\n"
            for (k, v) in headers { resp += "\(k): \(v)\r\n" }
            resp += "\r\n"
            guard await nwSend(conn: conn, data: Data(resp.utf8)) else { return false }
            do {
                for try await chunk in stream {
                    guard await nwSend(conn: conn, data: chunk) else { return false }
                }
            } catch {
                // Stream closed or errored — treat as normal SSE lifecycle.
            }
            return false

        default:
            let status = response.statusCode
            var hdrs = response.headers
            var body = Data()
            if let bd = response.bodyData {
                body = bd
                hdrs["Content-Length"] = "\(bd.count)"
            } else {
                hdrs["Content-Length"] = "0"
            }
            var resp = "HTTP/1.1 \(status) \(phrase(status))\r\n"
            for (k, v) in hdrs { resp += "\(k): \(v)\r\n" }
            resp += "\r\n"
            var data = Data(resp.utf8)
            data.append(body)
            guard await nwSend(conn: conn, data: data) else { return false }
            return true
        }
    }

    private func writePlain(conn: NWConnection, status: Int, extraHeaders: [String: String] = [:], body: String) async {
        let bodyBytes = Data(body.utf8)
        var resp = "HTTP/1.1 \(status) \(phrase(status))\r\nContent-Type: text/plain\r\nContent-Length: \(bodyBytes.count)\r\n"
        for (k, v) in extraHeaders { resp += "\(k): \(v)\r\n" }
        resp += "\r\n"
        var data = Data(resp.utf8)
        data.append(bodyBytes)
        _ = await nwSend(conn: conn, data: data)
    }

    private func phrase(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }

    // MARK: - NWConnection Helpers

    private func nwReceive(conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { content, _, isComplete, error in
                if let error {
                    cont.resume(returning: nil)
                    return
                }
                if isComplete && (content == nil || content!.isEmpty) {
                    cont.resume(returning: nil)  // Graceful EOF
                    return
                }
                cont.resume(returning: content ?? Data())
            }
        }
    }

    private func nwSend(conn: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            conn.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }

    // MARK: - Error Classification

    private func isCancelledError(_ error: any Error) -> Bool {
        guard let nwError = error as? NWError else { return false }
        if case .posix(let code) = nwError, code == .ECANCELED { return true }
        return false
    }
}
