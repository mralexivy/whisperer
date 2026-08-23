//
//  NemotronPromptDictionary.swift
//  Whisperer
//
//  The `prompt_dictionary` shipped in the Nemotron model's metadata.json, and the mapping
//  from Whisperer's bare ISO-639-1 codes onto the keys it actually contains.
//

#if canImport(FluidAudio)
import Foundation

/// The set of language keys the loaded Nemotron model has a conditioning prompt for.
///
/// ### Why this has to be read
/// `setLanguage("he")` looks like it works. The model's dictionary holds `"he-IL"` and no bare
/// `"he"`, so FluidAudio finds no entry, falls back to the `auto` prompt, and the session runs
/// unconditioned — while every log line reads like success. That is how a Hebrew meeting ended up
/// pinned to Italian for forty minutes. 47 of the model's languages have regional-only keys and
/// are affected identically; the 33 with a bare alias (`en`, `it`, `fr`, …) happen to work by
/// coincidence.
///
/// The dictionary sits in the same `metadata.json` the loader already requires, so the answer is
/// on disk next to the model. Nothing here guesses.
struct NemotronPromptDictionary: Sendable {
    /// Every key in the model's `prompt_dictionary`, verbatim.
    let promptIDs: [String: Int]

    static let autoKey = "auto"

    init(promptIDs: [String: Int]) {
        self.promptIDs = promptIDs
    }

    /// Reads `metadata.json` from the model directory. Returns nil when it is missing or malformed
    /// — callers must treat that as "unknown", not as "unsupported", since a wrong `isSupported ==
    /// false` would show the user a warning about a language that works fine.
    init?(modelDirectory: URL) {
        let url = modelDirectory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["prompt_dictionary"] as? [String: Any] else { return nil }
        var ids: [String: Int] = [:]
        for (key, value) in raw {
            if let number = value as? Int { ids[key] = number }
            else if let number = value as? NSNumber { ids[key] = number.intValue }
        }
        guard !ids.isEmpty else { return nil }
        self.promptIDs = ids
    }

    /// The dictionary key to hand FluidAudio for `language`, or nil when the model has no prompt
    /// for it.
    ///
    /// Tries the bare code first, then the model's regional spellings (`he` → `he-IL`). Regional
    /// candidates are sorted so the choice is deterministic across launches — dictionary iteration
    /// order is not, and a language that resolved to `pt-BR` on one launch and `pt-PT` on the next
    /// would be a genuinely confusing bug to chase.
    func promptKey(for language: TranscriptionLanguage) -> String? {
        guard language != .auto else { return Self.autoKey }
        return promptKey(forTag: language.rawValue)
    }

    /// Same resolution for a raw tag, which may already carry a region (`"it-IT"`).
    func promptKey(forTag tag: String) -> String? {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if promptIDs[trimmed] != nil { return trimmed }

        let base = String(trimmed.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" })[0])
        if promptIDs[base] != nil { return base }

        let prefix = base + "-"
        return promptIDs.keys
            .filter { $0.lowercased().hasPrefix(prefix) }
            .sorted()
            .first
    }
}
#endif
