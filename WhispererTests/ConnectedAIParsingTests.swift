//
//  ConnectedAIParsingTests.swift
//  WhispererTests
//
//  The output contract every connected provider answers in, and the stream parsers that
//  feed it: MeetingNotesSchema, SSEStreamParser, ClaudeStreamParser, error classification.
//

import XCTest
@testable import whisperer

final class MeetingNotesSchemaTests: XCTestCase {

    private let sample = """
    {"title":"Postgres for the events table","overview":"Postgres won over DynamoDB.\\n\\nSara writes the migration.",
     "topics":[{"text":"Database choice","seconds":12}],
     "decisions":[{"label":"Database","text":"Use Postgres","seconds":40}],
     "openQuestions":[{"text":"What about 500 GB?","seconds":null}],
     "nextMeeting":null,
     "actionItems":[{"task":"Write the migration","owner":"Sara","due":"Friday"},
                    {"task":"Check costs","owner":"Unknown","due":"n/a"}]}
    """

    func testDecodesFullObject() throws {
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(sample))
        XCTAssertEqual(notes.title, "Postgres for the events table")
        XCTAssertTrue(notes.summary.overview.contains("\n\nSara"))
        XCTAssertEqual(notes.summary.keyTopics.first?.timestampSeconds, 12)
        XCTAssertEqual(notes.summary.decisions.first?.label, "Database")
        XCTAssertEqual(notes.summary.openQuestions.first?.timestampSeconds, 0, "null seconds becomes 0")
        XCTAssertNil(notes.summary.nextMeeting)
        XCTAssertEqual(notes.summary.actionItems.count, 2)
        XCTAssertEqual(notes.summary.actionItems[0].ownerName, "Sara")
        XCTAssertEqual(notes.summary.actionItems[0].dueLabel, "Friday")
    }

    func testUnknownOwnerAndDueStayEmpty() throws {
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(sample))
        XCTAssertEqual(notes.summary.actionItems[1].ownerName, "", "a placeholder owner must not become a person")
        XCTAssertNil(notes.summary.actionItems[1].dueLabel)
    }

    func testDecodesFencedAndChattyReplies() throws {
        let fenced = "Here are the notes:\n```json\n\(sample)\n```\nLet me know!"
        XCTAssertNotNil(MeetingNotesSchema.decode(fenced))
        // A pty echo puts the prompt (with its own braces) before the answer: last object wins.
        let echoed = "prompt {not json} TRANSCRIPT\n\(sample)"
        XCTAssertEqual(MeetingNotesSchema.decode(echoed)?.title, "Postgres for the events table")
    }

    func testMissingOverviewIsRejected() {
        XCTAssertNil(MeetingNotesSchema.decode(#"{"title":"Only a title"}"#))
        XCTAssertNil(MeetingNotesSchema.decode("no json here"))
        XCTAssertNil(MeetingNotesSchema.decode(#"{"title":"x","overview":"   "}"#))
    }

    func testLenientOnWrongFieldTypes() throws {
        let odd = #"{"title":"T","overview":"O","topics":"not an array","actionItems":[{"task":"Do it","owner":5}]}"#
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(odd))
        XCTAssertTrue(notes.summary.keyTopics.isEmpty)
        XCTAssertTrue(notes.summary.actionItems.isEmpty, "an item that fails to decode is dropped, not fatal")
    }

    func testDecodeFromStructuredObject() throws {
        let object: [String: Any] = ["title": "From object", "overview": "Body", "topics": []]
        XCTAssertEqual(MeetingNotesSchema.decode(object: object)?.title, "From object")
    }

    func testCandidatesIgnoreBracesInsideStrings() {
        let text = #"{"overview":"a } b { c","title":"x"}"#
        XCTAssertEqual(MeetingNotesSchema.jsonObjectCandidates(in: text), [text])
    }

    func testStreamedTitleFiresOnlyWhenClosed() {
        XCTAssertNil(MeetingNotesSchema.streamedTitle(in: #"{"title": "Database"#))
        XCTAssertEqual(MeetingNotesSchema.streamedTitle(in: #"{"title": "Database Choice", "overv"#), "Database Choice")
        XCTAssertEqual(MeetingNotesSchema.streamedTitle(in: #"{"title":"Say \"hi\"","#), #"Say "hi""#)
        XCTAssertEqual(MeetingNotesSchema.streamedTitle(in: #"{"title": "שלום"}"#), "שלום")
        XCTAssertEqual(MeetingNotesSchema.streamedTitle(in: #"{"title": "פגישת צוות","#), "פגישת צוות")
        XCTAssertNil(MeetingNotesSchema.streamedTitle(in: #"{"title": "  "}"#))
    }

    /// OpenAI strict structured outputs (Codex --output-schema) rejects a schema unless every
    /// object lists all its properties as required and sets additionalProperties false.
    func testSchemaIsStrictModeCompatible() throws {
        let data = try XCTUnwrap(MeetingNotesSchema.full.data(using: .utf8))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        func check(_ node: [String: Any], path: String) {
            if node["type"] as? String == "object" {
                XCTAssertEqual(node["additionalProperties"] as? Bool, false, "\(path) additionalProperties")
                let props = (node["properties"] as? [String: Any]) ?? [:]
                let required = Set((node["required"] as? [String]) ?? [])
                XCTAssertEqual(required, Set(props.keys), "\(path) must require every property")
                for (key, value) in props {
                    if let child = value as? [String: Any] { check(child, path: "\(path).\(key)") }
                }
            }
            if let items = node["items"] as? [String: Any] { check(items, path: "\(path)[]") }
        }
        check(root, path: "$")
        let order = MeetingNotesSchema.fullCompact
        XCTAssertFalse(order.contains("\n"), "compact form is one line for argv")
    }
}

final class SSEStreamParserTests: XCTestCase {

    func testEventsAcrossSplitFrames() {
        var parser = SSEStreamParser()
        var events = parser.feed(Data("event: delta\ndata: {\"a\"".utf8))
        XCTAssertTrue(events.isEmpty)
        events = parser.feed(Data(":1}\n\ndata: second\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: "delta", data: #"{"a":1}"#)])
        events = parser.feed(Data("\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "second")])
    }

    func testMultibyteCharacterSplitAcrossChunks() {
        var parser = SSEStreamParser()
        let bytes = Array("data: שלום\n\n".utf8)
        // Split inside the two-byte ש.
        let first = parser.feed(Data(bytes[0..<7]))
        let second = parser.feed(Data(bytes[7...]))
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.first?.data, "שלום")
    }

    func testCommentsCRLFAndMultilineData() {
        var parser = SSEStreamParser()
        let events = parser.feed(Data(": keep-alive\r\ndata: line one\r\ndata: line two\r\nid: 7\r\n\r\n".utf8))
        XCTAssertEqual(events, [SSEEvent(event: nil, data: "line one\nline two")])
    }

    func testFinishFlushesTrailingEvent() {
        var parser = SSEStreamParser()
        XCTAssertTrue(parser.feed(Data("data: tail".utf8)).isEmpty)
        XCTAssertEqual(parser.finish(), [SSEEvent(event: nil, data: "tail")])
    }
}

#if !APP_STORE
final class ClaudeStreamParserTests: XCTestCase {

    /// Shape captured from a real `claude -p --output-format stream-json --verbose
    /// --include-partial-messages --json-schema …` run (claude 2.1.308).
    private let transcript = [
        #"{"type":"system","subtype":"init"}"#,
        #"{"type":"stream_event","event":{"type":"message_start"}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Database"}}}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":" Choice\", \"overview\": \"Alice picked Postgres.\"}"}}}"#,
        #"{"type":"rate_limit_event"}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"{}","structured_output":{"title":"Database Choice","overview":"Alice picked Postgres."}}"#,
    ].joined(separator: "\n") + "\n"

    func testAccumulatesDeltasAndReadsResult() throws {
        let parser = ClaudeStreamParser()
        // Feed in awkward chunk sizes to exercise line reassembly.
        var rest = Substring(transcript)
        while !rest.isEmpty {
            let n = min(17, rest.count)
            parser.feed(String(rest.prefix(n)))
            rest = rest.dropFirst(n)
        }
        parser.finish()
        XCTAssertEqual(MeetingNotesSchema.streamedTitle(in: parser.streamedText), "Database Choice")
        let result = try XCTUnwrap(parser.result)
        XCTAssertFalse(result.isError)
        let notes = try XCTUnwrap(MeetingNotesSchema.decode(object: try XCTUnwrap(result.structured)))
        XCTAssertEqual(notes.summary.overview, "Alice picked Postgres.")
    }

    func testErrorResultIsClassified() throws {
        let parser = ClaudeStreamParser()
        parser.feed(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Claude AI usage limit reached|1762300800"}"# + "\n")
        let outcome = Result { try ClaudeCodeProvider.outcome(parser: parser, result: CLIResult(stdout: "", stderr: "", exitCode: 1)) }
        guard case .failure(let error as MeetingAIProviderError) = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .quotaExhausted(retryAfter: nil))
    }

    func testAuthStatusParsing() {
        XCTAssertEqual(ClaudeCodeProvider.readiness(fromAuthStatus: #"{"loggedIn": true, "authMethod": "claude.ai"}"#),
                       .ready(detail: "Claude plan"))
        XCTAssertEqual(ClaudeCodeProvider.readiness(fromAuthStatus: #"{"loggedIn": true, "authMethod": "apiKey"}"#),
                       .ready(detail: "API key"))
        if case .notSignedIn = ClaudeCodeProvider.readiness(fromAuthStatus: #"{"loggedIn": false}"#) {} else {
            XCTFail("logged out must read as not signed in")
        }
    }

    func testCodexLoginStatusParsing() {
        XCTAssertEqual(CodexProvider.readiness(fromLoginStatus: "Logged in using ChatGPT"), .ready(detail: "ChatGPT plan"))
        XCTAssertEqual(CodexProvider.readiness(fromLoginStatus: "Logged in using an API key - sk-***"), .ready(detail: "API key"))
        if case .notSignedIn = CodexProvider.readiness(fromLoginStatus: "Not logged in") {} else { XCTFail() }
    }

    func testCodexReplyPrefersOutputFile() throws {
        let reply = try CodexProvider.reply(result: CLIResult(stdout: "noise", stderr: "", exitCode: 0), collected: #"{"overview":"x"}"#)
        XCTAssertEqual(reply, #"{"overview":"x"}"#)
        XCTAssertThrowsError(try CodexProvider.reply(result: CLIResult(stdout: "", stderr: "You've hit your usage limit.", exitCode: 0), collected: nil)) { error in
            XCTAssertEqual(error as? MeetingAIProviderError, .quotaExhausted(retryAfter: nil))
        }
    }

    func testCodexArgumentsAreLockedDown() {
        let args = CodexProvider(model: nil).arguments(workDir: URL(fileURLWithPath: "/tmp/x"), prompt: "P", schemaFile: "schema.json")
        for flag in ["--sandbox", "read-only", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--output-schema"] {
            XCTAssertTrue(args.contains(flag), "missing \(flag)")
        }
        XCTAssertEqual(args.last, "P", "the prompt is the positional argument; the transcript goes on stdin")
    }

    func testClaudeArgumentsDisableToolsAndMCP() {
        let args = ClaudeCodeProvider(model: "opus").arguments(systemPrompt: "S", schema: "{}")
        let tools = args.firstIndex(of: "--tools").map { args[$0 + 1] }
        XCTAssertEqual(tools, "", "--tools \"\" disables every built-in tool")
        XCTAssertTrue(args.contains("--strict-mcp-config"), "no MCP servers, so Claude can't call back into Whisperer")
        XCTAssertTrue(args.contains("--no-session-persistence"))
        XCTAssertFalse(args.contains("--bare"), "--bare skips the keychain, where a subscription sign-in lives")
        XCTAssertEqual(args.firstIndex(of: "--model").map { args[$0 + 1] }, "opus")
    }

    func testAntigravityEnvelopeParsing() {
        XCTAssertEqual(AntigravityProvider.text(fromReply: #"{"result":"Hello"}"#), "Hello")
        let inner = #"{"response":"{\"title\":\"T\",\"overview\":\"O\"}"}"#
        XCTAssertEqual(AntigravityProvider.notes(fromReply: inner)?.title, "T")
    }
}
#endif

final class ProviderErrorClassificationTests: XCTestCase {

    func testClassify() {
        XCTAssertEqual(MeetingAIProviderError.classify("Error: rate limit exceeded", exitCode: 1), .quotaExhausted(retryAfter: nil))
        XCTAssertEqual(MeetingAIProviderError.classify("Not logged in · Please run /login", exitCode: 1), .notSignedIn)
        XCTAssertEqual(MeetingAIProviderError.classify("prompt is too long: context exceeds", exitCode: 1), .contextTooLong)
        if case .processFailed(let code, _) = MeetingAIProviderError.classify("segfault", exitCode: 139) {
            XCTAssertEqual(code, 139)
        } else { XCTFail() }
    }

    func testHTTPStatusMapping() {
        XCTAssertEqual(ProviderHTTPClient.error(status: 401, body: "", retryAfter: nil), .unauthorized)
        XCTAssertEqual(ProviderHTTPClient.error(status: 429, body: #"{"error":{"code":"insufficient_quota"}}"#, retryAfter: "30"),
                       .quotaExhausted(retryAfter: 30))
        XCTAssertEqual(ProviderHTTPClient.error(status: 429, body: "slow down", retryAfter: "5"), .rateLimited(retryAfter: 5))
        XCTAssertEqual(ProviderHTTPClient.error(status: 400, body: "maximum context length is 128000 tokens", retryAfter: nil),
                       .contextTooLong)
        XCTAssertEqual(ProviderHTTPClient.map(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(ProviderHTTPClient.map(CancellationError()), .cancelled)
    }
}
