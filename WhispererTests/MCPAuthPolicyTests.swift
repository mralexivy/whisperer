//
//  MCPAuthPolicyTests.swift
//  WhispererTests
//
//  The MCP access-token policy and request-target parsing.
//

import XCTest
@testable import whisperer

final class MCPAuthPolicyTests: XCTestCase {

    private let tok = "s3cret-token"

    func testNotRequiredAllowsAnything() {
        XCTAssertTrue(MCPAuthPolicy.isAuthorized(headers: [:], path: "/mcp", expectedToken: tok, required: false))
        XCTAssertTrue(MCPAuthPolicy.isAuthorized(headers: ["Authorization": "Bearer wrong"], path: "/mcp",
                                                 expectedToken: tok, required: false))
    }

    func testRequiredRejectsMissingAndWrongToken() {
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: [:], path: "/mcp", expectedToken: tok, required: true))
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: ["Authorization": "Bearer nope"], path: "/mcp",
                                                  expectedToken: tok, required: true))
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: ["Authorization": tok], path: "/mcp",
                                                  expectedToken: tok, required: true),
                       "a bare token without the Bearer scheme is not accepted")
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: ["Authorization": "Basic \(tok)"], path: "/mcp",
                                                  expectedToken: tok, required: true))
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: ["Authorization": "Bearer \(tok)x"], path: "/mcp",
                                                  expectedToken: tok, required: true))
    }

    func testBearerHeaderIsCaseInsensitive() {
        for (name, value) in [("Authorization", "Bearer \(tok)"),
                              ("authorization", "bearer \(tok)"),
                              ("AUTHORIZATION", "BEARER   \(tok)  ")] {
            XCTAssertTrue(MCPAuthPolicy.isAuthorized(headers: [name: value], path: "/mcp",
                                                     expectedToken: tok, required: true), "\(name): \(value)")
        }
    }

    func testQueryTokenAccepted() {
        XCTAssertTrue(MCPAuthPolicy.isAuthorized(headers: [:], path: "/mcp?token=\(tok)",
                                                 expectedToken: tok, required: true))
        XCTAssertTrue(MCPAuthPolicy.isAuthorized(headers: [:], path: "/messages?sessionId=abc&token=\(tok)",
                                                 expectedToken: tok, required: true))
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: [:], path: "/mcp?token=other",
                                                  expectedToken: tok, required: true))
    }

    func testEmptyExpectedTokenNeverMatches() {
        XCTAssertFalse(MCPAuthPolicy.isAuthorized(headers: ["Authorization": "Bearer "], path: "/mcp?token=",
                                                  expectedToken: "", required: true))
    }

    func testMakeTokenIsRandomAndURLSafe() {
        let a = MCPAuthPolicy.makeToken(), b = MCPAuthPolicy.makeToken()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 32)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted))
    }

    func testRequestTargetRouting() {
        XCTAssertEqual(MCPRequestTarget("/mcp").route, .streamableHTTP)
        XCTAssertEqual(MCPRequestTarget("/mcp/").route, .streamableHTTP)
        XCTAssertEqual(MCPRequestTarget("/mcp?token=x").route, .streamableHTTP)
        XCTAssertEqual(MCPRequestTarget("http://localhost:8080/mcp").route, .streamableHTTP)
        XCTAssertEqual(MCPRequestTarget("/sse").route, .legacySSE)
        XCTAssertEqual(MCPRequestTarget("/messages?sessionId=1").route, .legacyMessages)
        XCTAssertEqual(MCPRequestTarget("/health").route, .health)
        XCTAssertEqual(MCPRequestTarget("/").route, .notFound)
        XCTAssertEqual(MCPRequestTarget("/mcpx").route, .notFound)
        XCTAssertEqual(MCPRequestTarget(nil).route, .notFound)
    }

    func testQueryItemsAreDecoded() {
        let t = MCPRequestTarget("/messages?sessionId=A-1&token=a%2Bb%20c&flag")
        XCTAssertEqual(t.path, "/messages")
        XCTAssertEqual(t.queryItems["sessionId"], "A-1")
        XCTAssertEqual(t.queryItems["token"], "a+b c")
        XCTAssertEqual(t.queryItems["flag"], "")
    }
}
