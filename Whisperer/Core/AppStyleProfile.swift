//
//  AppStyleProfile.swift
//  Whisperer
//
//  Which app is receiving the text, expressed as the one thing the pipeline needs to know
//  about it: how people write there.
//
//  `TextInjector.captureTargetApp()` already freezes the destination bundle ID before recording
//  starts, and `TranscriptionRecord.targetAppName` already persists it. Until now neither
//  influenced the text — the bundle ID drove only a clipboard restore delay. This is the type
//  that turns that existing knowledge into behaviour.
//
//  Deliberately small. A profile is a *classification*, not a settings object: it answers "is
//  this a chat box or an editor" and nothing else. Everything downstream reads the enum, so
//  adding a behaviour means adding one switch, not threading a new flag through the pipeline.
//

import Foundation

// MARK: - AppStyleProfile

/// How text is conventionally written in the destination app.
enum AppStyleProfile: String, CaseIterable, Sendable {
    /// Chat boxes. Short turns, and a trailing period on a one-line message reads as terse or
    /// passive-aggressive rather than as correct punctuation.
    case messaging

    /// Editors, terminals and IDEs. Prose conventions mostly do not apply and an aggressive
    /// polish is more likely to damage an identifier than to improve a sentence.
    case code

    /// Documents, mail, notes. Full prose conventions.
    case prose

    /// Unrecognised, or dictation with no destination app (clipboard-only). Behaves exactly as
    /// the app behaved before this type existed — see `Behaviour` below.
    case unknown

    // MARK: Classification

    /// Bundle IDs whose writing conventions we are confident about.
    ///
    /// Conservative by construction: an app that is not on this list gets `.unknown`, which is
    /// byte-for-byte today's behaviour. Guessing from an app's category or name would put the
    /// burden of proof on the wrong side — a wrong guess silently changes output in an app the
    /// user never opted in for.
    private static let builtIn: [String: AppStyleProfile] = [
        // Messaging
        "com.tinyspeck.slackmacgap":           .messaging,   // Slack
        "com.apple.MobileSMS":                 .messaging,   // Messages
        "net.whatsapp.WhatsApp":               .messaging,
        "com.hnc.Discord":                     .messaging,
        "org.telegram.desktop":                .messaging,
        "ru.keepcoder.Telegram":               .messaging,
        "com.microsoft.teams2":                .messaging,
        "com.readdle.SparkDesktop":            .messaging,

        // Code
        "com.apple.dt.Xcode":                  .code,
        "com.microsoft.VSCode":                .code,
        "com.todesktop.230313mzl4w4u92":       .code,        // Cursor
        "com.apple.Terminal":                  .code,
        "com.googlecode.iterm2":               .code,
        "dev.warp.Warp-Stable":                .code,
        "com.jetbrains.intellij":              .code,
        "com.sublimetext.4":                   .code,

        // Prose
        "com.apple.mail":                      .prose,
        "com.apple.Notes":                     .prose,
        "com.apple.TextEdit":                  .prose,
        "com.microsoft.Word":                  .prose,
        "com.microsoft.Outlook":               .prose,
        "notion.id":                           .prose,
        "md.obsidian":                         .prose,
    ]

    /// The profile for a destination bundle ID.
    ///
    /// A nil bundle ID means clipboard-only dictation with no captured destination, which is
    /// `.unknown` for the same reason an unrecognised app is: we have no evidence, so we change
    /// nothing.
    static func profile(forBundleID bundleID: String?,
                        overrides: [String: AppStyleProfile] = [:]) -> AppStyleProfile {
        guard let bundleID, !bundleID.isEmpty else { return .unknown }
        if let override = overrides[bundleID] { return override }
        return builtIn[bundleID] ?? .unknown
    }
}

// MARK: - Behaviour

extension AppStyleProfile {

    /// Whether the polisher may close the final sentence of an utterance.
    ///
    /// This maps onto `DeterministicPolisher.forTranscript(terminatesUtteranceEnd:)`, which
    /// already exists for the meetings per-utterance pass. Note what it does and does not do: it
    /// stops `SentenceTerminator` *inserting* a closing period. It does not remove one the ASR
    /// itself produced, and whisper produces one most of the time — so this flag alone does not
    /// implement messaging suppression. `suppressesTrailingPeriod` is the other half.
    var terminatesUtteranceEnd: Bool {
        self != .messaging
    }

    /// Whether an ASR-produced trailing period should be stripped from a single-sentence
    /// utterance. See `TrailingPeriodSuppressor` for the exact conditions, which are narrower
    /// than this flag suggests.
    var suppressesTrailingPeriod: Bool {
        self == .messaging
    }
}
