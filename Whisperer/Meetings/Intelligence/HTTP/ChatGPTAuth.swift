//
//  ChatGPTAuth.swift
//  Whisperer
//
//  "Continue with ChatGPT": OAuth 2.0 authorization code + PKCE against OpenAI's Sign in
//  with ChatGPT, requesting plan usage (`chatgpt.tokens.use.direct`) so meeting requests
//  count against the user's ChatGPT plan instead of an API key.
//
//  Contract (developers.openai.com/siwc/token-sharing-open-source/sign-in, 2026-11-06):
//  - Authorize at https://auth.openai.com/api/accounts/authorize. First sign-in registers
//    dynamically: client_id=dynamic_agent_client + agent_name_hint, and the callback returns
//    the issued client_id (oaiapp_…) to reuse for later sign-ins.
//  - ext_agent_host_id identifies this Mac; chosen once and persisted.
//  - Redirect is a loopback listener on 127.0.0.1 (not localhost), started before the
//    browser opens; the port may differ between sign-ins.
//  - Token endpoint https://auth.openai.com/api/accounts/oauth/token, form-encoded, no
//    client secret. Refresh tokens rotate: access, expiry, scopes and refresh are replaced
//    together, in one Keychain write.
//  - Sign-in can succeed without plan usage: the granted scopes are checked.
//
//  Commercial apps need OpenAI's approval to use plan usage; until then the provider is listed
//  in every build with a "Preview" badge (`AIProviderID.isPreview`).
//

import AppKit
import CryptoKit
import Foundation
import Network

actor ChatGPTAuth {
    static let shared = ChatGPTAuth()

    static let authorizeEndpoint = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    static let dynamicClientID = "dynamic_agent_client"
    static let callbackPath = "/auth/callback"

    private static let credentialsAccount = "chatgpt.credentials"
    private static let hostIDKey = "connectedAI.chatGPT.hostID"

    // MARK: - Credentials

    nonisolated struct Credentials: Codable, Equatable, Sendable {
        var clientID: String
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var expiresAt: Date
        var scopes: [String]
        var email: String?

        var hasPlanUsage: Bool { scopes.contains(ChatGPTAuth.planScope) }
        func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 600 }
    }

    private let keychain: KeychainStore
    private var refreshTask: Task<Credentials, Error>?
    private var signInTask: Task<Credentials, Error>?

    init(keychain: KeychainStore = .connectedAI) {
        self.keychain = keychain
    }

    nonisolated func storedCredentials() -> Credentials? {
        guard let data = keychain.data(for: Self.credentialsAccount) else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: data)
    }

    private func save(_ credentials: Credentials) {
        if let data = try? JSONEncoder().encode(credentials) {
            keychain.set(data, for: Self.credentialsAccount)
        }
    }

    func signOut() {
        signInTask?.cancel()
        // The issued client id and host id stay: a later sign-in re-authorizes the same client.
        if var creds = storedCredentials() {
            creds.accessToken = ""
            creds.refreshToken = nil
            creds.idToken = nil
            creds.expiresAt = .distantPast
            creds.scopes = []
            save(creds)
        }
    }

    nonisolated var isSignedIn: Bool {
        guard let creds = storedCredentials() else { return false }
        return !creds.accessToken.isEmpty || creds.refreshToken != nil
    }

    /// A token valid for at least ten more minutes, refreshing (once, shared) if needed.
    func validAccessToken() async throws -> String {
        guard let creds = storedCredentials(), !creds.accessToken.isEmpty || creds.refreshToken != nil else {
            throw MeetingAIProviderError.notSignedIn
        }
        guard creds.hasPlanUsage else { throw MeetingAIProviderError.notSignedIn }
        if !creds.needsRefresh() { return creds.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await self.refresh(creds) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func refresh(_ creds: Credentials) async throws -> Credentials {
        guard let refreshToken = creds.refreshToken else { throw MeetingAIProviderError.unauthorized }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": creds.clientID,
            "resource": Self.resource,
        ]
        let json: [String: Any]
        do {
            json = try await ProviderHTTPClient.json(Self.formRequest(Self.tokenEndpoint, form))
        } catch MeetingAIProviderError.server(let status, _) where status == 400 {
            throw MeetingAIProviderError.unauthorized   // invalid_grant: refresh token revoked or reused
        }
        guard let updated = Self.credentials(fromTokenResponse: json, clientID: creds.clientID,
                                             previous: creds) else {
            throw MeetingAIProviderError.unauthorized
        }
        save(updated)
        Logger.info("ChatGPT: token refreshed", subsystem: .app)
        return updated
    }

    // MARK: - Sign in

    /// Opens the browser and waits for the loopback callback. Throws `.cancelled` if the
    /// user closes the tab — after five minutes the listener gives up.
    func signIn() async throws -> Credentials {
        signInTask?.cancel()
        let task = Task { try await self.performSignIn() }
        signInTask = task
        defer { signInTask = nil }
        return try await task.value
    }

    private func performSignIn() async throws -> Credentials {
        let previous = storedCredentials()
        let clientID = previous?.clientID ?? Self.dynamicClientID
        let pkce = Self.makePKCE()
        let state = Self.randomURLSafe(bytes: 24)
        let nonce = Self.randomURLSafe(bytes: 24)

        let listener = LoopbackCallbackListener(path: Self.callbackPath)
        let port = try await listener.start()
        let redirectURI = "http://127.0.0.1:\(port)\(Self.callbackPath)"

        let url = Self.authorizeURL(clientID: clientID, hostID: Self.hostID(), redirectURI: redirectURI,
                                    state: state, nonce: nonce, codeChallenge: pkce.challenge,
                                    idTokenHint: previous?.idToken)
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let query = try await listener.waitForCallback(timeout: 300)
        guard query["state"] == state else { throw MeetingAIProviderError.unauthorized }
        if query["error"] != nil { throw MeetingAIProviderError.cancelled }
        guard let code = query["code"] else { throw MeetingAIProviderError.unauthorized }

        // A new registration returns the issued id. On re-authorization it may be omitted;
        // a different one than saved means the response is not for this client.
        var issuedClientID = clientID
        if let returned = query["client_id"], !returned.isEmpty {
            if clientID != Self.dynamicClientID && returned != clientID { throw MeetingAIProviderError.unauthorized }
            issuedClientID = returned
        }

        let form = [
            "grant_type": "authorization_code",
            "client_id": issuedClientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": redirectURI,
            "resource": Self.resource,
        ]
        let json = try await ProviderHTTPClient.json(Self.formRequest(Self.tokenEndpoint, form))
        guard var creds = Self.credentials(fromTokenResponse: json, clientID: issuedClientID, previous: nil) else {
            throw MeetingAIProviderError.unauthorized
        }
        if creds.scopes.isEmpty, let granted = query["scope"] {
            creds.scopes = granted.split(separator: " ").map(String.init)
        }
        save(creds)
        Logger.info("ChatGPT: signed in (plan usage \(creds.hasPlanUsage ? "granted" : "declined"))", subsystem: .app)
        return creds
    }

    // MARK: - Pure helpers (tested)

    nonisolated static func hostID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: hostIDKey) { return existing }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        defaults.set(id, forKey: hostIDKey)
        return id
    }

    nonisolated static func authorizeURL(clientID: String, hostID: String, redirectURI: String,
                                         state: String, nonce: String, codeChallenge: String,
                                         idTokenHint: String?) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "resource", value: resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
        ]
        if clientID == dynamicClientID {
            items.append(URLQueryItem(name: "agent_name_hint", value: "Whisperer"))
        } else if let idTokenHint, !idTokenHint.isEmpty {
            items.append(URLQueryItem(name: "id_token_hint", value: idTokenHint))
        }
        components.queryItems = items
        return components.url!
    }

    nonisolated static func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = randomURLSafe(bytes: 48)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return (verifier, base64URL(Data(digest)))
    }

    nonisolated static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func credentials(fromTokenResponse json: [String: Any], clientID: String,
                                        previous: Credentials?, now: Date = Date()) -> Credentials? {
        guard let access = json["access_token"] as? String, !access.isEmpty else { return nil }
        let expiresIn = (json["expires_in"] as? Double) ?? (json["expires_in"] as? Int).map(Double.init) ?? 3600
        let scopes: [String]
        if let s = json["scope"] as? String {
            scopes = s.split(separator: " ").map(String.init)
        } else if let s = json["scopes"] as? [String] {
            scopes = s
        } else {
            scopes = previous?.scopes ?? []
        }
        let idToken = (json["id_token"] as? String) ?? previous?.idToken
        return Credentials(
            clientID: clientID,
            accessToken: access,
            refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
            idToken: idToken,
            expiresAt: now.addingTimeInterval(expiresIn),
            scopes: scopes,
            email: idToken.flatMap(emailFromIDToken) ?? previous?.email)
    }

    /// Display only — the email shown on the card. Nothing is authorized from it, so the
    /// signature is not checked here; the access token is what the API validates.
    nonisolated static func emailFromIDToken(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["email"] as? String
    }

    nonisolated static func formRequest(_ url: URL, _ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }
}

// MARK: - Loopback callback listener

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect. Answers a small "you can
/// close this tab" page and hands back the query parameters.
nonisolated final class LoopbackCallbackListener: @unchecked Sendable {
    private let path: String
    private let queue = DispatchQueue(label: "com.ivy.whisperer.oauth-callback")
    private var listener: NWListener?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?

    init(path: String) { self.path = path }

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { cont in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take(), let port = listener.port?.rawValue { cont.resume(returning: port) }
                case .failed(let error):
                    if once.take() { cont.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        defer { stop() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if let result {
                    lock.unlock()
                    cont.resume(with: result)
                    return
                }
                continuation = cont
                lock.unlock()
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(MeetingAIProviderError.timeout))
                }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(MeetingAIProviderError.cancelled))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: outcome)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel(); return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let components = URLComponents(string: String(parts[1])),
                  components.path == self.path else {
                Self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            var query: [String: String] = [:]
            for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
            let ok = query["code"] != nil
            Self.respond(connection, status: "200 OK", body: ok
                ? "<h2>Whisperer is connected to ChatGPT.</h2><p>You can close this tab.</p>"
                : "<h2>ChatGPT sign-in was not completed.</h2><p>You can close this tab and try again from Whisperer.</p>")
            self.finish(.success(query))
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Whisperer</title><body style=\"font-family:-apple-system;padding:40px\">\(body)</body>"
        let payload = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(payload)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
