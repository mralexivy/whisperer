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
