//
//  LiveLanguageOffer.swift
//  Whisperer
//
//  Notices the user dictating in a language live preview does not stream in, and decides when to
//  offer it. Live preview (Apple dictation) only streams in the user's configured languages, so a
//  Russian speaker whose list says English gets no live text — and nothing tells them why.
//
//  The spoken language is trusted only when two independent signals agree: the engine's own
//  language answer and the script of the text it produced. Either alone misleads — whisper leans
//  English on short windows, and Cyrillic or Latin script names a family, not a language.
//  One sighting is not enough either: the offer waits for `sightingsBeforeOffer`.
//

import Foundation

nonisolated struct LiveLanguageOfferPolicy: Sendable {

    /// Shorter utterances carry too little text for the script check to mean anything.
    static let minimumWords = 4
    /// Share of the text's letters that must be in a script the detected language is written in.
    static let minimumScriptShare: Float = 0.8
    /// Dictations in the same unconfigured language before the offer appears.
    static let sightingsBeforeOffer = 2
    /// Dismissals after which a language is never offered again.
    static let dismissalsBeforeSilence = 2

    /// The language the user spoke, when the engine's answer and the text's script agree.
    /// When the engine gave no answer, a script only one language is written in still decides.
    static func spokenLanguage(text: String, detected: TranscriptionLanguage?) -> TranscriptionLanguage? {
        guard text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return nil }
        let shares = ScriptAnalyzer.scriptShares(in: text)
        if let detected, detected != .auto {
            let families = ScriptAnalyzer.scriptFamilies(for: detected)
            guard !families.isEmpty else { return nil }
            let share = families.reduce(Float(0)) { $0 + (shares[$1] ?? 0) }
            return share >= minimumScriptShare ? detected : nil
        }
        guard let (family, share) = shares.max(by: { $0.value < $1.value }), share >= minimumScriptShare else { return nil }
        let candidates = ScriptAnalyzer.languages(for: family)
        return candidates.count == 1 ? candidates[0] : nil
    }

    private(set) var sightings: [TranscriptionLanguage: Int] = [:]

    /// Records one finished dictation; returns the language to offer now, if any.
    /// `configured` are the languages live preview already streams in; `silenced` are the ones
    /// the user has dismissed for good.
    mutating func observe(text: String, detected: TranscriptionLanguage?,
                          configured: [TranscriptionLanguage],
                          silenced: Set<TranscriptionLanguage>) -> TranscriptionLanguage? {
        guard let spoken = Self.spokenLanguage(text: text, detected: detected),
              !configured.contains(spoken), !silenced.contains(spoken) else { return nil }
        sightings[spoken, default: 0] += 1
        guard sightings[spoken, default: 0] >= Self.sightingsBeforeOffer else { return nil }
        sightings[spoken] = 0
        return spoken
    }
}
