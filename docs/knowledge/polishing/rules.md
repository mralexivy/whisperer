# Polishing — Rules (apply by default)

1. **Every gate defines its behaviour at `ASRCapabilities = []`, and that behaviour is KEEP.**
   Absent evidence never loosens a threshold — it only removes an extra reason to edit. Meetings
   run on Nemotron, which supplies no per-token evidence at all, so a rule that needs word
   timings or acoustic probabilities is a rule that exists for whisper.cpp and WhisperKit only.
   Any such rule goes behind an explicit flag (`ConfidenceGate.requireAcousticSupport`, defaulted
   off), never into the default path.

2. **Assert engine independence over the corpus, with hostile evidence.** Polish every fixture
   twice — `from(words:)` with full evidence, `from(text:)` with none — and require 0 divergences.
   Make the synthetic probabilities alternate near-0 / near-1 so a gate that reads them fails
   loudly rather than subtly. `PolishBenchmarkTests.testQualityIsIdenticalAtZeroCapability`.

3. **A pass must never empty an utterance.** Filler removal on a segment whose every word is a
   filler returns no edits. A segment is addressable — timestamp, speaker, playable audio span —
   so emptying one deletes a row rather than tidying it, and a discourse marker alone is the turn
   rather than noise inside one. Found on real data: segment 72 of `EFF8E485…` is the single word
   `כאילו` and was being replaced with the empty string.

4. **Never let a generative model's output through as prose — diff it into per-token edits and
   gate each one.** Accept-all/reject-all throws away thirty-nine good corrections to stop one
   bad one. `TranscriptDiff.edits(from:to:source:confidence:)`.

5. **Address edits by `TokenID`, never by an offset into a string that is about to change.** The
   app's utterances mix Hebrew, Russian and English, and UTF-16 offsets, grapheme counts and
   visual order disagree there silently. Compare whole tokens: Swift string equality is
   canonical-equivalence based, so composition differences do not read as edits.

6. **Refuse a rewrite that came back with no letters.** The literal diff of an empty rewrite is
   one deletion per token. Check before aligning, and log it.

7. **Apply a multi-word phrase edit all-or-nothing.** Half-applying one — the replacement lands,
   the companion delete is refused — is the one way to corrupt text that no individual gated edit
   can. Skip the phrase entirely unless every token it covers is editable.

8. **Run the passes sequentially against a scratch that simulates the gate**, not independently
   against the original sequence. Whitespace has to see the deletions — removing a word leaves two
   adjacent gaps that a pass reading the original would not know had become adjacent — and an edit
   the gate will refuse must not have its whitespace closed anyway. That bug shipped
   `не не надо` → `нене надо`.

9. **Precedence between edit sources is stated, not emergent.** user > organization > application
   > shipped > learned, and the higher source wins outright rather than by score: "the user typed
   this spelling" is not a confidence to be averaged against a shipped table. Otherwise build
   order decides the outcome.

10. **A stated edit may cross scripts; an inferred one may not.** An alias the user typed, a
    filler in an explicit vocabulary or a whitespace run is an assertion — `קוברנטיס` →
    `Kubernetes` is a dictionary entry, not a translation. A model proposal is a guess and faces
    the protection and drift guards plus a 0.99 floor, which is another way of saying nothing from
    a model auto-applies until it has been measured. Negation and digit guards apply to every
    source: a dictionary entry that eats a negation is a bug in the dictionary.

11. **Protect by masking tokens, not by substituting sentinels.** Substitution makes protection
    depend on the model returning `__URL_1__` intact, contradicts the shipped prompt's own raw
    `docker run --rm -it` examples, and — because the 13 patterns are all ASCII character classes
    — protects nothing at all in Hebrew or Russian. A mask needs no restore step and can key on
    token properties, so digits, acronyms, dictionary terms, mixed-script tokens and lone
    foreign-script words are protected in every script. Borderline cases go to hard: a hard span
    only loses the chance to be corrected, while an unprotected identifier can be silently
    rewritten.

12. **Extend a marker table to a new language only where the marker is unambiguous in it.** The
    false-positive guards in `ListFormatter` are an English word list and cannot catch a Hebrew or
    Russian misfire. So: discourse ordinals (`во-первых`, `ראשית`) yes; adjectival ordinals no
    (`ראשון`/`שני` are also Sunday/Monday, `первый`/`второй` are everyday adjectives); bare
    cardinals stay English-only, but behind an explicit `номер` / `מספר` the ambiguity is gone and
    both languages are in. Verified by measuring that the reformat count over 400 fixtures was
    unchanged at 8/400.

13. **Decide whether to invoke the LLM on content, not on length.** `text.count <= 15` skipped
    short fragments that needed punctuation and paid a 4B decode for long text that was already
    finished prose. `DeterministicPolisher.needsGenerativePass` asks whether a punctuation or
    casing judgement is actually left; 131 of 400 real transcripts clear it outright.

14. **A precision-gated model cannot supply completeness — pair it with a source that is
    high-precision by construction.** The retrained mmBERT `en/punct .` cell has recall 0.2895 at
    its precision-optimal threshold: 207 of 715 gold periods. That is not a training failure to be
    fixed with more data, it is what a 0.99 precision floor *costs*, and any model tuned to clear
    that floor will leave most boundaries unmarked. So completeness has to come from somewhere the
    precision is structural rather than tuned. For sentence ends that source is the measured pause:
    `SentenceTerminator` inserts `.` where our own VAD recorded ≥0.7 s of silence, which is evidence
    the speaker stopped rather than an opinion about prosody. Before it, 38.2% of utterances had no
    terminal mark *and* an interior run of more than twenty unpunctuated words.

15. **Derive acoustic evidence from sample counts, never from ASR word timings.** `TranscriptChunk`
    spans are `sampleIndex / sampleRate`, so they exist identically at `ASRCapabilities = []` —
    which is what lets the same pass run behind Nemotron and in meetings instead of degrading to a
    text-only fallback there. A pass that reads `TranscriptToken.audioStart` has quietly become
    engine-dependent, and the full-vs-`[]` parity test is what catches it.

16. **When a pause map might not describe the text, discard it — do not approximate.** The map is
    keyed by the whitespace token at each chunk join, so it is only valid if the chunks still join
    to exactly the text being polished. `stopAsync` applies dictionary correction and filler removal
    *after* joining, a card is often committed as a prefix with a remainder carried forward, and the
    tail dedupe rewrites the text outright. In all three the join-equality check fails and the
    caller polishes the plain string. Losing the acoustic signal costs one missing period; a
    mis-keyed pause ends a sentence in the middle of one.

17. **Separate "is this a fragment" from "may the last sentence be closed".** They come apart at the
    meetings seam: a VAD chunk wants sentence-initial capitals (not a fragment) but its *end* is a
    cut whose finality is only knowable from the silence the next chunk carries. Overloading
    `isFragment` for both would have cost meetings their capitalisation to buy correct termination.

18. **Never derive a `String.Index` from one string and apply it to another.** A `String.Index`
    encodes a UTF-8 offset and is only valid in the exact instance it came from. Two variants of
    this shipped simultaneously and both trapped in production:
    - Searching a `lowercased()` snapshot and slicing the original. `İ` (U+0130), `Ⱥ` (U+023A) and
      `Ⱦ` (U+023E) grow by a byte when lowercased, so one of them anywhere ahead of a match shifts
      every later index past its counterpart — silently garbling the extraction, then trapping.
    - Holding indices across a `replaceSubrange`. Any resize invalidates every outstanding index,
      so the *second* occurrence of a term whose replacement has a different length is
      out of bounds. This is the reported meeting-retranscribe crash.

    Carry positions as integer offsets across mutations, and convert between a string and its
    case-mapped copy through a Character distance (case mapping preserves grapheme count) with a
    `limitedBy:` backstop — `ListFormatter.mapIndex`.

19. **A range built from two independently-derived bounds needs an ordering guard, not just a
    bounds guard.** `tryPrefixedGroups` checked `pwStart < lastStart` and sliced
    `lower[firstEnd..<pwStart]`; on `"one one two"` the second marker's preceding word lands
    *inside* the first marker, so the range inverts and traps while both bounds are individually
    in range. Assert the two bounds' order explicitly.

20. **Integer accumulators over a user-supplied token stream need overflow-reporting arithmetic.**
    `SpokenNumberConverter`'s grammar accepts a scale after a scale, so ten "hundred"s in a row is
    a well-formed run and overflows Int64 — which traps in Swift rather than wrapping. Use
    `multipliedReportingOverflow`/`addingReportingOverflow` and end the run at the overflow, so the
    words parsed so far still convert. Check *before* mutating the accumulator, or the emitted
    value stops matching the span.

21. **A replace-all helper must be called once per distinct term, not once per occurrence.** The
    third correction pass iterated the word list and called a replace-every-occurrence helper for
    each. For ordinary entries the repeat visits are no-ops, but an entry whose replacement
    contains its own search term (`gpt → GPT model`) matches its own output, so N occurrences
    produced an N-fold expansion. Deduplicate the word list case-insensitively, matching the
    helper's own case-insensitive search.
