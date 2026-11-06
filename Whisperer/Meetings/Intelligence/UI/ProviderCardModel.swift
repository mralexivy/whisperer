//
//  ProviderCardModel.swift
//  Whisperer
//
//  What a provider card on the LLM page shows, as a pure function of the
//  provider's state. Kept out of the view so the rules are unit-tested.
//

import Foundation

nonisolated struct ProviderCardModel: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case ready, attention, neutral, error }

    enum Action: Equatable, Sendable, Hashable {
        case install(URL)
        case copySignInCommand(String)
        case connectChatGPT
        case disconnectChatGPT
        case enterKey
        case removeKey
        case test
        case useForMeetings
        case stopUsing
        case revokePermission
    }

    var id: AIProviderID
    var statusText: String
    var tone: Tone
    var isInUse: Bool
    var badge: String?
    var primary: Action?
    var secondary: [Action]

    static func make(id: AIProviderID,
                     readiness: ProviderReadiness?,
                     isChecking: Bool,
                     isSelected: Bool,
                     hasConsent: Bool,
                     keepLocalOnly: Bool,
                     installURL: URL?,
                     signInCommand: String?) -> ProviderCardModel {
        let inUse = isSelected && hasConsent && !keepLocalOnly
        var model = ProviderCardModel(
            id: id,
            statusText: isChecking ? "Checking…" : (readiness?.statusText ?? "Not checked"),
            tone: .neutral,
            isInUse: inUse,
            badge: id.isPreview ? "Preview" : nil,
            primary: nil,
            secondary: [])

        let selectAction: Action = inUse ? .stopUsing : .useForMeetings

        switch readiness {
        case .none:
            model.tone = .neutral
            model.primary = id.kind == .apiKey ? .enterKey : (id.kind == .oauth ? .connectChatGPT : .test)
        case .ready?:
            model.tone = .ready
            model.primary = selectAction
            model.secondary = [.test]
        case .notInstalled?:
            model.tone = .attention
            model.primary = installURL.map(Action.install)
        case .notSignedIn(let hint)?:
            model.tone = .attention
            switch id.kind {
            case .oauth: model.primary = .connectChatGPT
            case .cli:   model.primary = (signInCommand ?? (hint.isEmpty ? nil : hint)).map(Action.copySignInCommand)
            case .apiKey: model.primary = .enterKey
            }
            model.secondary = [.test]
        case .needsKey?:
            model.tone = .attention
            model.primary = .enterKey
        case .quotaExhausted?:
            model.tone = .error
            model.primary = selectAction
            model.secondary = [.test]
        case .unavailable?:
            model.tone = .error
            model.primary = id.kind == .apiKey ? .enterKey : .test
        }

        if id.kind == .apiKey, readiness?.isReady == true || readiness == .some(.unavailable("Key rejected")) {
            model.secondary.append(.removeKey)
        }
        if id.kind == .oauth, readiness?.isReady == true {
            model.secondary.append(.disconnectChatGPT)
        }
        if hasConsent { model.secondary.append(.revokePermission) }
        if isChecking { model.primary = nil }
        return model
    }
}
