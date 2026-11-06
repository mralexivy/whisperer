//
//  ConnectedAIPageController.swift
//  Whisperer
//
//  Everything the LLM page does when the user clicks something. The view is a thin
//  layer that renders `ProviderCardModel`s and forwards every button to `perform` / `select`
//  here, so the page's behavior is unit-tested by driving this controller against an
//  isolated store — the same code path a click takes.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ConnectedAIPageController: ObservableObject {
    let store: ConnectedAIStore

    /// Provider whose consent sheet is showing.
    @Published var consentFor: AIProviderID?
    /// Provider whose API-key sheet is showing.
    @Published var keyEditorFor: AIProviderID?
    /// Last test / sign-in result per card.
    @Published var testMessages: [AIProviderID: String] = [:]
    @Published var copiedCommand: AIProviderID?
    @Published var signingIn = false

    /// Side effects that leave the app; tests replace them.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var cancellable: AnyCancellable?

    init(store: ConnectedAIStore = .shared) {
        self.store = store
        // Re-render the page whenever the store changes.
        cancellable = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var subscriptionProviders: [AIProviderID] { store.availableProviders.filter { $0.kind != .apiKey } }
    var apiKeyProviders: [AIProviderID] { store.availableProviders.filter { $0.kind == .apiKey } }

    // MARK: - Chooser

    func chooseLocal() {
        store.selectedProvider = nil
    }

    /// Picking a provider uses it straight away if the user already allowed it; otherwise the
    /// consent sheet opens and nothing is routed until they press Allow.
    func select(_ id: AIProviderID) {
        if store.hasConsent(id) {
            store.selectedProvider = id
            store.keepLocalOnly = false
        } else {
            consentFor = id
        }
    }

    func allowConsent(_ id: AIProviderID) {
        store.grantConsent(id)
        store.selectedProvider = id
        store.keepLocalOnly = false
        consentFor = nil
        expanded = nil
    }

    func cancelConsent() {
        consentFor = nil
        expanded = nil
    }

    // MARK: - Rows (the LLM page's single list)

    /// The row whose inline panel (consent or setup) is open.
    @Published var expanded: AIProviderID?
    /// API keys being typed into a row's inline field, not yet saved.
    @Published var keyDrafts: [AIProviderID: String] = [:]

    /// What a row's inline panel shows when it opens.
    enum RowPanel: Equatable { case none, consent, setup, manage }

    func panel(for id: AIProviderID) -> RowPanel {
        guard expanded == id else { return .none }
        if consentFor == id { return .consent }
        return store.activeProviderID == id ? .manage : .setup
    }

    /// Clicking a row: a ready, allowed provider is used at once; a ready one not yet allowed
    /// opens its consent panel in place; anything else opens (or closes) its setup steps.
    func rowTapped(_ id: AIProviderID) {
        // The row already in use: open or close its manage panel (test, revoke, key, sign out).
        if store.activeProviderID == id {
            consentFor = nil
            expanded = (expanded == id) ? nil : id
            return
        }
        if isChooserEnabled(id) {
            if store.hasConsent(id) {
                select(id)
                expanded = nil
            } else {
                consentFor = id
                expanded = id
            }
        } else {
            consentFor = nil
            expanded = (expanded == id) ? nil : id
        }
    }

    func localTapped() {
        chooseLocal()
        store.keepLocalOnly = false
        expanded = nil
        consentFor = nil
    }

    /// Saves the key typed into a row and, if the provider now works, moves on to consent.
    @discardableResult
    func saveKey(_ id: AIProviderID) -> Task<Void, Never> {
        let draft = keyDrafts[id] ?? ""
        store.setAPIKey(draft, for: id)
        keyDrafts[id] = nil
        return Task {
            await store.refreshReadiness(id)
            if isChooserEnabled(id) { rowTapped(id) }
        }
    }

    /// Re-checks a provider after the user ran its sign-in or install step.
    @discardableResult
    func checkAgain(_ id: AIProviderID) -> Task<Void, Never> {
        Task {
            await store.refreshReadiness(id)
            if isChooserEnabled(id) { rowTapped(id) }
        }
    }

    func isChooserEnabled(_ id: AIProviderID) -> Bool {
        store.readiness[id]?.isReady == true
    }

    var chooserFootnote: String {
        if store.keepLocalOnly { return "“Keep all meeting AI on this Mac” is on — nothing is sent." }
        guard let id = store.activeProviderID else {
            return "Meeting notes and Ask AI run on this Mac. Nothing leaves it."
        }
        return "Meeting notes and Ask AI use \(id.displayName). If it's unavailable, this Mac takes over. Dictation always stays on this Mac."
    }

    // MARK: - Cards

    func cardModel(_ id: AIProviderID) -> ProviderCardModel {
        #if !APP_STORE
        let installURL = CLIDiscovery.installURL(for: id)
        let signIn = CLIDiscovery.signInCommand(for: id)
        #else
        let installURL: URL? = nil
        let signIn: String? = nil
        #endif
        return ProviderCardModel.make(
            id: id, readiness: store.readiness[id], isChecking: store.checking.contains(id),
            isSelected: store.selectedProvider == id, hasConsent: store.hasConsent(id),
            keepLocalOnly: store.keepLocalOnly, installURL: installURL, signInCommand: signIn)
    }

    func actionLabel(_ action: ProviderCardModel.Action, id: AIProviderID) -> String {
        switch action {
        case .install:              return "Install…"
        case .copySignInCommand:    return copiedCommand == id ? "Copied — run it in Terminal" : "Copy sign-in command"
        case .connectChatGPT:       return signingIn ? "Waiting for browser…" : "Continue with ChatGPT"
        case .disconnectChatGPT:    return "Disconnect"
        case .enterKey:             return store.apiKey(for: id) == nil ? "Add key…" : "Edit key…"
        case .removeKey:            return "Remove key"
        case .test:                 return "Test"
        case .useForMeetings:       return "Use for meetings"
        case .stopUsing:            return "Stop using"
        case .revokePermission:     return "Revoke permission"
        }
    }

    /// Runs a card button. Returns the task for actions that finish asynchronously, so a
    /// caller (a test) can await the outcome.
    @discardableResult
    func perform(_ action: ProviderCardModel.Action, id: AIProviderID) -> Task<Void, Never>? {
        switch action {
        case .install(let url):
            openURL(url)
        case .copySignInCommand(let command):
            copyToPasteboard(command)
            copiedCommand = id
        case .connectChatGPT:
            signingIn = true
            return Task {
                do {
                    let creds = try await ChatGPTAuth.shared.signIn()
                    // Models differ per account; take the first listed one unless the user chose.
                    if creds.hasPlanUsage, store.model(for: id).isEmpty,
                       let token = try? await ChatGPTAuth.shared.validAccessToken(),
                       let first = OpenAIResponsesProvider.newestModel(try await OpenAIResponsesProvider.listModels(token: token)) {
                        store.setModel(first, for: id)
                    }
                    testMessages[id] = creds.hasPlanUsage
                        ? nil
                        : "Signed in, but plan usage wasn't allowed. Continue again and approve using your ChatGPT plan."
                } catch {
                    testMessages[id] = (error as? MeetingAIProviderError)?.localizedDescription ?? error.localizedDescription
                }
                signingIn = false
                await store.refreshReadiness(id)
            }
        case .disconnectChatGPT:
            return Task {
                await ChatGPTAuth.shared.signOut()
                if store.selectedProvider == id { store.selectedProvider = nil }
                await store.refreshReadiness(id)
            }
        case .enterKey:
            keyEditorFor = id
        case .removeKey:
            store.setAPIKey(nil, for: id)
            if store.selectedProvider == id { store.selectedProvider = nil }
            return Task { await store.refreshReadiness(id) }
        case .test:
            testMessages[id] = "Testing…"
            return Task {
                switch await store.test(id) {
                case .success: testMessages[id] = "Works — answered in a test request."
                case .failure(let error): testMessages[id] = error.localizedDescription
                }
            }
        case .useForMeetings:
            select(id)
        case .stopUsing:
            store.selectedProvider = nil
        case .revokePermission:
            store.revokeConsent(id)
            expanded = nil
        }
        return nil
    }
}
