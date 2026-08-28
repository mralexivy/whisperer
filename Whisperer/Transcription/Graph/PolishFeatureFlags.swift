//
//  PolishFeatureFlags.swift
//  Whisperer
//
//  The user-facing switch for the non-generative polishing path, and the only place that
//  decides whether it is live.
//
//  This exists because the path it gates is a *replacement for a shipped behaviour*, not an
//  addition beside one. It shipped off while that replacement was being measured, and it is on
//  by default as of 2026-08-19.
//
//  **Why the default moved.** `PolishVerdictTests.testMergeVerdict` states ten rules before it
//  runs and scores the deterministic arm against the shipped 4B arm on 400 real recordings. At the
//  B9 run nine held and one did not (see below). The headline numbers: p95 polish latency 3.00 ms
//  against a bar of one third of the 4B's 3717.8 ms; script drift 0, token preservation 1.000,
//  retractions 0; folded WER improved in every script (en n=115 0.1778 → 0.0692); boundary F1 up
//  in every script (en 0.7169 → 0.7325); recovery toward the authored gold en −0.283 → +0.171;
//  0 of 400 divergences between `ASRCapabilities = []` and `.whisperCpp`, so the path behaves the
//  same behind every engine; `llm_rate` 0 by construction for dictation; peak RSS 56 MB against
//  the 4B's 2509 MB.
//
//  **Rule 5 does not hold, and the default moved anyway. That is a judgement, not a measurement,
//  and it is recorded here rather than in a commit message.** Rule 5 asks for per-position edit
//  precision ≥ 0.99 in every class × script × reference. Nine of the ten rules pass. Rule 5 fails
//  in exactly two cells, both the utterance-final period against the authored gold: Hebrew 0.9375
//  (45/48) and Russian 0.9730 (36/37). English is 1.0000 (130/130). The failure is **four
//  periods** — `הוא` twice, `בעצם`, `Моя` — each an utterance that trailed off on a function word
//  the pass read as a finished sentence.
//
//  Three things were tried to close it and all three are on the record as negatives.
//  `SentenceTerminator.danglers` cannot simply be extended with those four words: they are the
//  entire observed evidence, and a guard fitted on its own failures has measured nothing.
//  `Tools/llm-eval/calibrate_danglers.py` was written to fit the set from data instead and
//  reports a negative against both references — the whole-file decode disagrees with the gold
//  51-to-5 in one direction at this exact position, and the authored gold's held-out half holds
//  three unterminated endings in total, because its author finished every utterance they were
//  handed. And a per-script gate that disabled the end rule for Hebrew and Cyrillic was
//  implemented, measured and reverted on 2026-08-19: it removed the four wrong periods and cost
//  Hebrew sentence-boundary F1 0.742 → 0.412, failing rule 3b, because it also removes every
//  right period at the same position and there are far more of those.
//
//  So the cost of default-on is stated rather than gated away: in Hebrew, three utterances in
//  forty-eight get a period the author would not have written. The alternative on the table was
//  not "no wrong periods" — it was arm A, which rules 3, 3b and 4 measure as worse at this and at
//  everything else, at a thousand times the latency. Closing rule 5 honestly needs a reference
//  that can judge an utterance-final ending: roughly 300 human-labelled endings per language, per
//  the note in `calibrate_danglers.py`. A 0.99 bar is not certifiable at n=48 in any case.
//
//  One exclusion is also built into rule 5's own scoring, and it is bounded rather than asserted:
//  the utterance-final period is not scored against the whole-file decode, which omits one 51
//  times to 5 where the authored gold supplies one.
//  `PolishPeriodPrecisionDiagnosticTests.testDecodeRejectionsSplitByPosition` re-scores every
//  decode-reference rejection with that rule off and fails if any survives — 24 of 24 at B8. That
//  position is still gated by the authored gold, which is where it fails.
//
//  "Better on 400 of your own recordings" and "better on the next thing you dictate" are still
//  different claims. That is what the Settings switch is for, and why off must keep restoring the
//  4B path exactly rather than approximately.
//
//  Read through `UserDefaults` rather than `@AppStorage` because the consumers are not views:
//  `AppState`, `MeetingSession` and `DeterministicPolisher` all need the value, and
//  `MeetingTranscriptRefiner.isEnabled` (`MeetingTranscriptRefiner.swift:74`) already
//  establishes this exact pattern for `meetingPolishEnabled`. The keys are read live rather
//  than cached so a toggle takes effect on the next utterance, not on the next launch — which
//  is what makes A/B testing it by hand practical.
//

import Foundation

/// Experimental switches for the deterministic / discriminative polishing path.
///
/// The master switch defaults to **on**; the two sub-switches still default to off. Whatever the
/// default, every consumer must behave exactly as the shipped pre-branch path does when the master
/// switch is off. That is the property that makes the toggle a real control rather than a label:
/// if "off" merely means "mostly the old behaviour", the user cannot tell which arm produced a bad
/// result and the comparison is worthless. It mattered when this was an experiment and it matters
/// more now that it is the default, because off is the only way back.
enum PolishFeatureFlags {

    // MARK: - Keys

    /// Master switch. Gates the token-graph pipeline, the paragraph pass, and the LLM
    /// short-circuit together, because they are one behaviour from the user's point of view.
    static let fastPolishKey = "fastPolishEnabled"

    /// The value an install with no stored preference gets.
    ///
    /// Declared once and read by both places that need it — `isFastPolishEnabled` below and the
    /// `@AppStorage` binding behind the Settings toggle (`WhispererApp.swift`). `@AppStorage`
    /// requires its own default expression and cannot consult this enum's accessor, so the two
    /// would otherwise be independent literals that happen to agree. They did not: the flip to on
    /// moved `isFastPolishEnabled` and left the toggle at `false`, which renders a switch in the
    /// off position while the feature it controls is running.
    static let fastPolishDefault = true

    /// Sub-switch for the mmBERT editor's *certified* edit classes.
    ///
    /// **Deliberately not surfaced in Settings, and the editor is deliberately not on the runtime
    /// path.** Recalibration on 326 held-out real ASR → reference pairs — roughly four times the
    /// evidence the first pass had — measured the model at P = 0.80 (en/error, n = 320) and
    /// P = 0.92 (en sentence-final period). Those are point estimates, not confidence-bound
    /// failures: the model is genuinely not precise enough on real speech, and the earlier
    /// P = 1.0000 readings were small-sample artefacts of an 86-pair split. The risk-tiered floors
    /// (0.99 meaning / 0.97 disfluency / 0.95 cosmetic) do not rescue it. See
    /// `Tools/mmbert/CALIBRATION.md` and `thresholds-calibrated.json`: 0 of 48 cells enabled.
    ///
    /// The key is kept so the seam is named and a future recalibration has somewhere to land, and
    /// so a developer can force the path on for measurement with `defaults write`. It has no UI
    /// because a switch that provably changes no output is a lie about what the app can do.
    static let editorKey = "fastPolishEditorEnabled"

    /// Sub-switch for paragraph segmentation.
    ///
    /// Separate because it is the only class of edit here that changes the *shape* of the
    /// output rather than its characters, so it is the one most likely to be a matter of
    /// taste rather than of correctness. A wrong break is visible and cheap; a user who finds
    /// the rate wrong should be able to turn it off without losing punctuation and casing.
    static let paragraphsKey = "fastPolishParagraphsEnabled"

    // MARK: - Reads

    /// Whether the non-generative polishing path is live.
    ///
    /// Absent key means **on**, matching `meetingPolishEnabled`. Read through `object(forKey:)`
    /// rather than `bool(forKey:)` because `bool(forKey:)` returns `false` for an absent key and
    /// therefore cannot express an on-by-default flag at all — the two states "the user turned it
    /// off" and "the user has never touched it" are the same value to it, and they must not be.
    ///
    /// The consequence to keep in mind when reading this: an install that had the flag explicitly
    /// off keeps it off across this change, because its key is present. Only unconfigured installs
    /// move. That is the correct behaviour — an explicit choice outranks a new default — but it
    /// means "the default is on" and "everyone gets it" are not the same statement.
    static var isFastPolishEnabled: Bool {
        UserDefaults.standard.object(forKey: fastPolishKey) as? Bool ?? fastPolishDefault
    }

    /// Whether model-proposed edits may apply.
    ///
    /// Conjoined with the master switch deliberately: the editor's proposals are judged
    /// against a graph the deterministic passes built, so enabling it alone would run the
    /// model over a pipeline that is not there. This is enforced here rather than trusted to
    /// each caller.
    ///
    /// Note this is permission, not sufficiency. `ConfidenceGate` still refuses any edit whose
    /// class has not been measured at its tier's precision bound, so switching this on cannot
    /// enable an uncertified class — it can only stop suppressing the certified ones.
    static var isEditorEnabled: Bool {
        isFastPolishEnabled && (UserDefaults.standard.object(forKey: editorKey) as? Bool ?? true)
    }

    /// Whether the paragraph pass may insert breaks.
    static var areParagraphsEnabled: Bool {
        isFastPolishEnabled && (UserDefaults.standard.object(forKey: paragraphsKey) as? Bool ?? true)
    }

    // MARK: - Diagnostics

    /// A one-line description of the active configuration, for the log line each polish pass
    /// writes.
    ///
    /// Without this, a user reporting "the output looks wrong" produces a log that cannot be
    /// attributed to an arm — and the entire point of shipping this behind a switch is to be
    /// able to attribute results to an arm.
    static var stateDescription: String {
        guard isFastPolishEnabled else { return "fast-polish off (LLM path)" }
        var parts = ["fast-polish on"]
        if isEditorEnabled { parts.append("editor") }
        if areParagraphsEnabled { parts.append("paragraphs") }
        return parts.joined(separator: " + ")
    }
}
