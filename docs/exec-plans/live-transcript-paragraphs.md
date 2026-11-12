# Live transcript paragraphs — design and implementation plan

Status: **implemented 2026-11-12** (timed words, segmenter, coordinator + session wiring, post-meeting
`FinalParagraphPass` in `MeetingJobQueue` before the editor pass). The live window and the Workspace
draw the same `MeetingSession.segments` with the same per-segment cards and one speaker header per turn,
so there is nothing to keep aligned: the paragraphs are decided once, upstream. Real-data checks:
`FinalParagraphPassTests` (the 7 saved meetings: 25 → 10 cards, 15 → 0 fragments, every word kept,
idempotent) and `MeetingLiveRealAudioTests` (Apple dictation at 1x on the same meetings' audio).

> **Correction (measured while implementing).** Only *final* results carry one range per word.
> *Volatile* results carry **a single run for the whole phrase** — `rs`..`re`, where `re` moves to
> the end of the newest word. The bridge therefore places each new volatile word backwards from
> `re` (0.4 s per word, capped by the jump), so a jump in `re` over one word is a pause; finals
> replace the estimate for words not yet handed out. Checked on the 101 s pauses clip with real
> Apple dictation: 215 timed words of 216, pauses of 3 s and 6 s measured as 5.0 s and 9.2 s
> (the clip's own edge silence adds ~2 s), breaks at both, none inside the 0.4 / 1.5 s pauses.
> `AppleTimedWordsIntegrationTests`.

Status (original): proposed (2026-11-11). Scope: the meeting live text in the floating
window and the workspace, and the same engine for long dictation. No VAD, no new model, no audio
processing, no LLM in the live path.

## Measured facts this design rests on

All from `scratchpad/asrprobe` — Apple `DictationTranscriber`, our preset
(`.progressiveLongDictation`) plus `.audioTimeRange`, fed at 1× with pauses of known length
(0.4 / 1.5 / 3 / 6 s) between FLEURS sentences, en-US and he-IL, macOS 26.

| Question | Answer |
|---|---|
| Word-level audio timestamps? | **Yes.** With `.audioTimeRange` every run is one word with a start and end in audio time (en: median 1 word/run, max 3 for contractions; he: always 1). Zero untimed runs. |
| Do word gaps show real pauses? | **Yes.** Inserted 1.5 / 3 / 6 s pauses measured as 1.5–2.3 / 4.7–5.4 / 8.6–9.0 s (the clips carry their own edge silence). Natural pauses inside speech: 0.3–1.8 s. |
| How late is the text? | Volatile results lag the audio by 0.06–0.08 s (p50), ~2.5 updates/s. |
| How far back does Apple revise shown words? | **Only the last word**: p50 = p99 = max = 1 word in both languages. English also flips punctuation on its own (25 punctuation-only revisions in 101 s); Hebrew had none. |
| Is "final" a sentence? | **No.** Finals came every 21–65 s. Hebrew finals had no sentence punctuation at all (0/3); English 1/2. |
| Finalization watermark? | `resultsFinalizationTime`, monotonic in every run. |
| Phrase ranges? | `result.range` per result; coarse (tens of seconds) — useful only as Mode B. |
| Does `NLTokenizer(.sentence)` help without punctuation? | **No.** The 213-word Hebrew final and the punctuation-stripped English are each "1 sentence"; with punctuation it only repeats the periods. 0.07–1.7 ms. Not used. |

## A. Current state (what is wrong today)

Path: `SystemLivePreviewBridge` (Apple) → `MeetingSpeakerCoordinator` → `MeetingSession` cards.

1. **Timing is thrown away.** `handle(text:)` keeps `String(result.text.characters)` only; no
   `.audioTimeRange` is requested. The coordinator then stamps each new piece with the audio
   position at the moment it *arrived* (`ingestAccumulated`: `pending.append(… start: queueStart,
   end: now)`). That is callback time, exactly what must not be read as silence.
2. **Paragraph = card.** `MeetingSession` makes one `MeetingSegment` per paragraph and draws each
   as its own speaker card, so one person talking for two minutes becomes 3–5 cards with the same
   name.
3. **Breaks need a sentence end.** A soft break (`.softBreak`, the 1.2 s "gap" rule) only cuts at a
   sentence terminator that clears 12 words / 5 s. Unpunctuated Hebrew never has one, so the only
   break left is the **30 s cap**, which cuts by character share — mid-sentence.
4. **The 1.2 s gap is measured on arrival spans clipped to diarizer runs**, not on words; it fires on
   diarizer holes and misses real pauses inside one arrival burst.
5. Stable text is "the prefix three consecutive updates agree on" over the *whole* composed text —
   fine for Apple (it only revises the last word) but blind to timing.

## B. Algorithm

### Inputs (per settled word)
`Word { text, start, end, speaker?, punctAfter }` — `start/end` from `.audioTimeRange`.

A word is **settled** when it is not among the last 2 words of the newest volatile result, or its
`end ≤ resultsFinalizationTime`. Measured revision depth is 1 word, so a 2-word tail is enough;
nothing settled is ever revised, which is what makes every later decision final.

### Modes
- **A — word timing** (normal on macOS 26 with `.audioTimeRange`).
- **B — phrase ranges only** (`result.range` without runs): a gap between two *final* results
  counts only if ≥ 1.5 s; otherwise Mode C rules.
- **C — text only** (another backend, or timing missing): punctuation + length + continuation.
  Arrival time is never used as a pause.
The mode is decided per word (a word without a time range drops to C for that gap), so the
engine degrades without the UI noticing.

### Boundary score at the gap after settled word *i* (same speaker)

```
pause   = gap(i, i+1)             // Mode A; 0 in Mode C
L       = words in the open paragraph, S = its seconds

score  = 0
score += pause < 0.7 ? 0 : pause < 1.5 ? 1 : pause < 3 ? 2.5 : pause < 5 ? 4 : 6   // timing
score += endsSentence(word i) ? 1.5 : 0                                // weak: punctuation
score -= isContinuation(word i) ? 2 : 0                               // "and", "и", "ו…", "כי"…
score += L < 25 ? -3 : L < 60 ? 0 : L < 90 ? 1 : 2                    // readable length
break when score ≥ 3  and  (L ≥ 12 and S ≥ 5  or  pause ≥ 3)
```

Consequences, by design (checked against the formula):
- a pause of 5 s or more breaks any paragraph of 12+ words (6 − 3 = 3);
- a 3–5 s pause breaks from 25 words (4 + 0);
- a 1.5–3 s pause breaks from 25 words at a sentence end (2.5 + 1.5), or from 60 words without one (2.5 + 1);
- a 0.7–1.5 s pause breaks only past 60 words at a sentence end (1 + 1 + 1.5), or past 90 words (1 + 2);
- "and …" / "כי …" before a pause costs 2: a 3–5 s pause then needs 60+ words, a 5 s+ pause 25+;
- **no timing, no punctuation (Mode C):** from L ≥ 90 the best-scoring gap in the last 40 words wins
  (sentence end > non-continuation word > anything not inside a number, URL or `v1.2`); at L = 140
  that choice is forced. Prefer a long paragraph to fragments.

`isContinuation` is a small, tested, optional list per script: en `and but because so or that which`,
ru `и а но что потому поэтому или`, he `ו`-prefixed words, `אבל כי ש לכן או`. Language-agnostic:
the list is matched on the word, whatever language the session thinks it is in.

### Hysteresis and commitment
- Decisions are made only on settled words, so a boundary is **never moved or merged later** in
  live mode. The visible delay is zero: unsettled words render in the live tail as today.
- A boundary candidate exists from the moment its gap is settled; it becomes visible when the next
  word after it settles (a paragraph never shows as empty); it is committed with that word.
- If speech stops, the last paragraph stays open; nothing waits on a timer. Stop commits it.

### Speakers (cards are turns, paragraphs live inside them)
- A **card** is a speaker turn. A paragraph never spans two speakers.
- Speaker per word from its audio time against the diarizer's finalized turns (replaces arrival
  spans; the coordinator's "minimum introduction" floor stays: a voice owns words only after 1 s).
- A new card starts when the attributed speaker changes for ≥ 3 words / ≥ 1 s. Shorter
  interjections ("yes", "right") from another voice: shown inline as their own one-line card only
  if the diarizer is confident; otherwise kept in the current card (existing behaviour, measured
  less flicker).
- Same speaker after another speaker → new card. Same speaker after a long silence → same card,
  new paragraph.
- A late attribution correction relabels the card; it never re-flows paragraphs.

## C. Swift architecture

- `SystemLivePreviewBridge`: request `.audioTimeRange`; emit `TimedWordUpdate { generation,
  words: [TimedWord], settledCount, watermark }` next to the existing string callback (step 1 keeps
  both, so nothing breaks).
- `LiveParagraphSegmenter` (new, pure `struct`, no actors): `mutating func add(settled: [TimedWord])
  -> [SegmenterOp]` with ops `.appendWords`, `.startParagraph`, `.startTurn(speaker)`,
  `.relabelTurn`. O(1) per word; state = the open paragraph's counters and the last word.
- `MeetingSpeakerCoordinator`: attribute **words by audio time**; drop arrival-time spans.
- `MeetingSession`: replaces the gap / cap / sentence-end rules with the segmenter's ops; a
  `MeetingSegment` stays one paragraph (no data migration) and gains nothing new.
- UI (`MeetingTranscriptView`, live window): **render consecutive segments of one speaker as one
  card with paragraph spacing.** UI-only, so every existing meeting benefits too.
- Final mode: after polish, a post-meeting pass re-runs the same scorer on the polished text with
  punctuation weighted 2.5 instead of 1.5, mapped by timestamps; user-edited cards are kept.

## D. UX rules
Live tail always visible and instant; paragraphs appear when their first settled word does; no
re-flow of anything already settled; RTL paragraphs keep `NSTextField` base direction per
paragraph; mixed-script text is never split on a script change.

## E. Edge cases (expected behaviour)

| # | Case | Expected |
|---|---|---|
| 1 | Continuous, no punctuation | One paragraph until a 1.5–3 s pause at L ≥ 60, a 3 s+ pause at L ≥ 25, or the Mode-C choice at 90–140 words |
| 2 | 100-word monologue, no pauses | Break at the best gap in words 90–100 (sentence end or non-continuation) |
| 3 | 300 words, no punctuation | 2–3 paragraphs of 90–140 words, never inside a number/URL |
| 4 | Wrong period | +1.5 only; alone never breaks under 60 words |
| 5 | Punctuation only in final | Live unaffected; final pass may re-paragraph (after the meeting) |
| 6 | Punctuation removed between partials | Ignored: only settled words are scored |
| 7 | Five shown words replaced | Cannot happen on Apple (measured max 1); other backends: replaced words are unsettled tail |
| 8 | Repeated text for same range | Settled count is monotonic per generation; duplicates dropped by audio time |
| 9 | Partly overlapping range | Words with `start <` last settled end are dropped |
| 10 | Late / out of order | Ignored if older than last settled word; never reorders |
| 11 | 3 s pause mid-thought ("and…") | Stays open unless L ≥ 60 (4 − 2 + 1 = 3) |
| 12 | 7 s pause, continues | New paragraph once L ≥ 12 (6 − 3 = 3) |
| 13 | Instant speaker change | New card at the first word attributed to the new speaker |
| 14 | Overlap | Words go to the diarizer's dominant speaker for their time; no merged paragraph |
| 15 | "yes", "right" | Absorbed unless the diarizer is confident (see Speakers) |
| 16 | Long technical explanation | Paragraphs of 25–90 words at pauses |
| 17–19 | en↔he, ru↔en, three languages | One paragraph; language never a boundary |
| 20 | `v1.2`, `GPT-6`, URLs | No break inside a token; period inside a token is not a sentence end |
| 21 | Restarts a sentence | Usually no pause → stays |
| 22 | Enumerates a list | Breaks only at pauses; final pass formats lists (existing) |
| 23 | "because" + pause | Continuation −2 holds it |
| 24 | No timestamps | Mode C |
| 25 | Coarse phrase times | Mode B |
| 26 | Attribution arrives late | Words wait in the tail ≤ 1 s (existing diarizer lag); card label then fixed |
| 27 | Attribution corrected | Card relabelled, paragraphs unchanged |
| 28 | Stop while pending | Commit open paragraph |
| 29 | Backend switch | New generation; segmenter resets the open paragraph boundary, keeps turns |
| 30 | Whisper final differs | Final pass replaces text by time range; live paragraphs not re-flowed until the meeting ends |

Max retroactive revision in live mode: **none** for settled words; the 2-word tail only.

## F. Implementation steps (each shippable and revertible)

1. Capture: `.audioTimeRange` + `TimedWordUpdate` beside today's string path; record event traces
   (Debug) for benchmarks. No behaviour change.
2. `LiveParagraphSegmenter` + unit tests for the 30 cases (pure, no UI).
3. Coordinator attributes words by audio time.
4. `MeetingSession` uses segmenter ops behind a flag (`meetingParagraphEngine`), old rules kept.
5. UI: consecutive same-speaker segments render as one card (independent of 4).
6. Post-meeting re-paragraph of the polished transcript.
7. Turn the flag on after the benchmark gate below.

## G. Validation
- Traces: `pauses-en/he.wav`, the he/en/ru/he/en replay, and recorded event traces from real
  meetings (step 1 records them).
- Baselines: current rules; fixed every-N-words; punctuation-only; timing-only; proposed; Mode C.
- Metrics: boundary precision/recall vs. hand-marked boundaries; paragraphs < 12 words (fragmentation)
  and > 140 (walls); cards per speaker turn; layout revisions (must be 0 for settled text);
  cost per update (target < 0.05 ms) and memory flat over a 3-hour replay.
- Ablation: drop each of timing, punctuation, continuation, length pressure in turn; keep only the
  terms that move precision/recall.
- Gate: precision and recall both ≥ the current rules on every trace, zero settled-text revisions,
  fragmentation and walls each lower than today.

## Answers in one line each
1–4: use Apple's own word timing (`.audioTimeRange`), measured accurate; text-only fallback scores
punctuation, length and continuation. 5: continuation words + length. 6: from 90 words at the best
gap, forced by 140. 7: decide only on settled words (Apple revises one word). 8: when the next word
after the gap settles. 9: new card only on a speaker change. 10: language is never a signal.
11: O(1) per word, no NLP, no model. 12: the G benchmarks. 13: timing and length carry it;
punctuation and continuation are on probation in the ablation; NLTokenizer is out. 14: the score
above.
