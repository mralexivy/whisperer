//
//  ConnectedAIStore.swift
//  Whisperer
//
//  Settings and state for Connected AI: which provider meetings use, per-provider consent,
//  model choice, API keys (Keychain) and last-known readiness.
//
//  Local stays the default. A meeting goes to a connected provider only when all hold:
//  the user picked it, consented to sending transcripts to its vendor, the "keep all meeting
//  AI on this Mac" switch is off, and the provider exists in this build.
//

import Combine
import Foundation

@MainActor
final class ConnectedAIStore: ObservableObject {
    static let shared = ConnectedAIStore()

    // MARK: Keys

    private enum Key {
        static let provider = "connectedAI.meetingProvider"
        static let keepLocal = "connectedAI.keepLocal"
        static let consent = "connectedAI.consent"
        static func model(_ id: AIProviderID) -> String { "connectedAI.model.\(id.rawValue)" }
        static func apiKey(_ id: AIProviderID) -> String { "apikey.\(id.rawValue)" }
    }

    static let defaultModels: [AIProviderID: String] = [
        .openAIKey: "gpt-5",
        .anthropicKey: "claude-sonnet-5-5",
        .geminiKey: "gemini-2.5-flash",
    ]

    // MARK: Published state

    @Published var selectedProvider: AIProviderID? {
        didSet { defaults.set(selectedProvider?.rawValue, forKey: Key.provider) }
    }
    @Published var keepLocalOnly: Bool {
        didSet { defaults.set(keepLocalOnly, forKey: Key.keepLocal) }
    }
    @Published private(set) var consented: Set<AIProviderID>
    @Published private(set) var readiness: [AIProviderID: ProviderReadiness] = [:]
    @Published private(set) var checking: Set<AIProviderID> = []
    @Published private(set) var keyRevision = 0
    /// One-line, non-modal notice after a fallback ("Claude Code hit its usage limit — notes made on this Mac").
    @Published var lastNotice: String?

    let defaults: UserDefaults
    let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .connectedAI) {
        self.defaults = defaults
        self.keychain = keychain
        selectedProvider = defaults.string(forKey: Key.provider).flatMap(AIProviderID.init(rawValue:))
        keepLocalOnly = defaults.bool(forKey: Key.keepLocal)
        consented = Set((defaults.stringArray(forKey: Key.consent) ?? []).compactMap(AIProviderID.init(rawValue:)))
    }

    // MARK: Availability

    /// Providers shown in this build, in display order.
    var availableProviders: [AIProviderID] {
        AIProviderID.allCases.filter { id in
            guard id.isAvailableInThisBuild else { return false }
            if id == .chatGPT { return ChatGPTAuth.isPreviewEnabled }
            return true
        }
    }

    /// The provider meeting AI uses right now, or nil for "on this Mac".
    var activeProviderID: AIProviderID? {
        guard !keepLocalOnly, let id = selectedProvider,
              availableProviders.contains(id), consented.contains(id) else { return nil }
        return id
    }

    func activeProvider() -> (any MeetingIntelligenceProvider)? {
        activeProviderID.flatMap(provider(for:))
    }

    // MARK: Consent

    func hasConsent(_ id: AIProviderID) -> Bool { consented.contains(id) }

    func grantConsent(_ id: AIProviderID) {
        consented.insert(id)
        defaults.set(consented.map(\.rawValue).sorted(), forKey: Key.consent)
    }

    func revokeConsent(_ id: AIProviderID) {
        consented.remove(id)
        defaults.set(consented.map(\.rawValue).sorted(), forKey: Key.consent)
        if selectedProvider == id { selectedProvider = nil }
    }

    // MARK: Models

    func model(for id: AIProviderID) -> String {
        let stored = defaults.string(forKey: Key.model(id))?.trimmingCharacters(in: .whitespaces) ?? ""
        return stored.isEmpty ? (Self.defaultModels[id] ?? "") : stored
    }

    func setModel(_ model: String, for id: AIProviderID) {
        objectWillChange.send()
        defaults.set(model.trimmingCharacters(in: .whitespaces), forKey: Key.model(id))
    }

    // MARK: API keys

    func apiKey(for id: AIProviderID) -> String? {
        let key = keychain.string(for: Key.apiKey(id))
        return (key?.isEmpty ?? true) ? nil : key
    }

    func setAPIKey(_ key: String?, for id: AIProviderID) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { keychain.remove(Key.apiKey(id)) } else { keychain.set(trimmed, for: Key.apiKey(id)) }
        keyRevision += 1
        readiness[id] = nil
    }

    // MARK: Provider construction

    func provider(for id: AIProviderID) -> (any MeetingIntelligenceProvider)? {
        let model = model(for: id)
        let keychain = self.keychain
        switch id {
        #if !APP_STORE
        case .claudeCode:  return ClaudeCodeProvider(model: model)
        case .codex:       return CodexProvider(model: model)
        case .antigravity: return AntigravityProvider(model: model)
        #else
        case .claudeCode, .codex, .antigravity: return nil
        #endif
        case .chatGPT:
            var p = OpenAIResponsesProvider(
                id: .chatGPT, model: model.isEmpty ? "gpt-5" : model,
                token: { try await ChatGPTAuth.shared.validAccessToken() }, isPlanRoute: true)
            // Plan models are reasoning models; notes, answers and cleanup don't need deep
            // thought, and "low" is the lowest effort they accept ("none"/"minimal" are 400s).
            p.reasoningEffort = "low"
            p.keyPresent = { ChatGPTAuth.shared.storedCredentials()?.hasPlanUsage ?? false }
            return p
        case .openAIKey:
            let account = Key.apiKey(id)
            var p = OpenAIResponsesProvider(
                id: .openAIKey, model: model,
                token: {
                    guard let key = keychain.string(for: account), !key.isEmpty else {
                        throw MeetingAIProviderError.unauthorized
                    }
                    return key
                }, isPlanRoute: false)
            p.keyPresent = { keychain.string(for: account)?.isEmpty == false }
            return p
        case .anthropicKey:
            let account = Key.apiKey(id)
            return AnthropicAPIProvider(model: model, apiKey: { keychain.string(for: account) })
        case .geminiKey:
            let account = Key.apiKey(id)
            return GeminiAPIProvider(model: model, apiKey: { keychain.string(for: account) })
        }
    }

    // MARK: Readiness

    #if DEBUG
    /// Test seam for UI tests that need a provider in a given state without running its CLI.
    func _setReadinessForTesting(_ value: ProviderReadiness?, for id: AIProviderID) {
        readiness[id] = value
    }
    #endif

    func refreshReadiness(_ id: AIProviderID) async {
        guard let provider = provider(for: id) else {
            readiness[id] = .unavailable("Not available in this version")
            return
        }
        checking.insert(id)
        let result = await provider.readiness()
        if id == .chatGPT, result.isReady { await adoptNewestChatGPTModel() }
        checking.remove(id)
        readiness[id] = result
    }

    /// There is no model picker for the ChatGPT plan: keep it on the newest model the
    /// account offers (a stale pick like gpt-5.6 is several seconds slower per request).
    private func adoptNewestChatGPTModel() async {
        // Only the app's own store: test stores must not reach the network.
        guard defaults === UserDefaults.standard,
              let token = try? await ChatGPTAuth.shared.validAccessToken(),
              let models = try? await OpenAIResponsesProvider.listModels(token: token),
              let newest = OpenAIResponsesProvider.newestModel(models),
              newest != model(for: .chatGPT) else { return }
        Logger.info("ChatGPT: using \(newest) (was \(model(for: .chatGPT).isEmpty ? "default" : model(for: .chatGPT)))", subsystem: .app)
        setModel(newest, for: .chatGPT)
    }

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in availableProviders {
                group.addTask { await self.refreshReadiness(id) }
            }
        }
    }

    /// Sends one tiny request to prove the provider works end to end.
    func test(_ id: AIProviderID) async -> Result<String, MeetingAIProviderError> {
        guard let provider = provider(for: id) else { return .failure(.notInstalled) }
        checking.insert(id)
        defer { checking.remove(id) }
        do {
            let answer = try await provider.ask(
                MeetingAskInput(question: "Reply with the single word OK.", transcript: "[0s] Speaker: Testing."),
                onPartial: { _ in })
            readiness[id] = .ready(detail: provider.modelLabel)
            return .success(answer)
        } catch let error as MeetingAIProviderError {
            readiness[id] = Self.readiness(after: error, id: id)
            return .failure(error)
        } catch {
            return .failure(.server(status: 0, body: error.localizedDescription))
        }
    }

    static func readiness(after error: MeetingAIProviderError, id: AIProviderID) -> ProviderReadiness {
        switch error {
        case .notInstalled: return .notInstalled
        case .notSignedIn, .unauthorized:
            switch id.kind {
            case .apiKey: return .unavailable("Key rejected")
            case .oauth:  return .notSignedIn(hint: "Continue with ChatGPT")
            case .cli:
                #if !APP_STORE
                return .notSignedIn(hint: CLIDiscovery.signInCommand(for: id) ?? "")
                #else
                return .notSignedIn(hint: "")
                #endif
            }
        case .quotaExhausted(let wait): return .quotaExhausted(until: wait.map { Date().addingTimeInterval($0) })
        default: return .unavailable(error.localizedDescription)
        }
    }

    // MARK: Fallback notice

    /// Records that `id` failed for a meeting and local took over.
    func noteFallback(_ id: AIProviderID, error: MeetingAIProviderError, meetingID: UUID?) {
        readiness[id] = Self.readiness(after: error, id: id)
        lastNotice = "\(id.displayName): \(error.localizedDescription) Used the AI on this Mac instead."
        NotificationCenter.default.post(name: .connectedAIDidFallBack, object: meetingID)
    }
}

// MARK: - Router

/// Which AI a single request uses: the user's setting, this Mac, or a one-off pick
/// (Regenerate → "with Claude Code").
nonisolated enum ProviderChoice: Equatable, Sendable {
    case automatic
    case local
    case provider(AIProviderID)
}

/// Entry point for `MeetingAIService` (an actor) to pick up the active provider.
nonisolated enum MeetingIntelligenceRouter {
    #if DEBUG
    /// Test seam: when set, used instead of the store's choice.
    nonisolated(unsafe) static var _testProvider: (any MeetingIntelligenceProvider)?
    nonisolated(unsafe) static var _testForceLocal = false
    #endif

    static func activeProvider(_ choice: ProviderChoice = .automatic) async -> (any MeetingIntelligenceProvider)? {
        #if DEBUG
        if _testForceLocal { return nil }
        if let p = _testProvider, choice != .local { return p }
        #endif
        return await MainActor.run { () -> (any MeetingIntelligenceProvider)? in
            let store = ConnectedAIStore.shared
            switch choice {
            case .automatic:
                return store.activeProvider()
            case .local:
                return nil
            case .provider(let id):
                // A one-off pick still needs consent and a build that has the provider.
                guard store.availableProviders.contains(id), store.hasConsent(id) else { return nil }
                return store.provider(for: id)
            }
        }
    }

    static func noteFallback(_ id: AIProviderID, error: Error, meetingID: UUID?) async {
        let mapped = (error as? MeetingAIProviderError) ?? .server(status: 0, body: error.localizedDescription)
        await MainActor.run { ConnectedAIStore.shared.noteFallback(id, error: mapped, meetingID: meetingID) }
    }
}

// MARK: - Provenance

/// Which AI wrote a meeting's notes. Shown as a pill on the overview.
nonisolated struct MeetingAIProvenance: Codable, Equatable, Sendable {
    /// `AIProviderID.rawValue`, or "local".
    var source: String
    var model: String?
    var date: Date

    var provider: AIProviderID? { AIProviderID(rawValue: source) }
    var isLocal: Bool { provider == nil }
    var displayName: String { provider?.displayName ?? "this Mac" }

    static let storeKey = "connectedAI.provenance"
    /// Separate record for who polished the transcript (notes and polish can differ).
    static let polishStoreKey = "connectedAI.polishProvenance"
    static let maxEntries = 2_000

    static func record(_ entry: MeetingAIProvenance, for meetingID: UUID, defaults: UserDefaults = .standard,
                       key: String = storeKey) {
        var all = load(defaults: defaults, key: key)
        all[meetingID.uuidString] = entry
        if all.count > maxEntries {
            let keep = all.sorted { $0.value.date > $1.value.date }.prefix(maxEntries)
            all = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    static func lookup(_ meetingID: UUID, defaults: UserDefaults = .standard,
                       key: String = storeKey) -> MeetingAIProvenance? {
        load(defaults: defaults, key: key)[meetingID.uuidString]
    }

    static func forget(_ meetingID: UUID, defaults: UserDefaults = .standard, key: String = storeKey) {
        var all = load(defaults: defaults, key: key)
        all[meetingID.uuidString] = nil
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    /// Decoded records per (defaults, key), so the meeting list can ask for every row cheaply.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (Data, [String: MeetingAIProvenance])] = [:]

    private static func load(defaults: UserDefaults, key: String) -> [String: MeetingAIProvenance] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        let cacheKey = "\(ObjectIdentifier(defaults).hashValue)|\(key)"
        cacheLock.lock()
        if let hit = cache[cacheKey], hit.0 == data { cacheLock.unlock(); return hit.1 }
        cacheLock.unlock()
        let decoded = decode(data)
        cacheLock.lock(); cache[cacheKey] = (data, decoded); cacheLock.unlock()
        return decoded
    }

    private static func decode(_ data: Data) -> [String: MeetingAIProvenance] {
        guard let all = try? JSONDecoder().decode([String: MeetingAIProvenance].self, from: data) else { return [:] }
        return all
    }
}
