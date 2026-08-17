//
//  PolishFeatureFlags.swift
//  Whisperer
//
//  The user-facing switch for the non-generative polishing path, and the only place that
//  decides whether it is live.
//
//  This exists because the path it gates is a *replacement for a shipped behaviour*, not an
//  addition beside one. On the 400-fixture corpus it measures better than the 4B on every
//  column that was compared — WER against the whole-file reference 0.188 → 0.073 mean,
//  0.140 → 0.050 median, at p95 2.4 ms of polishing instead of a 4B prefill — but "better on
//  400 of your own recordings" and "better on the next thing you dictate" are different
//  claims, and only the second one matters when the text lands in someone's editor. So the
//  default is off, the switch is in Settings, and turning it off restores the shipped path
//  exactly rather than approximately.
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
/// Every flag defaults to **off**, and every consumer must behave exactly as the shipped
/// pre-branch path does when it is off. That is the property that makes the toggle a real
/// control rather than a label: if "off" merely means "mostly the old behaviour", the user
/// cannot tell which arm produced a bad result and the comparison is worthless.
enum PolishFeatureFlags {

    // MARK: - Keys

    /// Master switch. Gates the token-graph pipeline, the paragraph pass, and the LLM
    /// short-circuit together, because they are one behaviour from the user's point of view.
    static let fastPolishKey = "fastPolishEnabled"

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
    /// Absent key means **off**, unlike `meetingPolishEnabled`, whose absent-means-on default
    /// is right for a feature that shipped enabled. This one has not shipped, so an
    /// unconfigured install must get the behaviour it had before the merge.
    static var isFastPolishEnabled: Bool {
        UserDefaults.standard.bool(forKey: fastPolishKey)
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
        isFastPolishEnabled && UserDefaults.standard.bool(forKey: editorKey)
    }

    /// Whether the paragraph pass may insert breaks.
    static var areParagraphsEnabled: Bool {
        isFastPolishEnabled && UserDefaults.standard.bool(forKey: paragraphsKey)
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
