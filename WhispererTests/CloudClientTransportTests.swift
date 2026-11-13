import XCTest
import CryptoKit
@testable import whisperer

// MARK: - URLProtocol double

nonisolated final class CloudLocked<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func with<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var snapshot: T { with { $0 } }
}

/// Answers every request through `handler`, so the real URLSession stack (headers, bodies, redirects, errors) is
/// exercised with no network.
nonisolated final class CloudStubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: URLError?

        static func json(_ text: String, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: Data(text.utf8))
        }
        static func fail(_ code: URLError.Code) -> Reply { Reply(error: URLError(code)) }
    }
    typealias Handler = @Sendable (URLRequest, Data) -> Reply

    nonisolated(unsafe) private static var handler: Handler?
    private static let lock = NSLock()

    static func install(_ h: @escaping Handler) { lock.lock(); handler = h; lock.unlock() }
    static func uninstall() { lock.lock(); handler = nil; lock.unlock() }
    private static func current() -> Handler? { lock.lock(); defer { lock.unlock() }; return handler }

    static func session() -> URLSession { CloudHTTP.makeSession(requestTimeout: 5, protocolClasses: [CloudStubProtocol.self]) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func body(of request: URLRequest) -> Data {
        if let b = request.httpBody { return b }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var out = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            out.append(buffer, count: n)
        }
        return out
    }

    override func startLoading() {
        guard let handler = Self.current() else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let reply = handler(request, Self.body(of: request))
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Tests

final class CloudHTTPTransportTests: XCTestCase {
    private let base = URL(string: "https://api.test")!
    private var partials: URL!

    override func setUp() {
        super.setUp()
        partials = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-partials-\(UUID().uuidString)")
    }

    override func tearDown() {
        CloudStubProtocol.uninstall()
        try? FileManager.default.removeItem(at: partials)
        super.tearDown()
    }

    private func transport(token: @escaping CloudTokenProvider = { _ in "tok" }, chunk: Int = 256 << 10, download: Int = 300, attempts: Int = 3) -> CloudHTTPTransport {
        var c = CloudHTTPTransport.Configuration()
        c.uploadChunkSize = chunk
        c.downloadChunkSize = download
        c.maxAttempts = attempts
        c.sleep = { _ in }
        c.partialDirectory = partials
        let session = CloudStubProtocol.session()
        return CloudHTTPTransport(api: CloudHTTP(baseURL: base, session: session), tokens: token, blobSession: session, configuration: c)
    }

    private func grant(_ url: String = "https://storage.test/o/x?sig=1", name: String = "w/users/a/e1/audio/\(String(repeating: "a", count: 32))",
                       resumable: Bool? = nil, headers: [String: String]? = nil) -> CloudGrant {
        CloudGrant(name: name, url: url, expiresAt: Date().addingTimeInterval(600), resumable: resumable, headers: headers)
    }

    // MARK: control plane

    func testHeadsDecodesServerJSONWithNanosecondDatesAndSendsBearer() async throws {
        let seen = CloudLocked<[URLRequest]>([])
        CloudStubProtocol.install { request, _ in
            seen.with { $0.append(request) }
            return .json(#"{"serverTime":"2026-11-13T12:00:00.123456789Z","readOnly":false,"version":7,"epoch":2,"heads":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":{"seq":3,"crc":4294967295}},"snapshot":{"id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","covers":{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":2},"version":1}}"#)
        }
        let heads = try await transport().heads(since: 5)
        XCTAssertEqual(heads.version, 7)
        XCTAssertEqual(heads.epoch, 2)
        XCTAssertEqual(heads.heads?["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], CloudHead(seq: 3, crc: 4294967295))
        XCTAssertEqual(heads.snapshot?.covers["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], 2)
        XCTAssertNotNil(heads.serverTime)
        let request = try XCTUnwrap(seen.snapshot.first)
        XCTAssertEqual(request.url?.path, "/v1/sync/heads")
        XCTAssertEqual(request.url?.query, "since=5")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testHeadsUnchangedAndNoSinceParameterForNil() async throws {
        CloudStubProtocol.install { request, _ in
            XCTAssertNil(request.url?.query)
            return .json(#"{"serverTime":"2026-11-13T12:00:00Z","readOnly":true,"unchanged":true,"version":9}"#)
        }
        let heads = try await transport().heads(since: nil)
        XCTAssertEqual(heads.unchanged, true)
        XCTAssertEqual(heads.readOnly, true)
        XCTAssertEqual(heads.version, 9)
    }

    func testDateParsing() {
        let reference = Date(timeIntervalSince1970: 1_794_571_200) // 2026-11-13T12:00:00Z
        for text in ["2026-11-13T12:00:00Z", "2026-11-13T12:00:00.000Z", "2026-11-13T12:00:00.000000000Z", "2026-11-13T12:00:00.5Z", "2026-11-13T14:00:00+02:00"] {
            let date = CloudJSON.parseDate(text)
            XCTAssertNotNil(date, text)
            XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, reference.timeIntervalSince1970, accuracy: 1, text)
        }
        XCTAssertNil(CloudJSON.parseDate("yesterday"))
        XCTAssertNotNil(CloudJSON.parseDate("0001-01-01T00:00:00Z")) // Go's zero time (an unset paidUntil)
    }

    func testRequestUploadsAndCommitBodiesMatchTheServerWireFormat() async throws {
        let bodies = CloudLocked<[String: Data]>([:])
        CloudStubProtocol.install { request, body in
            bodies.with { $0[request.url!.path] = body }
            switch request.url!.path {
            case "/v1/sync/upload":
                return .json(#"{"grants":[{"name":"w/n","url":"https://s.test/u","expiresAt":"2026-11-13T12:15:00.5Z","resumable":true,"headers":{"x-goog-resumable":"start"}}]}"#)
            default:
                return .json(#"{"version":4,"head":{"seq":2,"crc":99}}"#)
            }
        }
        let t = transport()
        let grants = try await t.requestUploads([CloudUploadRequest(ref: .audio(id: String(repeating: "c", count: 32)), size: 9_000_000)])
        XCTAssertEqual(grants.first?.resumable, true)
        XCTAssertEqual(grants.first?.headers?["x-goog-resumable"], "start")
        let result = try await t.commit(device: String(repeating: "d", count: 32), seq: 2, crc: 99,
                                        extra: [.audio(id: String(repeating: "c", count: 32))],
                                        snapshot: CloudSnapshotInfo(id: String(repeating: "e", count: 32), covers: [String(repeating: "d", count: 32): 1], version: 1))
        XCTAssertEqual(result, CloudCommitResult(version: 4, head: CloudHead(seq: 2, crc: 99)))

        let upload = try JSONSerialization.jsonObject(with: try XCTUnwrap(bodies.snapshot["/v1/sync/upload"])) as? [String: Any]
        let first = (upload?["objects"] as? [[String: Any]])?.first
        XCTAssertEqual(first?["size"] as? Int, 9_000_000)
        XCTAssertEqual((first?["ref"] as? [String: Any])?["kind"] as? String, "audio")
        XCTAssertNil((first?["ref"] as? [String: Any])?["device"], "absent optionals are not sent")

        let commit = try JSONSerialization.jsonObject(with: try XCTUnwrap(bodies.snapshot["/v1/sync/commit"])) as? [String: Any]
        XCTAssertEqual(commit?["device"] as? String, String(repeating: "d", count: 32))
        XCTAssertEqual(commit?["seq"] as? Int, 2)
        XCTAssertEqual(commit?["crc"] as? Int, 99)
        XCTAssertEqual((commit?["extra"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((commit?["snapshot"] as? [String: Any])?["version"] as? Int, 1)
    }

    func testDownloadRequestAndDeleteCount() async throws {
        CloudStubProtocol.install { request, body in
            if request.url!.path == "/v1/sync/delete" { return .json(#"{"deleted":3}"#) }
            let objects = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["objects"] as? [[String: Any]]
            XCTAssertEqual(objects?.first?["kind"] as? String, "snapshots")
            return .json(#"{"grants":[{"name":"w/s","url":"https://s.test/g","expiresAt":"2026-11-13T12:01:00Z"}]}"#)
        }
        let t = transport()
        let grants = try await t.requestDownloads([.snapshot(id: String(repeating: "a", count: 32))])
        XCTAssertEqual(grants.count, 1)
        XCTAssertNil(grants[0].resumable)
        let deleted = try await t.delete([.audio(id: String(repeating: "a", count: 32))])
        XCTAssertEqual(deleted, 3)
    }

    func testUnauthorizedRenewsTheTokenExactlyOnceThenRetries() async throws {
        let forced = CloudLocked<[Bool]>([])
        let seenTokens = CloudLocked<[String]>([])
        CloudStubProtocol.install { request, _ in
            let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
            seenTokens.with { $0.append(token) }
            return token == "Bearer fresh" ? .json(#"{"version":1,"unchanged":true}"#) : .json(#"{"error":"unauthorized","message":"expired"}"#, status: 401)
        }
        let t = transport(token: { force in forced.with { $0.append(force) }; return force ? "fresh" : "stale" })
        let heads = try await t.heads(since: nil)
        XCTAssertEqual(heads.version, 1)
        XCTAssertEqual(forced.snapshot, [false, true])
        XCTAssertEqual(seenTokens.snapshot, ["Bearer stale", "Bearer fresh"])
    }

    func testSecondUnauthorizedIsSurfacedWithoutLooping() async {
        let calls = CloudLocked<Int>(0)
        CloudStubProtocol.install { _, _ in calls.with { $0 += 1 }; return .json(#"{"error":"unauthorized","message":""}"#, status: 401) }
        do { _ = try await transport().heads(since: nil); XCTFail("should throw") } catch {
            XCTAssertEqual(error as? CloudTransportError, .unauthorized)
        }
        XCTAssertEqual(calls.snapshot, 2, "one call, one renewal, one retry — never more")
    }

    func testTokenProviderVerdictIsPassedThrough() async {
        CloudStubProtocol.install { _, _ in .json(#"{"error":"unauthorized","message":""}"#, status: 401) }
        let t = transport(token: { force in if force { throw CloudTransportError.deviceRevoked }; return "t" })
        do { _ = try await t.heads(since: nil); XCTFail() } catch { XCTAssertEqual(error as? CloudTransportError, .deviceRevoked) }
    }

    func testEveryServerErrorCodeMapsToATransportError() async {
        let head = #","head":{"seq":4,"crc":7}"#
        let table: [(Int, String, String, CloudTransportError)] = [
            (409, "sequence_conflict", head, .sequenceConflict(head: CloudHead(seq: 4, crc: 7))),
            (403, "read_only", "", .readOnly),
            (402, "over_quota", "", .overQuota),
            (402, "storage_full", "", .overQuota),
            (429, "download_limit", "", .downloadLimit),
            (429, "too_many_uploads", "", .rateLimited(retryAfter: nil)),
            (409, "not_uploaded", "", .notUploaded),
            (409, "checksum_mismatch", "", .checksumMismatch),
            (403, "device_revoked", "", .deviceRevoked),
            (403, "device_not_authorized", "", .deviceRevoked),
            (403, "sealed", "", .sealed),
            (403, "no_access", "", .noAccess),
            (409, "library_required", "", .server(status: 409)),
            (404, "not_found", "", .server(status: 404)),
            (400, "bad_request", "", .server(status: 400)),
            (500, "internal", "", .server(status: 500)),
            (503, "sync_unavailable", "", .server(status: 503)),
        ]
        for (status, code, extra, expected) in table {
            CloudStubProtocol.install { _, _ in .json(#"{"error":"\#(code)","message":"m"\#(extra)}"#, status: status) }
            do { _ = try await transport().heads(since: nil); XCTFail("\(code) should throw") } catch {
                XCTAssertEqual(error as? CloudTransportError, expected, "\(status) \(code)")
            }
        }
    }

    func testRetryAfterIsParsed() async {
        CloudStubProtocol.install { _, _ in .json(#"{"error":"rate_limited","message":""}"#, status: 429, headers: ["Retry-After": "60"]) }
        do { _ = try await transport().heads(since: nil); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .rateLimited(retryAfter: 60))
        }
    }

    func testNetworkFailuresAreOffline() async {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed] {
            CloudStubProtocol.install { _, _ in .fail(code) }
            do { _ = try await transport().heads(since: nil); XCTFail() } catch {
                XCTAssertEqual(error as? CloudTransportError, .offline, "\(code)")
            }
        }
    }

    // MARK: simple uploads

    func testSimpleUploadSendsTheGrantedHeadersAndBytes() async throws {
        let seen = CloudLocked<(URLRequest, Data)?>(nil)
        CloudStubProtocol.install { request, body in seen.with { $0 = (request, body) }; return CloudStubProtocol.Reply() }
        let payload = Data((0..<5000).map { UInt8($0 % 251) })
        try await transport().upload(payload, with: grant(headers: ["x-goog-if-generation-match": "0", "x-goog-content-length-range": "0,5000"]))
        let (request, body) = try XCTUnwrap(seen.snapshot)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.absoluteString, "https://storage.test/o/x?sig=1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-if-generation-match"), "0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-content-length-range"), "0,5000")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the session token must never go to Cloud Storage")
        XCTAssertEqual(body, payload)
    }

    func testPreconditionFailedOnUploadIsSuccess() async throws {
        CloudStubProtocol.install { _, _ in CloudStubProtocol.Reply(status: 412) }
        try await transport().upload(Data([1, 2, 3]), with: grant())
    }

    func testUploadFailuresMap() async {
        for (status, expected) in [(403, CloudTransportError.server(status: 403)), (500, .server(status: 500)), (429, .rateLimited(retryAfter: nil))] {
            CloudStubProtocol.install { _, _ in CloudStubProtocol.Reply(status: status) }
            do { try await transport().upload(Data([1]), with: grant()); XCTFail() } catch { XCTAssertEqual(error as? CloudTransportError, expected) }
        }
        CloudStubProtocol.install { _, _ in .fail(.networkConnectionLost) }
        do { try await transport().upload(Data([1]), with: grant()); XCTFail() } catch { XCTAssertEqual(error as? CloudTransportError, .offline) }
    }

    // MARK: resumable uploads

    /// A minimal Cloud Storage resumable-upload server, as the protocol specifies it.
    private nonisolated final class FakeResumable: @unchecked Sendable {
        struct Log { var starts = 0; var statusQueries = 0; var chunks: [(from: Int, to: Int, total: Int, count: Int)] = [] }
        private let lock = NSLock()
        private var received = Data()
        private(set) var log = Log()
        private(set) var complete = false
        var failChunkNumbers: Set<Int> = []   // 1-based chunk PUT numbers answered with a dropped connection
        var persistFailedChunk = false
        var startStatus = 201
        private var chunkNumber = 0

        func handle(_ request: URLRequest, _ body: Data) -> CloudStubProtocol.Reply {
            lock.lock(); defer { lock.unlock() }
            if request.httpMethod == "POST" {
                log.starts += 1
                if startStatus != 201 { return .init(status: startStatus) }
                precondition(request.value(forHTTPHeaderField: "x-goog-resumable") == "start")
                return .init(status: 201, headers: ["Location": "https://storage.test/session/abc"])
            }
            precondition(request.httpMethod == "PUT")
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            if range.hasPrefix("bytes */") {
                log.statusQueries += 1
                precondition(body.isEmpty)
                return progress()
            }
            // "bytes a-b/total"
            let parts = range.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int($0) }
            precondition(parts.count == 3, "bad Content-Range \(range)")
            let (a, b, total) = (parts[0], parts[1], parts[2])
            precondition(b - a + 1 == body.count)
            if b + 1 < total { precondition(body.count % (256 << 10) == 0, "a non-final chunk must be a multiple of 256 KiB") }
            chunkNumber += 1
            log.chunks.append((a, b, total, body.count))
            if failChunkNumbers.contains(chunkNumber) {
                if persistFailedChunk, a == received.count { received.append(body) }
                return .fail(.networkConnectionLost)
            }
            precondition(a == received.count, "chunk starts at \(a) but \(received.count) committed")
            received.append(body)
            if received.count == total { complete = true; return .init(status: 200) }
            return progress()
        }

        private func progress() -> CloudStubProtocol.Reply {
            if complete { return .init(status: 200) }
            return .init(status: 308, headers: received.isEmpty ? [:] : ["Range": "bytes=0-\(received.count - 1)"])
        }

        var bytes: Data { lock.lock(); defer { lock.unlock() }; return received }
    }

    private func payload(_ n: Int) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }) }
    private let kb256 = 256 << 10

    func testResumableUploadInChunksWithGrantedHeaders() async throws {
        let fake = FakeResumable()
        let startHeaders = CloudLocked<[String: String]>([:])
        CloudStubProtocol.install { request, body in
            if request.httpMethod == "POST" { startHeaders.with { $0 = request.allHTTPHeaderFields ?? [:] } }
            return fake.handle(request, body)
        }
        let data = payload(3 * kb256 + 1234)
        try await transport().upload(data, with: grant(resumable: true, headers: ["x-goog-resumable": "start", "x-goog-if-generation-match": "0", "x-goog-content-length-range": "0,9999999"]))
        XCTAssertEqual(fake.bytes, data)
        XCTAssertTrue(fake.complete)
        XCTAssertEqual(fake.log.starts, 1)
        XCTAssertEqual(fake.log.chunks.map(\.count), [kb256, kb256, kb256, 1234])
        XCTAssertEqual(startHeaders.snapshot["x-goog-if-generation-match"], "0")
        XCTAssertNil(startHeaders.snapshot["Authorization"])
    }

    func testResumableUploadResumesFromTheCommittedOffsetAfterAnInterruption() async throws {
        let fake = FakeResumable()
        fake.failChunkNumbers = [2]           // the second chunk dies on the wire and was NOT stored
        CloudStubProtocol.install { request, body in fake.handle(request, body) }
        let data = payload(3 * kb256 + 99)
        try await transport().upload(data, with: grant(resumable: true, headers: ["x-goog-resumable": "start"]))
        XCTAssertEqual(fake.bytes, data)
        XCTAssertEqual(fake.log.starts, 1, "one session for the whole object")
        XCTAssertEqual(fake.log.statusQueries, 1, "after the failure the transfer asks where it stands")
        // chunk 1 ok, chunk 2 failed, chunk 2 again (resumed at kb256), chunk 3, then the 99-byte tail.
        XCTAssertEqual(fake.log.chunks.map(\.from), [0, kb256, kb256, 2 * kb256, 3 * kb256])
    }

    func testResumableUploadWhenTheLostReplyHadActuallyStoredTheChunk() async throws {
        let fake = FakeResumable()
        fake.failChunkNumbers = [2]; fake.persistFailedChunk = true // stored, but the reply was lost
        CloudStubProtocol.install { request, body in fake.handle(request, body) }
        let data = payload(3 * kb256)
        try await transport().upload(data, with: grant(resumable: true, headers: ["x-goog-resumable": "start"]))
        XCTAssertEqual(fake.bytes, data)
        XCTAssertEqual(fake.log.chunks.map(\.from), [0, kb256, 2 * kb256], "the stored chunk is not sent twice")
    }

    func testResumableUploadGivesUpButKeepsTheSessionForTheNextCall() async throws {
        let fake = FakeResumable()
        fake.failChunkNumbers = [2, 3]
        CloudStubProtocol.install { request, body in fake.handle(request, body) }
        let t = transport(attempts: 1)
        let data = payload(3 * kb256 + 5)
        let g = grant(resumable: true, headers: ["x-goog-resumable": "start"])
        do { try await t.upload(data, with: g); XCTFail("should give up") } catch { XCTAssertEqual(error as? CloudTransportError, .offline) }
        XCTAssertFalse(fake.complete)
        try await t.upload(data, with: g) // the engine retries later
        XCTAssertEqual(fake.bytes, data)
        XCTAssertEqual(fake.log.starts, 1, "the second call resumed the remembered session instead of starting a new one")
        XCTAssertGreaterThanOrEqual(fake.log.statusQueries, 1)
    }

    func testResumableStartOnAnExistingObjectIsSuccess() async throws {
        let fake = FakeResumable(); fake.startStatus = 412
        CloudStubProtocol.install { request, body in fake.handle(request, body) }
        try await transport().upload(payload(kb256 * 2), with: grant(resumable: true, headers: ["x-goog-resumable": "start"]))
        XCTAssertTrue(fake.log.chunks.isEmpty)
    }

    func testResumableUploadFromAFileMatchesData() async throws {
        let fake = FakeResumable()
        CloudStubProtocol.install { request, body in fake.handle(request, body) }
        let data = payload(2 * kb256 + 7)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("up-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await transport().upload(fileAt: file, size: Int64(data.count), with: grant(resumable: true, headers: ["x-goog-resumable": "start"]))
        XCTAssertEqual(fake.bytes, data)
    }

    // MARK: downloads

    /// Serves one object with ranged GET semantics.
    private nonisolated final class FakeObject: @unchecked Sendable {
        let data: Data
        var generation = "17"
        private let lock = NSLock()
        private(set) var ranges: [String] = []
        var failRequestNumbers: Set<Int> = []
        private var n = 0
        init(_ data: Data) { self.data = data }

        func handle(_ request: URLRequest) -> CloudStubProtocol.Reply {
            lock.lock(); defer { lock.unlock() }
            n += 1
            if failRequestNumbers.contains(n) { return .fail(.networkConnectionLost) }
            let header = request.value(forHTTPHeaderField: "Range") ?? ""
            ranges.append(header)
            let spec = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            guard spec.count == 2, spec[0] < data.count else {
                return .init(status: 416, headers: ["Content-Range": "bytes */\(data.count)"])
            }
            let end = min(spec[1], data.count - 1)
            return .init(status: 206, headers: ["Content-Range": "bytes \(spec[0])-\(end)/\(data.count)", "x-goog-generation": generation],
                         body: data.subdata(in: spec[0]..<(end + 1)))
        }
    }

    func testDownloadAssemblesRangedChunks() async throws {
        let object = FakeObject(payload(1000))
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let got = try await transport(download: 300).download(with: grant())
        XCTAssertEqual(got, object.data)
        XCTAssertEqual(object.ranges, ["bytes=0-299", "bytes=300-599", "bytes=600-899", "bytes=900-1199"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partials.path), [], "no partial file is left after success")
    }

    func testDownloadResumesFromThePartialFileAfterAnInterruption() async throws {
        let object = FakeObject(payload(1000))
        object.failRequestNumbers = [3]
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let t = transport(download: 300, attempts: 0) // no in-call retry: the call itself fails
        let g = grant()
        do { _ = try await t.download(with: g); XCTFail("should fail") } catch { XCTAssertEqual(error as? CloudTransportError, .offline) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: partials.path).isEmpty, "the partial survives")
        let got = try await t.download(with: g)
        XCTAssertEqual(got, object.data)
        XCTAssertEqual(object.ranges, ["bytes=0-299", "bytes=300-599", "bytes=600-899", "bytes=900-1199"], "the second call continued at 600, not 0")
    }

    func testDownloadRetriesInsideOneCall() async throws {
        let object = FakeObject(payload(700))
        object.failRequestNumbers = [2]
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let got = try await transport(download: 300, attempts: 2).download(with: grant())
        XCTAssertEqual(got, object.data)
    }

    func testDownloadRestartsWhenTheObjectWasReplaced() async throws {
        let object = FakeObject(payload(600))
        object.failRequestNumbers = [2]
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let t = transport(download: 300, attempts: 0)
        let g = grant()
        _ = try? await t.download(with: g)
        object.generation = "18" // deleted and re-uploaded in the meantime
        let got = try await t.download(with: g)
        XCTAssertEqual(got, object.data)
    }

    func testDownloadToFileAndEmptyObjectAndMissingObject() async throws {
        let object = FakeObject(payload(450))
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)/out.bin")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        try await transport(download: 200).download(with: grant(), to: target)
        XCTAssertEqual(try Data(contentsOf: target), object.data)

        let empty = FakeObject(Data())
        CloudStubProtocol.install { request, _ in empty.handle(request) }
        let none = try await transport().download(with: grant(name: "w/empty"))
        XCTAssertTrue(none.isEmpty)

        CloudStubProtocol.install { _, _ in CloudStubProtocol.Reply(status: 404) }
        do { _ = try await transport().download(with: grant(name: "w/missing")); XCTFail() } catch {
            XCTAssertEqual(error as? CloudTransportError, .server(status: 404))
        }
    }

    func testDownloadChunkNeverExceeds64MiB() async throws {
        var c = CloudHTTPTransport.Configuration()
        c.downloadChunkSize = 500 << 20
        c.partialDirectory = partials
        let object = FakeObject(payload(10))
        CloudStubProtocol.install { request, _ in object.handle(request) }
        let session = CloudStubProtocol.session()
        let clamped = CloudHTTPTransport(api: CloudHTTP(baseURL: base, session: session), tokens: { _ in "" }, blobSession: session, configuration: c)
        _ = try await clamped.download(with: grant())
        XCTAssertEqual(object.ranges.first, "bytes=0-\((64 << 20) - 1)")
    }
}
