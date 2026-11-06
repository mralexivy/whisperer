//
//  CalendarAccounts.swift
//  Whisperer
//
//  Google Calendar and Outlook / Microsoft 365, connected directly with "Sign in with Google /
//  Microsoft". These are the app's only calendar sources — nothing depends on the macOS Calendar
//  app or its permission. Read-only scopes, OAuth with PKCE (no client secret ships in the app),
//  tokens in the Keychain, events fetched straight from the provider — nothing passes through a
//  server of ours.
//
//  Configuration: each provider needs an OAuth client registered by the app's owner. Set the
//  client IDs in Info.plist (`WhispererGoogleCalendarClientID`, `WhispererMicrosoftCalendarClientID`)
//  — see docs/exec-plans/calendar-oauth-setup.md. Without one, that provider's button explains
//  it is not configured instead of failing.
//

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// A calendar the user can switch on or off in Settings.
struct CalendarSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    /// sRGB components of the calendar's colour, for the selection list.
    let color: [Double]
}

// MARK: - Provider definitions

enum CalendarAccountProvider: String, Codable, CaseIterable, Sendable {
    case google
    case microsoft

    var displayName: String {
        switch self {
        case .google: return "Google Calendar"
        case .microsoft: return "Outlook / Microsoft 365"
        }
    }

    var shortName: String { self == .google ? "Google" : "Outlook" }

    /// Info.plist key holding the OAuth client ID.
    var clientIDKey: String {
        switch self {
        case .google: return "WhispererGoogleCalendarClientID"
        case .microsoft: return "WhispererMicrosoftCalendarClientID"
        }
    }

    var clientID: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: clientIDKey) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    var isConfigured: Bool { clientID != nil }

    /// Least privilege: read events and the calendar list, plus the identity to label the account.
    var scopes: [String] {
        switch self {
        case .google:
            return ["openid", "email",
                    "https://www.googleapis.com/auth/calendar.events.readonly",
                    "https://www.googleapis.com/auth/calendar.calendarlist.readonly"]
        case .microsoft:
            return ["openid", "email", "offline_access", "User.Read", "Calendars.Read"]
        }
    }

    var authorizeURL: URL {
        switch self {
        case .google: return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        }
    }

    var tokenURL: URL {
        switch self {
        case .google: return URL(string: "https://oauth2.googleapis.com/token")!
        case .microsoft: return URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        }
    }

    /// Google's installed-app (iOS/macOS client) redirect is the reversed client ID; Microsoft's
    /// "Mobile and desktop" platform takes the bundle-ID scheme registered for the app.
    func redirect(clientID: String) -> (uri: String, scheme: String) {
        switch self {
        case .google:
            let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            let scheme = "com.googleusercontent.apps.\(prefix)"
            return ("\(scheme):/oauth2redirect", scheme)
        case .microsoft:
            let scheme = "msauth.\(Bundle.main.bundleIdentifier ?? "com.ivy.whisperer")"
            return ("\(scheme)://auth", scheme)
        }
    }
}

/// A signed-in calendar account. The email labels it; tokens live only in the Keychain.
struct CalendarAccount: Codable, Identifiable, Equatable, Sendable {
    let provider: CalendarAccountProvider
    let email: String
    var id: String { "\(provider.rawValue):\(email.lowercased())" }
}

struct OAuthTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

enum CalendarAccountError: LocalizedError {
    case notConfigured(CalendarAccountProvider)
    case cancelled
    case authorizationFailed(String)
    case needsReconnect
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let p): return "\(p.shortName) sign-in isn't set up in this build."
        case .cancelled: return "Sign-in was cancelled."
        case .authorizationFailed(let why): return "Sign-in failed: \(why)"
        case .needsReconnect: return "Sign in again to keep this calendar connected."
        case .http(let code): return "The calendar service returned an error (\(code))."
        }
    }
}

// MARK: - OAuth (PKCE)

@MainActor
final class CalendarOAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = CalendarOAuthClient()
    private static let keychain = KeychainStore(service: "com.ivy.whisperer.calendar-accounts")
    private var session: ASWebAuthenticationSession?

    /// Runs the sign-in sheet and returns the account plus its tokens.
    func signIn(_ provider: CalendarAccountProvider) async throws -> (CalendarAccount, OAuthTokens) {
        guard let clientID = provider.clientID else { throw CalendarAccountError.notConfigured(provider) }
        let redirect = provider.redirect(clientID: clientID)
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomURLSafe(24)

        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.uri),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: provider.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        if provider == .google {
            items += [.init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent")]
        } else {
            items += [.init(name: "response_mode", value: "query"), .init(name: "prompt", value: "select_account")]
        }
        components.queryItems = items

        let callback = try await present(url: components.url!, scheme: redirect.scheme)
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = query.first(where: { $0.name == "error" })?.value {
            throw error == "access_denied" ? CalendarAccountError.cancelled : CalendarAccountError.authorizationFailed(error)
        }
        guard query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else {
            throw CalendarAccountError.authorizationFailed("the response did not match the request")
        }

        let token = try await exchange(provider: provider, form: [
            "grant_type": "authorization_code", "code": code, "client_id": clientID,
            "redirect_uri": redirect.uri, "code_verifier": verifier,
        ])
        let tokens = OAuthTokens(accessToken: token.accessToken, refreshToken: token.refreshToken,
                                 expiresAt: Date().addingTimeInterval(token.expiresIn))
        let email = try await Self.accountEmail(provider: provider, token: token)
        let account = CalendarAccount(provider: provider, email: email)
        Self.save(tokens, for: account)
        return (account, tokens)
    }

    /// A valid access token, refreshing it when it has expired.
    func accessToken(for account: CalendarAccount) async throws -> String {
        guard var tokens = Self.load(for: account) else { throw CalendarAccountError.needsReconnect }
        if !tokens.isExpired { return tokens.accessToken }
        guard let refresh = tokens.refreshToken, let clientID = account.provider.clientID else {
            throw CalendarAccountError.needsReconnect
        }
        var form = ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]
        if account.provider == .microsoft { form["scope"] = account.provider.scopes.joined(separator: " ") }
        let fresh: TokenResponse
        do {
            fresh = try await exchange(provider: account.provider, form: form)
        } catch CalendarAccountError.http(let code) where code == 400 || code == 401 {
            throw CalendarAccountError.needsReconnect   // revoked or expired refresh token
        }
        tokens.accessToken = fresh.accessToken
        if let rotated = fresh.refreshToken { tokens.refreshToken = rotated }
        tokens.expiresAt = Date().addingTimeInterval(fresh.expiresIn)
        Self.save(tokens, for: account)
        return tokens.accessToken
    }

    func forget(_ account: CalendarAccount) {
        Self.keychain.remove(account.id)
    }

    // MARK: Internals

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let idToken: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token"
            case expiresIn = "expires_in", idToken = "id_token"
        }
    }

    private func exchange(provider: CalendarAccountProvider, form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: provider.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .networkConnectionLost {
            // A pooled connection that went stale while the browser was in front fails once with
            // -1005; the authorization code is still valid, so one immediate retry completes it.
            Logger.info("Calendar OAuth: \(provider.rawValue) token exchange lost its connection — retrying once", subsystem: .app)
            (data, response) = try await URLSession.shared.data(for: request)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Logger.warning("Calendar OAuth: \(provider.rawValue) token endpoint returned \(status)", subsystem: .app)
            throw CalendarAccountError.http(status)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// The account's email: from Google's ID token, or Graph `/me` for Microsoft.
    private static func accountEmail(provider: CalendarAccountProvider, token: TokenResponse) async throws -> String {
        if let idToken = token.idToken, let email = emailClaim(in: idToken) { return email }
        if provider == .microsoft {
            var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName")!)
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: request)
            let me = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let mail = (me?["mail"] as? String) ?? (me?["userPrincipalName"] as? String) { return mail }
        }
        return "\(provider.shortName) account"
    }

    /// Reads `email` from a JWT payload. The token came straight from the provider over TLS in
    /// the code exchange, so it is used as a label only — never as proof of anything.
    nonisolated static func emailClaim(in jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["email"] as? String) ?? (json["preferred_username"] as? String)
    }

    private func present(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let callback { continuation.resume(returning: callback); return }
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    continuation.resume(throwing: CalendarAccountError.cancelled)
                } else {
                    continuation.resume(throwing: CalendarAccountError.authorizationFailed(error?.localizedDescription ?? "unknown"))
                }
            }
            session.presentationContextProvider = self
            // Reuse the browser's existing Google/Microsoft session where there is one.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: CalendarAccountError.authorizationFailed("the sign-in window could not open"))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) ?? NSWindow() }
    }

    private static func save(_ tokens: OAuthTokens, for account: CalendarAccount) {
        if let data = try? JSONEncoder().encode(tokens) { keychain.set(data, for: account.id) }
    }

    private static func load(for account: CalendarAccount) -> OAuthTokens? {
        keychain.data(for: account.id).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }

    nonisolated static func randomURLSafe(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return base64URL(Data(buffer))
    }

    nonisolated static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

// MARK: - Remote calendar sources

/// Reads calendars and events for one signed-in account.
protocol RemoteCalendarSource: Sendable {
    var account: CalendarAccount { get }
    func calendars() async throws -> [CalendarSummary]
    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot]
}

extension CalendarAccount {
    /// Calendar IDs are namespaced by account so selections never collide across sources.
    func namespaced(_ calendarID: String) -> String { "\(id)|\(calendarID)" }
    func localCalendarID(_ namespaced: String) -> String? {
        let prefix = "\(id)|"
        return namespaced.hasPrefix(prefix) ? String(namespaced.dropFirst(prefix.count)) : nil
    }
}

nonisolated struct RemoteHTTP: Sendable {
    let account: CalendarAccount

    func json(_ url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        let token = try await CalendarOAuthClient.shared.accessToken(for: account)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CalendarAccountError.needsReconnect }
        guard (200..<300).contains(status) else { throw CalendarAccountError.http(status) }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

nonisolated enum CalendarDates {
    static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let rfc3339Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ string: String) -> Date? {
        rfc3339.date(from: string) ?? rfc3339Fractional.date(from: string)
    }

    /// Graph returns "2026-11-06T10:00:00.0000000" in the zone asked for (UTC here), no suffix.
    static func parseGraphUTC(_ string: String) -> Date? {
        let trimmed = string.split(separator: ".").first.map(String.init) ?? string
        return rfc3339.date(from: trimmed + "Z")
    }

    /// "yyyy-MM-dd" all-day dates, local midnight.
    static func parseDay(_ string: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: string)
    }
}

// MARK: Google

nonisolated struct GoogleCalendarSource: RemoteCalendarSource {
    let account: CalendarAccount
    private var http: RemoteHTTP { RemoteHTTP(account: account) }

    func calendars() async throws -> [CalendarSummary] {
        let json = try await http.json(URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader")!)
        let items = json["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return CalendarSummary(id: account.namespaced(id),
                                   title: (item["summaryOverride"] as? String) ?? (item["summary"] as? String) ?? id,
                                   sourceTitle: "Google · \(account.email)",
                                   color: Self.rgb(item["backgroundColor"] as? String))
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot] {
        var all: [CalendarEventSnapshot] = []
        for calendarID in calendarIDs {
            var pageToken: String?
            repeat {
                var c = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? calendarID)/events")!
                c.queryItems = [
                    .init(name: "timeMin", value: CalendarDates.rfc3339.string(from: start)),
                    .init(name: "timeMax", value: CalendarDates.rfc3339.string(from: end)),
                    .init(name: "singleEvents", value: "true"),
                    .init(name: "orderBy", value: "startTime"),
                    .init(name: "maxResults", value: "250"),
                ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
                let json = try await http.json(c.url!)
                for item in json["items"] as? [[String: Any]] ?? [] {
                    if let snapshot = Self.snapshot(item, calendarID: account.namespaced(calendarID)) { all.append(snapshot) }
                }
                pageToken = json["nextPageToken"] as? String
            } while pageToken != nil
        }
        return all
    }

    static func snapshot(_ item: [String: Any], calendarID: String) -> CalendarEventSnapshot? {
        guard let id = item["id"] as? String,
              let startObj = item["start"] as? [String: Any], let endObj = item["end"] as? [String: Any] else { return nil }
        let allDay = startObj["dateTime"] == nil
        let startAt = (startObj["dateTime"] as? String).flatMap(CalendarDates.parse)
            ?? (startObj["date"] as? String).flatMap(CalendarDates.parseDay)
        let endAt = (endObj["dateTime"] as? String).flatMap(CalendarDates.parse)
            ?? (endObj["date"] as? String).flatMap(CalendarDates.parseDay)
        guard let startAt, let endAt else { return nil }

        // Structured conference link first (Meet, or a Zoom/Teams add-on), then hangoutLink.
        let entryPoints = (item["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]] ?? []
        let video = entryPoints.first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
        let url = (video ?? item["hangoutLink"] as? String).flatMap(URL.init(string:))

        let attendees = item["attendees"] as? [[String: Any]] ?? []
        let me = attendees.first { $0["self"] as? Bool == true }
        let others = attendees.filter { $0["self"] as? Bool != true && $0["resource"] as? Bool != true }
        let eventType = item["eventType"] as? String ?? "default"

        return CalendarEventSnapshot(
            eventIdentifier: id,
            externalIdentifier: item["iCalUID"] as? String,
            calendarID: calendarID,
            title: item["summary"] as? String ?? "",
            startAt: startAt,
            endAt: endAt,
            // Focus time, out of office and working location are blocks, not meetings.
            isAllDay: allDay || ["outOfOffice", "focusTime", "workingLocation", "birthday"].contains(eventType),
            isCanceled: item["status"] as? String == "cancelled",
            url: url,
            location: item["location"] as? String,
            notes: item["description"] as? String,
            attendeeCount: attendees.isEmpty ? nil : attendees.count,
            currentUserRSVP: rsvp(me?["responseStatus"] as? String),
            isSoloEvent: others.isEmpty,
            participants: participants(attendees))
    }

    /// Attendees minus rooms and resources. Google lists the organizer among them, flagged.
    static func participants(_ attendees: [[String: Any]]) -> [MeetingParticipant] {
        attendees.compactMap { a in
            guard a["resource"] as? Bool != true, let email = a["email"] as? String, !email.isEmpty else { return nil }
            return MeetingParticipant(name: a["displayName"] as? String, email: email,
                                      isSelf: a["self"] as? Bool == true,
                                      isOrganizer: a["organizer"] as? Bool == true,
                                      response: rsvp(a["responseStatus"] as? String))
        }
    }

    static func rsvp(_ status: String?) -> MeetingRSVP {
        switch status {
        case "accepted": return .accepted
        case "tentative": return .tentative
        case "declined": return .declined
        case "needsAction": return .pending
        default: return .unknown
        }
    }

    static func rgb(_ hex: String?) -> [Double] {
        guard let hex, hex.count == 7, let v = Int(hex.dropFirst(), radix: 16) else { return [0.26, 0.52, 0.96] }
        return [Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255]
    }
}

// MARK: Microsoft

nonisolated struct MicrosoftCalendarSource: RemoteCalendarSource {
    let account: CalendarAccount
    private var http: RemoteHTTP { RemoteHTTP(account: account) }

    func calendars() async throws -> [CalendarSummary] {
        let json = try await http.json(URL(string: "https://graph.microsoft.com/v1.0/me/calendars?$select=id,name,hexColor")!)
        let items = json["value"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return CalendarSummary(id: account.namespaced(id), title: item["name"] as? String ?? "Calendar",
                                   sourceTitle: "Outlook · \(account.email)",
                                   color: GoogleCalendarSource.rgb(item["hexColor"] as? String))
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: [String]) async throws -> [CalendarEventSnapshot] {
        var all: [CalendarEventSnapshot] = []
        let select = "id,iCalUId,subject,start,end,isAllDay,isCancelled,responseStatus,onlineMeeting,onlineMeetingUrl,location,attendees,organizer,bodyPreview,showAs,isOrganizer"
        for calendarID in calendarIDs {
            var c = URLComponents(string: "https://graph.microsoft.com/v1.0/me/calendars/\(calendarID)/calendarView")!
            c.queryItems = [
                .init(name: "startDateTime", value: CalendarDates.rfc3339.string(from: start)),
                .init(name: "endDateTime", value: CalendarDates.rfc3339.string(from: end)),
                .init(name: "$top", value: "100"),
                .init(name: "$select", value: select),
            ]
            var next: URL? = c.url
            while let url = next {
                let json = try await http.json(url, headers: ["Prefer": "outlook.timezone=\"UTC\""])
                for item in json["value"] as? [[String: Any]] ?? [] {
                    if let snapshot = Self.snapshot(item, calendarID: account.namespaced(calendarID),
                                                    selfEmail: account.email) { all.append(snapshot) }
                }
                next = (json["@odata.nextLink"] as? String).flatMap(URL.init(string:))
            }
        }
        return all
    }

    static func snapshot(_ item: [String: Any], calendarID: String, selfEmail: String = "") -> CalendarEventSnapshot? {
        guard let id = item["id"] as? String,
              let s = (item["start"] as? [String: Any])?["dateTime"] as? String,
              let e = (item["end"] as? [String: Any])?["dateTime"] as? String,
              let startAt = CalendarDates.parseGraphUTC(s), let endAt = CalendarDates.parseGraphUTC(e) else { return nil }
        let join = ((item["onlineMeeting"] as? [String: Any])?["joinUrl"] as? String) ?? (item["onlineMeetingUrl"] as? String)
        let attendees = item["attendees"] as? [[String: Any]] ?? []
        let response = (item["responseStatus"] as? [String: Any])?["response"] as? String
        let isOrganizer = item["isOrganizer"] as? Bool ?? false
        return CalendarEventSnapshot(
            source: .microsoft,
            eventIdentifier: id,
            externalIdentifier: item["iCalUId"] as? String,
            calendarID: calendarID,
            title: item["subject"] as? String ?? "",
            startAt: startAt,
            endAt: endAt,
            isAllDay: item["isAllDay"] as? Bool ?? false || item["showAs"] as? String == "oof",
            isCanceled: item["isCancelled"] as? Bool ?? false,
            url: join.flatMap(URL.init(string:)),
            location: (item["location"] as? [String: Any])?["displayName"] as? String,
            notes: item["bodyPreview"] as? String,
            attendeeCount: attendees.isEmpty ? nil : attendees.count + (isOrganizer ? 1 : 0),
            currentUserRSVP: isOrganizer ? .accepted : rsvp(response),
            isSoloEvent: attendees.isEmpty,
            participants: participants(attendees: attendees, organizer: item["organizer"] as? [String: Any],
                                       isOrganizer: isOrganizer, selfEmail: selfEmail))
    }

    /// Graph lists the organizer separately from `attendees`; merge them, drop rooms and
    /// resources, and mark the signed-in account.
    static func participants(attendees: [[String: Any]], organizer: [String: Any]?,
                             isOrganizer: Bool, selfEmail: String) -> [MeetingParticipant] {
        let me = selfEmail.lowercased()
        var seen = Set<String>()
        var result: [MeetingParticipant] = []
        if let address = organizer?["emailAddress"] as? [String: Any], let email = address["address"] as? String, !email.isEmpty {
            seen.insert(email.lowercased())
            result.append(MeetingParticipant(name: address["name"] as? String, email: email,
                                             isSelf: isOrganizer || email.lowercased() == me,
                                             isOrganizer: true, response: .accepted))
        }
        for a in attendees where a["type"] as? String != "resource" {
            guard let address = a["emailAddress"] as? [String: Any], let email = address["address"] as? String,
                  !email.isEmpty, seen.insert(email.lowercased()).inserted else { continue }
            let response = (a["status"] as? [String: Any])?["response"] as? String
            result.append(MeetingParticipant(name: address["name"] as? String, email: email,
                                             isSelf: email.lowercased() == me, isOrganizer: false,
                                             response: rsvp(response)))
        }
        return result
    }

    static func rsvp(_ response: String?) -> MeetingRSVP {
        switch response {
        case "accepted", "organizer": return .accepted
        case "tentativelyAccepted": return .tentative
        case "declined": return .declined
        case "notResponded", "none": return .pending
        default: return .unknown
        }
    }
}
