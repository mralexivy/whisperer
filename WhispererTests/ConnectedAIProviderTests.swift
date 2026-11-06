//
//  ConnectedAIProviderTests.swift
//  WhispererTests
//
//  Providers end to end against fakes: the CLI runner against small shell scripts, and the
//  HTTP providers against a URLProtocol stub that replays SSE streams.
//

import CryptoKit
import XCTest
@testable import whisperer

#if !APP_STORE
final class CLIProcessRunnerTests: XCTestCase {

    private var scripts: [URL] = []

    override func tearDown() {
        scripts.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func script(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-cli-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        scripts.append(url)
        return url
    }

    func testStdinRoundTripAndStreaming() async throws {
        let cat = try script("cat")
        let chunks = Chunks()
        let (result, _) = try await CLIProcessRunner.run(
            executable: cat, arguments: { _ in [] }, stdin: "שלום transcript", timeout: 10,
            onStdout: { chunks.append($0) })
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "שלום transcript")
        XCTAssertEqual(chunks.joined, "שלום transcript")
    }

    func testLargeStdinDoesNotDeadlock() async throws {
        let wc = try script("wc -c | tr -d ' '")
        let big = String(repeating: "a", count: 2_000_000)
        let (result, _) = try await CLIProcessRunner.run(executable: wc, arguments: { _ in [] }, stdin: big, timeout: 20)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "2000000")
    }

    func testRunsInEmptyTempDirThatIsDeletedAfterwards() async throws {
        let probe = try script("pwd; ls -A | wc -l | tr -d ' '; cat schema.json")
        var dir: URL?
        let (result, _) = try await CLIProcessRunner.run(
            executable: probe, arguments: { d in dir = d; return [] }, stdin: "",
            files: ["schema.json": "{}"], timeout: 10)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let workDir = try XCTUnwrap(dir)
        XCTAssertTrue(lines.first?.hasSuffix(workDir.lastPathComponent) == true, "cwd is the per-call temp dir")
        XCTAssertEqual(lines.dropFirst().first, "1", "only the files we wrote are there")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.path), "temp dir is removed afterwards")
    }

    func testEnvironmentIsScrubbed() {
        let env = CLIProcessRunner.environment(from: [
            "HOME": "/Users/x", "PATH": "/custom/bin",
            "WHISPERER_SECRET": "nope", "AWS_SECRET_ACCESS_KEY": "nope", "ANTHROPIC_API_KEY": "user-own",
        ])
        XCTAssertNil(env["WHISPERER_SECRET"])
        XCTAssertNil(env["AWS_SECRET_ACCESS_KEY"])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "user-own", "the CLI's own auth variables travel with it")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertTrue(env["PATH"]?.hasPrefix("/") == true)
        XCTAssertTrue(env["PATH"]?.hasSuffix(":/custom/bin") == true, "user PATH kept after ours")
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    func testCollectReadsFilesBeforeCleanup() async throws {
        let writer = try script("echo '{\"overview\":\"o\"}' > out.txt")
        let (_, collected) = try await CLIProcessRunner.run(
            executable: writer, arguments: { _ in [] }, stdin: "", timeout: 10,
            collect: { try? String(contentsOf: $0.appendingPathComponent("out.txt"), encoding: .utf8) })
        XCTAssertEqual(collected?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"overview":"o"}"#)
    }

    func testTimeoutKillsTheProcess() async throws {
        let sleeper = try script("sleep 30")
        let started = Date()
        do {
            _ = try await CLIProcessRunner.run(executable: sleeper, arguments: { _ in [] }, stdin: "", timeout: 1)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? MeetingAIProviderError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testCancellationKillsTheProcess() async throws {
        let sleeper = try script("sleep 30")
        let task = Task {
            try await CLIProcessRunner.run(executable: sleeper, arguments: { _ in [] }, stdin: "", timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(400))
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? MeetingAIProviderError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "cancel must stop the child within 2 s + slack")
    }

    func testOutputCap() async throws {
        let yes = try script("head -c 100000 /dev/zero | tr '\\0' 'x'")
        let (result, _) = try await CLIProcessRunner.run(
            executable: yes, arguments: { _ in [] }, stdin: "", timeout: 10, maxOutputBytes: 1_000)
        XCTAssertEqual(result.stdout.count, 1_000)
    }

    func testMissingExecutable() async {
        do {
            _ = try await CLIProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/claude"),
                                               arguments: { _ in [] }, stdin: "", timeout: 5)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MeetingAIProviderError, .notInstalled)
        }
    }

    func testDiscoveryHonoursOverride() throws {
        let fake = try script("echo hi")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "CLIDiscoveryTests-\(UUID().uuidString)"))
        defaults.set(fake.path, forKey: CLIDiscovery.overrideKey(for: .claudeCode))
        XCTAssertEqual(CLIDiscovery.locate(.claudeCode, defaults: defaults)?.path, fake.path)
        defaults.set("relative/path", forKey: CLIDiscovery.overrideKey(for: .claudeCode))
        XCTAssertNotEqual(CLIDiscovery.locate(.claudeCode, defaults: defaults)?.path, "relative/path",
                          "a relative override is never trusted")
    }

    private final class Chunks: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [String] = []
        func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
        var joined: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
    }
}
#endif

// MARK: - HTTP providers

/// Replays canned responses keyed by host. Each test installs its own table.
final class StubURLProtocol: URLProtocol {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() { lock.lock(); replies = [:]; requests = []; lock.unlock() }
    static func enqueue(host: String, _ reply: Reply) { lock.lock(); replies[host, default: []].append(reply); lock.unlock() }
    static var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        var req = request
        if req.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            req.httpBody = data
        }
        Self.requests.append(req)
        let host = request.url?.host ?? ""
        let reply = Self.replies[host]?.isEmpty == false ? Self.replies[host]!.removeFirst() : Reply(status: 500, body: "no stub")
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers.merging(["Content-Type": "text/event-stream"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver in small pieces so the SSE parser sees split frames.
        let bytes = Data(reply.body.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 23, bytes.count)
            client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPProviderTests: XCTestCase {

    private var savedSession: URLSession!

    override func setUp() {
        super.setUp()
        savedSession = ProviderHTTPClient.session
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        ProviderHTTPClient.session = URLSession(configuration: config)
        StubURLProtocol.reset()
    }

    override func tearDown() {
        ProviderHTTPClient.session = savedSession
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let input = MeetingNotesInput(transcript: "[0s] Alice: We picked Postgres.", languageName: "English",
                                          wordCount: 4, isShortNote: true)

    private func openAISSE(_ pieces: [String]) -> String {
        pieces.map { piece -> String in
            let escaped = String(data: try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": piece]), encoding: .utf8)!
            return "event: response.output_text.delta\ndata: \(escaped)\n\n"
        }.joined() + "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"
    }

    private func openAI(planRoute: Bool) -> OpenAIResponsesProvider {
        OpenAIResponsesProvider(id: planRoute ? .chatGPT : .openAIKey, model: "gpt-test",
                                token: { "tok-123" }, isPlanRoute: planRoute)
    }

    func testOpenAINotesStreamTitleFirst() async throws {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 200, body: openAISSE([
            #"{"title": "Postgres "#, #"decision", "overview": "#, #""Alice picked Postgres.", "topics": []}"#,
        ])))
        let titles = Box<[String]>([])
        let notes = try await openAI(planRoute: false).generateNotes(input) { title in
            titles.mutate { $0.append(title) }
        }
        XCTAssertEqual(notes.title, "Postgres decision")
        XCTAssertEqual(notes.summary.overview, "Alice picked Postgres.")
        XCTAssertEqual(titles.value, ["Postgres decision"], "title fires exactly once, before the stream ends")

        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["instructions"])
        XCTAssertEqual(((body["text"] as? [String: Any])?["format"] as? [String: Any])?["type"] as? String, "json_schema")
    }

    /// The ChatGPT plan route rejects these fields; none may ever be serialized.
    func testPlanRouteBodyHasNoUnsupportedFields() throws {
        let body = openAI(planRoute: true).body(instructions: "I", user: "U", schema: MeetingNotesSchema.full)
        let keys = Set(body.keys)
        XCTAssertTrue(keys.isDisjoint(with: OpenAIResponsesProvider.unsupportedPlanFields), "sent: \(keys)")
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertFalse(input.contains { $0["role"] as? String == "system" }, "system role items are rejected")
    }

    func testOpenAISchemaRejectionRetriesWithInlineSchema() async throws {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 400, body: #"{"error":{"message":"text.format not supported"}}"#))
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 200, body: openAISSE([#"{"title":"T","overview":"O"}"#])))
        let notes = try await openAI(planRoute: false).generateNotes(input) { _ in }
        XCTAssertEqual(notes.title, "T")
        let second = try XCTUnwrap(StubURLProtocol.recorded.last?.httpBody)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: second) as? [String: Any])
        XCTAssertNil(body["text"], "retry drops the structured-output field")
        XCTAssertTrue((body["instructions"] as? String)?.contains("JSON schema") == true)
    }

    /// The plan route rejects `text.format`; it gets the schema inline in a single request.
    func testPlanRouteSendsSchemaInlineInOneRequest() async throws {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 200, body: openAISSE([#"{"title":"T","overview":"O"}"#])))
        let notes = try await openAI(planRoute: true).generateNotes(input) { _ in }
        XCTAssertEqual(notes.title, "T")
        XCTAssertEqual(StubURLProtocol.recorded.count, 1, "no doomed structured-output attempt first")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: StubURLProtocol.recorded[0].httpBody ?? Data()) as? [String: Any])
        XCTAssertNil(body["text"])
        XCTAssertTrue((body["instructions"] as? String)?.contains("JSON schema") == true)
    }

    func testOpenAIErrorsMap() async {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 401, body: "{}"))
        do { _ = try await openAI(planRoute: false).ask(MeetingAskInput(question: "q", transcript: "t")) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? MeetingAIProviderError, .unauthorized) }

        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 429, body: #"{"error":{"type":"insufficient_quota"}}"#,
                                                              headers: ["Retry-After": "60"]))
        do { _ = try await openAI(planRoute: false).ask(MeetingAskInput(question: "q", transcript: "t")) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? MeetingAIProviderError, .quotaExhausted(retryAfter: 60)) }
    }

    func testOpenAIAskStreamsPartials() async throws {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 200, body: openAISSE(["They chose ", "Postgres [12s]."])))
        let partials = Box<[String]>([])
        let answer = try await openAI(planRoute: false).ask(MeetingAskInput(question: "q", transcript: "t")) { p in
            partials.mutate { $0.append(p) }
        }
        XCTAssertEqual(answer, "They chose Postgres [12s].")
        XCTAssertEqual(partials.value.last, "They chose Postgres [12s].")
        XCTAssertGreaterThanOrEqual(partials.value.count, 2)
    }

    func testAnthropicStreams() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start"}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"{\\"title\\": \\"קורס בינה\\", "}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\\"overview\\": \\"סיכום.\\"}"}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        StubURLProtocol.enqueue(host: "api.anthropic.com", .init(status: 200, body: sse))
        let provider = AnthropicAPIProvider(model: "claude-test", apiKey: { "sk-ant" })
        let notes = try await provider.generateNotes(input) { _ in }
        XCTAssertEqual(notes.title, "קורס בינה")
        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAnthropicOverloadedMapsToRateLimited() async {
        StubURLProtocol.enqueue(host: "api.anthropic.com", .init(status: 200, body:
            "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n"))
        let provider = AnthropicAPIProvider(model: "m", apiKey: { "k" })
        do { _ = try await provider.ask(MeetingAskInput(question: "q", transcript: "t")) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? MeetingAIProviderError, .rateLimited(retryAfter: nil)) }
    }

    func testGeminiStreamsAndSkipsThoughts() async throws {
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"text":"thinking…","thought":true}]}}]}

        data: {"candidates":[{"content":{"parts":[{"text":"{\\"title\\":\\"G\\",\\"overview\\":\\"Body\\"}"}]}}]}


        """
        StubURLProtocol.enqueue(host: "generativelanguage.googleapis.com", .init(status: 200, body: sse))
        let provider = GeminiAPIProvider(model: "gemini-test", apiKey: { "g-key" })
        let notes = try await provider.generateNotes(input) { _ in }
        XCTAssertEqual(notes.title, "G")
        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertTrue(request.url?.absoluteString.contains("models/gemini-test:streamGenerateContent?alt=sse") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "g-key")
        XCTAssertFalse(request.url?.absoluteString.contains("g-key") == true, "key never in the URL")
    }

    func testMissingKeyFailsWithoutNetwork() async {
        let provider = GeminiAPIProvider(model: "m", apiKey: { nil })
        let readiness = await provider.readiness()
        XCTAssertEqual(readiness, .needsKey)
        do { _ = try await provider.ask(MeetingAskInput(question: "q", transcript: "t")) { _ in }; XCTFail() }
        catch { XCTAssertEqual(error as? MeetingAIProviderError, .unauthorized) }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testListModelsPlanRouteFiltersByVisibility() async throws {
        StubURLProtocol.enqueue(host: "api.openai.com", .init(status: 200, body:
            #"{"models":[{"slug":"gpt-a","visibility":"list"},{"slug":"gpt-hidden","visibility":"hide"}]}"#))
        let models = try await OpenAIResponsesProvider.listModels(token: "t")
        XCTAssertEqual(models, ["gpt-a"])
    }
}

/// Lock-protected box for values mutated from @Sendable callbacks.
nonisolated final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&stored); lock.unlock() }
}

// MARK: - ChatGPT auth

final class ChatGPTAuthTests: XCTestCase {

    func testFirstSignInRegistersDynamically() throws {
        let url = ChatGPTAuth.authorizeURL(clientID: ChatGPTAuth.dynamicClientID, hostID: "urn:uuid:abc",
                                           redirectURI: "http://127.0.0.1:5555/auth/callback", state: "s",
                                           nonce: "n", codeChallenge: "c", idTokenHint: "ignored")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/api/accounts/authorize")
        XCTAssertEqual(items["client_id"], "dynamic_agent_client")
        XCTAssertEqual(items["agent_name_hint"], "Whisperer")
        XCTAssertNil(items["id_token_hint"], "no hint on first registration")
        XCTAssertEqual(items["ext_agent_host_id"], "urn:uuid:abc")
        XCTAssertEqual(items["redirect_uri"], "http://127.0.0.1:5555/auth/callback")
        XCTAssertTrue(items["scope"]?.contains("chatgpt.tokens.use.direct") == true)
        XCTAssertTrue(items["scope"]?.contains("offline_access") == true)
        XCTAssertEqual(items["resource"], "https://api.openai.com/v1")
        XCTAssertEqual(items["code_challenge_method"], "S256")
    }

    func testReauthorizationUsesIssuedClientAndHint() {
        let url = ChatGPTAuth.authorizeURL(clientID: "oaiapp_123", hostID: "h", redirectURI: "r", state: "s",
                                           nonce: "n", codeChallenge: "c", idTokenHint: "idtok")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "id_token_hint", value: "idtok")))
        XCTAssertFalse(query.contains { $0.name == "agent_name_hint" })
    }

    func testPKCEChallengeIsBase64URLSHA256WithoutPadding() {
        let pkce = ChatGPTAuth.makePKCE()
        let expected = ChatGPTAuth.base64URL(Data(SHA256.hash(data: Data(pkce.verifier.utf8))))
        XCTAssertEqual(pkce.challenge, expected)
        XCTAssertFalse(pkce.challenge.contains("="))
        XCTAssertFalse(pkce.challenge.contains("+"))
        XCTAssertFalse(pkce.challenge.contains("/"))
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43, "RFC 7636 minimum verifier length")
    }

    func testTokenResponseParsing() throws {
        let payload = ChatGPTAuth.base64URL(Data(#"{"email":"me@example.com"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        let creds = try XCTUnwrap(ChatGPTAuth.credentials(fromTokenResponse: [
            "access_token": "at", "refresh_token": "rt", "expires_in": 3600,
            "scope": "openid offline_access chatgpt.tokens.use.direct", "id_token": "h.\(payload).sig",
        ], clientID: "oaiapp_1", previous: nil, now: now))
        XCTAssertTrue(creds.hasPlanUsage)
        XCTAssertEqual(creds.email, "me@example.com")
        XCTAssertEqual(creds.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(creds.needsRefresh(now: now))
        XCTAssertTrue(creds.needsRefresh(now: now.addingTimeInterval(3_100)))
    }

    func testRefreshKeepsRotatedTokenAndPreviousFields() throws {
        let previous = ChatGPTAuth.Credentials(clientID: "c", accessToken: "old", refreshToken: "rt1", idToken: "id",
                                               expiresAt: .distantPast, scopes: ["chatgpt.tokens.use.direct"], email: "e")
        let updated = try XCTUnwrap(ChatGPTAuth.credentials(fromTokenResponse: ["access_token": "new", "refresh_token": "rt2"],
                                                            clientID: "c", previous: previous))
        XCTAssertEqual(updated.refreshToken, "rt2", "rotated refresh token replaces the old one")
        XCTAssertEqual(updated.scopes, previous.scopes)
        XCTAssertEqual(updated.email, "e")
        let noRotation = try XCTUnwrap(ChatGPTAuth.credentials(fromTokenResponse: ["access_token": "new"], clientID: "c", previous: previous))
        XCTAssertEqual(noRotation.refreshToken, "rt1")
    }

    func testDeclinedPlanUsageIsDetected() throws {
        let creds = try XCTUnwrap(ChatGPTAuth.credentials(fromTokenResponse: ["access_token": "a", "scope": "openid profile email"],
                                                          clientID: "c", previous: nil))
        XCTAssertFalse(creds.hasPlanUsage)
    }

    func testFormEncoding() throws {
        let request = ChatGPTAuth.formRequest(ChatGPTAuth.tokenEndpoint, ["redirect_uri": "http://127.0.0.1:1/auth/callback", "code": "a+b"])
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8)
        XCTAssertEqual(body, "code=a%2Bb&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fauth%2Fcallback")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
    }

    func testHostIDIsStable() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ChatGPTAuthTests-\(UUID().uuidString)"))
        let first = ChatGPTAuth.hostID(defaults: defaults)
        XCTAssertTrue(first.hasPrefix("urn:uuid:"))
        XCTAssertEqual(ChatGPTAuth.hostID(defaults: defaults), first)
    }

    func testLoopbackListenerDeliversCallback() async throws {
        let listener = LoopbackCallbackListener(path: "/auth/callback")
        let port = try await listener.start()
        let waiter = Task { try await listener.waitForCallback(timeout: 10) }
        let url = URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz&client_id=oaiapp_9")!
        let (data, _) = try await URLSession.shared.data(from: url)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("close this tab"))
        let query = try await waiter.value
        XCTAssertEqual(query["code"], "abc")
        XCTAssertEqual(query["state"], "xyz")
        XCTAssertEqual(query["client_id"], "oaiapp_9")
    }
}
