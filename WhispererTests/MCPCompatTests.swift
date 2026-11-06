//
//  MCPCompatTests.swift
//  WhispererTests
//
//  Transport compatibility of the MCP server, exercised through MCPSessionRegistry.route
//  directly (no sockets): JSON response mode, sessionless plain-HTTP calls, optional /
//  query-string tokens, /health, 404s, and the legacy HTTP+SSE transport.
//

import XCTest
import MCP
@testable import whisperer

final class MCPCompatTests: XCTestCase {

    private static let port = 51998
    private var savedRequireToken = false

    override func setUp() {
        super.setUp()
        savedRequireToken = AppState.shared.mcpRequireToken
        AppState.shared.mcpRequireToken = false
    }

    override func tearDown() {
        AppState.shared.mcpRequireToken = savedRequireToken
        super.tearDown()
    }

    // MARK: - Helpers

    private let initBody = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"compat","version":"1"}}}"#
    private let listBody = #"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#

    private func post(_ registry: MCPSessionRegistry, body: String, path: String = "/mcp",
                      accept: String? = "application/json", headers extra: [String: String] = [:]) async -> HTTPResponse {
        var headers = ["Content-Type": "application/json"]
        if let accept { headers["Accept"] = accept }
        headers.merge(extra) { _, new in new }
        let req = HTTPRequest(method: "POST", headers: headers, body: Data(body.utf8), path: path)
        return await registry.route(req, lanEnabled: false, port: Self.port)
    }

    private func get(_ registry: MCPSessionRegistry, path: String,
                     headers: [String: String] = ["Accept": "text/event-stream"]) async -> HTTPResponse {
        await registry.route(HTTPRequest(method: "GET", headers: headers, body: nil, path: path),
                             lanEnabled: false, port: Self.port)
    }

    private func bodyJSON(_ r: HTTPResponse) -> [String: Any]? {
        guard let d = r.bodyData else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private func token() -> String { AppState.shared.mcpBearerToken }

    // MARK: - JSON response mode

    func testJSONOnlyAcceptInitializeReturnsPlainJSON() async throws {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: initBody, accept: "application/json")
        XCTAssertEqual(r.statusCode, 200)
        guard case .data = r else { return XCTFail("expected a JSON body, got \(r)") }
        XCTAssertEqual(r.headers[HTTPHeaderName.contentType], "application/json")
        let result = try XCTUnwrap(bodyJSON(r)?["result"] as? [String: Any])
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["name"] as? String, "Whisperer")
        let sid = try XCTUnwrap(r.headers[HTTPHeaderName.sessionID], "session id must survive the collapse")

        // Follow-up in the same session, still JSON.
        let list = await post(registry, body: listBody, headers: [HTTPHeaderName.sessionID: sid])
        XCTAssertEqual(list.statusCode, 200)
        let tools = (bodyJSON(list)?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertTrue(tools?.contains { $0["name"] as? String == "list_meetings" } == true)
        XCTAssertEqual(bodyJSON(list)?["id"] as? Int, 7)
        await registry.shutdown()
    }

    func testMissingOrWildcardAcceptGetsJSON() async {
        let registry = MCPSessionRegistry()
        for accept in [nil, "*/*"] as [String?] {
            let r = await post(registry, body: initBody, accept: accept)
            XCTAssertEqual(r.statusCode, 200, "Accept: \(accept ?? "none")")
            if case .data = r {} else { XCTFail("Accept \(accept ?? "none") should get JSON") }
        }
        await registry.shutdown()
    }

    func testExplicitSSEAcceptStillStreams() async {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: initBody, accept: "application/json, text/event-stream")
        guard case .stream = r else { return XCTFail("expected SSE stream") }
        await registry.shutdown()
    }

    func testUnacceptableAcceptIs406() async {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: initBody, accept: "text/html")
        XCTAssertEqual(r.statusCode, 406)
        await registry.shutdown()
    }

    // MARK: - Sessionless plain HTTP

    func testSessionlessToolsListReturnsTools() async throws {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: listBody, accept: nil)
        XCTAssertEqual(r.statusCode, 200)
        let json = try XCTUnwrap(bodyJSON(r))
        XCTAssertEqual(json["id"] as? Int, 7, "the client's own id must come back")
        let names = ((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names ?? []).isSuperset(of: ["list_meetings", "get_meeting",
                                                        "search_transcriptions", "get_transcription"]), true)
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)
        await registry.shutdown()
    }

    func testConcurrentSessionlessCallsWithSameIDDoNotCollide() async {
        let registry = MCPSessionRegistry()
        let body = #"{"jsonrpc":"2.0","id":"same","method":"tools/list"}"#
        async let a = post(registry, body: body)
        async let b = post(registry, body: body)
        async let c = post(registry, body: body)
        let all = await [a, b, c]
        for r in all {
            XCTAssertEqual(r.statusCode, 200)
            XCTAssertEqual(bodyJSON(r)?["id"] as? String, "same")
            XCTAssertNotNil(bodyJSON(r)?["result"])
        }
        await registry.shutdown()
    }

    func testSessionlessNotificationIsAccepted() async {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(r.statusCode, 202)
        await registry.shutdown()
    }

    // MARK: - Auth

    func testNoTokenNeededByDefault() async {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: initBody)
        XCTAssertEqual(r.statusCode, 200)
        await registry.shutdown()
    }

    func testTokenRequiredRejectsAndAcceptsHeaderOrQuery() async {
        AppState.shared.mcpRequireToken = true
        let registry = MCPSessionRegistry()

        let none = await post(registry, body: initBody)
        XCTAssertEqual(none.statusCode, 401)
        XCTAssertNotNil(none.headers["WWW-Authenticate"])
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)

        let header = await post(registry, body: initBody, headers: ["authorization": "bearer \(token())"])
        XCTAssertEqual(header.statusCode, 200)

        let query = await post(registry, body: listBody, path: "/mcp?token=\(token())")
        XCTAssertEqual(query.statusCode, 200)

        let wrongQuery = await post(registry, body: listBody, path: "/mcp?token=nope")
        XCTAssertEqual(wrongQuery.statusCode, 401)

        let sse = await get(registry, path: "/sse")
        XCTAssertEqual(sse.statusCode, 401, "legacy SSE is protected too")
        await registry.shutdown()
    }

    func testLANAlwaysRequiresToken() async {
        AppState.shared.mcpRequireToken = false
        let registry = MCPSessionRegistry()
        let req = HTTPRequest(method: "POST",
                              headers: ["Content-Type": "application/json", "Accept": "application/json"],
                              body: Data(initBody.utf8), path: "/mcp")
        let r = await registry.route(req, lanEnabled: true, port: Self.port)
        XCTAssertEqual(r.statusCode, 401)
        await registry.shutdown()
    }

    func testForeignOriginIsRejectedWithoutToken() async {
        let registry = MCPSessionRegistry()
        let r = await post(registry, body: listBody, headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(r.statusCode, 403, "browser pages must not reach the loopback server")
        let h = await post(registry, body: listBody, headers: ["Host": "evil.example:\(Self.port)"])
        XCTAssertEqual(h.statusCode, 421, "DNS rebinding (foreign Host) must be refused")
        let health = await get(registry, path: "/health", headers: ["Origin": "https://evil.example"])
        XCTAssertEqual(health.statusCode, 403)
        await registry.shutdown()
    }

    // MARK: - Health / 404

    func testHealthNeedsNoTokenAndReportsTransports() async throws {
        AppState.shared.mcpRequireToken = true
        let registry = MCPSessionRegistry()
        let r = await get(registry, path: "/health", headers: [:])
        XCTAssertEqual(r.statusCode, 200)
        let json = try XCTUnwrap(bodyJSON(r))
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["name"] as? String, "Whisperer")
        XCTAssertEqual(json["transports"] as? [String], ["streamable-http", "sse"])
        XCTAssertEqual(json["tokenRequired"] as? Bool, true)
        XCTAssertFalse(String(decoding: r.bodyData ?? Data(), as: UTF8.self).contains(token()))
    }

    func testUnknownPathIs404() async {
        let registry = MCPSessionRegistry()
        for path in ["/", "/api", "/mcpx", "/.well-known/oauth-protected-resource"] {
            let r = await post(registry, body: initBody, path: path)
            XCTAssertEqual(r.statusCode, 404, path)
        }
        let n = await registry.sessionCount
        XCTAssertEqual(n, 0)
    }

    func testTrailingSlashAndQueryStillRouteToMCP() async {
        let registry = MCPSessionRegistry()
        let a = await post(registry, body: listBody, path: "/mcp/")
        let b = await post(registry, body: listBody, path: "/mcp?client=x")
        XCTAssertEqual(a.statusCode, 200)
        XCTAssertEqual(b.statusCode, 200)
        await registry.shutdown()
    }

    // MARK: - Legacy SSE

    /// Collects SSE events from a stream in the background so the test can wait with a deadline.
    private actor EventSink {
        var events: [MCPSSECollapser.Event] = []
        var buffer = ""
        func append(_ chunk: Data) {
            buffer += String(decoding: chunk, as: UTF8.self)
            let (parsed, rest) = MCPSSECollapser.parseEvents(buffer)
            buffer = rest
            events += parsed
        }
        func snapshot() -> [MCPSSECollapser.Event] { events }
    }

    private func waitForEvent(_ sink: EventSink, timeout: TimeInterval = 5,
                              where match: @escaping (MCPSSECollapser.Event) -> Bool) async -> MCPSSECollapser.Event? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let e = await sink.snapshot().first(where: match) { return e }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testLegacySSEEndpointThenMessages() async throws {
        let registry = MCPSessionRegistry()
        let r = await get(registry, path: "/sse")
        guard case .stream(let stream, let headers) = r else { return XCTFail("GET /sse must stream, got \(r)") }
        XCTAssertEqual(headers[HTTPHeaderName.contentType], "text/event-stream")

        let sink = EventSink()
        let reader = Task {
            do { for try await chunk in stream { await sink.append(chunk) } } catch {}
        }
        defer { reader.cancel() }

        let endpointEvent = await waitForEvent(sink) { $0.event == "endpoint" }
        let endpoint = try XCTUnwrap(endpointEvent?.data)
        XCTAssertTrue(endpoint.hasPrefix("/messages?sessionId="), endpoint)
        let legacyCount = await registry.legacySessionCount
        XCTAssertEqual(legacyCount, 1)

        let accepted = await post(registry, body: initBody, path: endpoint, accept: nil)
        XCTAssertEqual(accepted.statusCode, 202)

        let initEvent = await waitForEvent(sink) { $0.event == "message" && $0.data.contains("serverInfo") }
        let initJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(initEvent).data.utf8)) as? [String: Any])
        XCTAssertEqual(initJSON["id"] as? Int, 1)

        _ = await post(registry, body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, path: endpoint)
        let listAccepted = await post(registry, body: listBody, path: endpoint)
        XCTAssertEqual(listAccepted.statusCode, 202)
        let listEvent = await waitForEvent(sink) { $0.event == "message" && $0.data.contains("list_meetings") }
        XCTAssertNotNil(listEvent, "tools/list result must arrive on the SSE stream")

        // Unknown session → 404, missing session → 400.
        let unknown = await post(registry, body: listBody, path: "/messages?sessionId=nope")
        XCTAssertEqual(unknown.statusCode, 404)
        let missing = await post(registry, body: listBody, path: "/messages")
        XCTAssertEqual(missing.statusCode, 400)

        await registry.shutdown()
    }

    func testLegacySSESessionEvictedWhenStreamCloses() async throws {
        let registry = MCPSessionRegistry()
        // Read the endpoint event, then drop every reference to the stream, like the HTTP
        // writer does when the client disconnects.
        try await readFirstLegacyEventAndDrop(registry)
        let open = await registry.legacySessionCount
        let deadline = Date().addingTimeInterval(5)
        var count = open
        while count > 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            count = await registry.legacySessionCount
        }
        XCTAssertEqual(count, 0, "a closed SSE stream must free its session")
        await registry.shutdown()
    }

    private func readFirstLegacyEventAndDrop(_ registry: MCPSessionRegistry) async throws {
        let r = await get(registry, path: "/sse")
        guard case .stream(let stream, _) = r else { return XCTFail("expected stream") }
        var it = stream.makeAsyncIterator()
        let first = try await it.next()
        XCTAssertNotNil(first)
        let n = await registry.legacySessionCount
        XCTAssertEqual(n, 1)
    }

    func testLegacyEndpointCarriesQueryToken() async throws {
        AppState.shared.mcpRequireToken = true
        let registry = MCPSessionRegistry()
        let r = await get(registry, path: "/sse?token=\(token())")
        guard case .stream(let stream, _) = r else { return XCTFail("expected stream, got \(r.statusCode)") }
        var it = stream.makeAsyncIterator()
        let first = try await it.next()
        let (events, _) = MCPSSECollapser.parseEvents(String(decoding: first ?? Data(), as: UTF8.self))
        let endpoint = try XCTUnwrap(events.first?.data)
        XCTAssertTrue(endpoint.contains("&token=\(token())"), endpoint)
        let accepted = await post(registry, body: initBody, path: endpoint)
        XCTAssertEqual(accepted.statusCode, 202, "the advertised endpoint must authenticate by itself")
        await registry.shutdown()
    }

    // MARK: - MCPSSECollapser

    func testParseEventsHandlesPrimingMultilineCRLFAndRemainder() {
        let text = "id: 1\ndata: \n\n: comment\r\nevent: message\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\ndata: partial"
        let (events, rest) = MCPSSECollapser.parseEvents(text)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "")
        XCTAssertEqual(events[1].event, "message")
        XCTAssertEqual(events[1].data, "{\"a\":\n1}")
        XCTAssertEqual(rest, "data: partial")
    }

    func testIsJSONRPCResponse() {
        XCTAssertTrue(MCPSSECollapser.isJSONRPCResponse(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)))
        XCTAssertTrue(MCPSSECollapser.isJSONRPCResponse(Data(#"{"jsonrpc":"2.0","id":"x","error":{"code":1}}"#.utf8)))
        XCTAssertFalse(MCPSSECollapser.isJSONRPCResponse(Data(#"{"jsonrpc":"2.0","method":"notifications/progress"}"#.utf8)))
        XCTAssertFalse(MCPSSECollapser.isJSONRPCResponse(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)))
        XCTAssertFalse(MCPSSECollapser.isJSONRPCResponse(Data("not json".utf8)))
    }

    func testFirstResponseSkipsNotificationsAndSplitChunks() async {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        cont.yield(Data("id: 0\ndata: \n\n".utf8))
        cont.yield(Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\n".utf8))
        cont.yield(Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,".utf8))
        cont.yield(Data("\"result\":{\"ok\":true}}\n\n".utf8))
        let data = await MCPSSECollapser.firstResponse(in: stream, timeout: .seconds(2))
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(json?["id"] as? Int, 3)
        cont.finish()
    }

    func testFirstResponseHandlesFinalEventWithoutBlankLine() async {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        cont.yield(Data("data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}".utf8))
        cont.finish()
        let data = await MCPSSECollapser.firstResponse(in: stream, timeout: .seconds(2))
        XCTAssertNotNil(data)
    }

    func testFirstResponseTimesOut() async {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        cont.yield(Data("data: \n\n".utf8))
        let start = Date()
        let data = await MCPSSECollapser.firstResponse(in: stream, timeout: .milliseconds(200))
        XCTAssertNil(data)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        cont.finish()
    }

    func testAcceptHeaderParsing() {
        XCTAssertTrue(MCPAcceptHeader(nil).allowsJSONResponse)
        XCTAssertTrue(MCPAcceptHeader("").allowsSSE)
        XCTAssertFalse(MCPAcceptHeader("*/*").explicitlyWantsSSE)
        XCTAssertTrue(MCPAcceptHeader("application/json;q=0.9, text/event-stream").explicitlyWantsSSE)
        XCTAssertFalse(MCPAcceptHeader("text/html").allowsJSONResponse)
        XCTAssertFalse(MCPAcceptHeader("text/html").allowsSSE)
    }
}
