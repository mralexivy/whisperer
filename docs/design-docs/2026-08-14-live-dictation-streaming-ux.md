# Live Dictation Streaming UX

**Status:** implemented — `Whisperer/UI/DictationStreamView.swift`, `Whisperer/UI/LiveTranscriptionCard.swift`
**Scope:** every LTR live-text surface — the dictation overlay HUD and the meeting live window's
open bubble (`MeetingLiveTranscriptView`). Both drive the same `DictationStreamView`; the HUD
passes words from the `SmoothTextUpdater` it already owns, the meeting bubble wraps the pacing
engine in `LivePourText` because it has only a growing `String`. Committed transcript cards
(`MeetingTranscriptView`, and the card list beneath the live bubble) are static text and unchanged.

## The problem

Text arrives in batches; speech does not. Nemotron emits a partial every
`NemotronBridge.chunkMs` (1120ms) and whisper.cpp finalizes a VAD chunk every 1–2s, so the UI
receives 3–7 words at once — words that were *spoken* spread evenly across that same second.

Printing a batch the moment it lands and then going quiet is the artefact this design exists to
remove. The screen alternates between a dump and dead air, and neither half resembles dictation:
the dump reads as a machine flushing a buffer, and the silence between dumps reads as the app
having stopped listening. Both are worse than the underlying latency actually is.

The fix is not to make the model faster. It is to stop discarding timing information the batch
already implies.

## The principle

**Re-time the batch to the speech that produced it.** A batch of N words that arrived one
chunk-period after the last one represents one period of speaking. Spread those N words across
that period and each word surfaces roughly when it was said. Nothing is delayed beyond the
period it was already going to be delayed by, nothing is dumped, and something is always moving.

Three consequences follow, and each is a section below: the pacing engine that does the spreading,
the per-word rendering that makes an individual word's arrival legible, and the caret that gives
the stream a source.

## 1. Pacing — `SmoothTextUpdater`

### Speech-rate drain

```
interval = clamp( (arrivalPeriod × pourDutyCycle) / pendingCount, 0.035s, 0.34s )
```

| Term | Value | Why |
|---|---|---|
| `arrivalPeriod` | seeded 1.12s, EWMA of real gaps (α = 0.4) | Seeded to Nemotron's cadence; the average lets the same code pace whisper.cpp's irregular VAD chunks and the 500ms preview pass without knowing which backend is running. Samples outside 0.2…2.5s are rejected — the first partial follows model warm-up, and a long gap is a pause in speech, not a slower encoder. |
| `pourDutyCycle` | 0.8 | Under 1.0 so jitter cannot accumulate backlog: every batch finishes a little before the next is due. At exactly 1.0 a single slow chunk puts the stream permanently behind. |
| floor | 0.035s | Below this the reveal stops reading as words arriving and starts reading as a flush — the anti-pattern in different clothes. |
| ceiling | 0.34s ≈ 175 wpm | A lone word must not hang around for most of a second waiting out a period it does not need. |

The interval is computed **once per batch** and held. Recomputing per word makes the interval grow
as the queue drains, so a phrase visibly decelerates into its own tail and overruns the next
arrival.

The **first word of a batch is unpaced** — it renders immediately. That word is the app answering;
the answer should not wait on a schedule. Only its successors are spread.

### Why a self-rescheduling one-shot timer

A repeating `Timer` fixes its interval at creation, so a mid-batch arrival could not change the
cadence until the next batch. The one-shot reschedules itself and re-reads `currentWordInterval`
each time. It is installed in `RunLoop.Mode.common`: in `.default` the run loop switches modes
while `OverlayPanel` animates its frame for an expand/collapse, and the stream visibly stalls
mid-phrase.

### Monotonic projection (pre-existing, load-bearing here)

Only words *beyond the current word count* are ever enqueued; revisions to already-displayed words
are discarded. For Nemotron this costs nothing — RNNT decoding is monotonic and every partial is a
strict prefix-extension. For whisper.cpp it trades a rare late correction for never rewriting text
the user has already read. The accurate final text still comes from the transcriber at stop, so
nothing is lost downstream.

This is also what makes per-word view identity safe: the word at index *i* is never rewritten, only
appended after.

## 2. Rendering — `DictationStreamView`

One SwiftUI view per word. A single `Text` cannot do this: per-word opacity is possible in an
attributed string, but a per-word transform is not, and a caret that glides to wherever the last
glyph landed needs that glyph to have a frame.

### Entrance

Opacity 0→1, y +4pt→0, scale 0.94→1 (anchor `.bottomLeading`), over 120ms on
`cubic-bezier(0.25, 1, 0.5, 1)`.

Deliberately **no blur**: a blur is an offscreen filter pass that stays attached at radius 0 once
the animation finishes, so a few hundred settled words would each keep one. `scaleEffect` is a
transform, costs nothing at identity, and gives the same "focusing in" read.

### The settling tail — a recency cue, not a volatility claim

The source spec calls the dim tail "ghost text", meaning *the model may still revise these words*.
For whisper.cpp that is literally true: the tiny preview model's tail is replaced by the main model
at chunk handoff. **For Nemotron it is false** — no word is ever retracted. A hard grey/black cliff
would assert something untrue on the backend most users are on, and this repo already records what
that looks like: `MeetingLiveTranscriptView` dropped its dimmed tail because it read as a rendering
fault rather than as "this may change".

So the tail is graded, not binary — opacity ramps 0.50 → 0.90 over the last four words, a trail
behind the caret rather than a boundary — and it resolves fully to ink whenever streaming stops
(1.5s after the last *poured* word, not the last arrival, so the settle tracks what the user saw).
It says "these just landed", which is true of every backend.

Settle is a **colour** change only. Italicising or re-weighting the tail would change its metrics,
so every word would re-measure on settling — exactly the layout shift the design avoids.

### Bounded view count

`DictationFlowLayout` measures every subview on every pass, and a pass runs on each word append —
unbounded views make append O(n) and the recording O(n²). A 5-minute dictation is ~700 words, which
would stutter the HUD. Only the last **200** words are rendered as individual views; the card shows
~12 lines at its 340pt maximum, so that is several screens of scrollback at fixed cost.
`displayedText` keeps the full transcript for accessibility, and the inserted text comes from the
transcriber, never from anything on screen.

`ForEach` is keyed on the word's **absolute** index. With positional identity, every survivor would
re-appear — and re-run its entrance — each time the window dropped its oldest word.

## 3. The caret — `KineticCaret`

A 2×17pt gradient bar (`#5B6CF7` → `#8B5CF6`) that is the last subview in the flow layout, so
placing it is the layout's job and it inherits the wrap. Animating the *layout* on `words.count`
(140ms, same curve) is what makes it glide to its new x instead of teleporting — the word appears
to pour out from behind it.

| State | Treatment |
|---|---|
| Streaming | Solid, full-height, `shadow(blueAccent 0.55, radius 4)` |
| Paused | Breathing pulse — opacity 0.2↔0.9 and scaleY 0.86↔1.0, 1.05s ease-in-out, `repeatForever` |

The pulse is the only thing on screen still saying "listening" during a pause. The bloom is one
filter for the whole card — the one place a glow is affordable, and what makes the caret read as a
light source the words emerge from rather than as a rectangle.

`repeatForever` must be explicitly cancelled when streaming resumes; otherwise it keeps running and
re-asserts itself the moment the opacity ternary flips back.

## 4. LTR / RTL split

| | LTR | RTL |
|---|---|---|
| Renderer | `DictationStreamView` (SwiftUI, per-word) | `TranscriptionTextView` (`NSTextField`) |
| Caret | `KineticCaret` view | blinking `" |"` string |
| Reveal | word-by-word pour | immediate |

RTL keeps the `NSTextField` because it is the only thing that can set
`NSParagraphStyle.baseWritingDirection` — six SwiftUI approaches were tested and failed
(ARCHITECTURE.md) — and because the word-reveal animation is deliberately skipped for RTL anyway:
revealing logical word order moves the insertion edge unpredictably.

The 530ms cursor timer now runs **only** in RTL. In LTR it would re-evaluate the card body — and
re-measure every word in the flow layout — twice a second to flip a flag nothing on that path
reads.

## What this does not do

- **No engine changes.** `NemotronBridge.chunkMs` stays at 1120. Shortening it would genuinely cut
  latency, but its accuracy cost is unmeasured and the encoder cost is per chunk.
- **No word-level timestamps.** FluidAudio exposes `getTokenTimings()` / `finishWithTokenTimings()`,
  which would let each word be placed at its true offset instead of estimated from the batch. Using
  them means widening `NemotronBridging`, `TranscriptChunk`, and the callback chain — a larger
  change than this, and the estimate is within a word of the truth at conversational rates.
- **No sub-200ms latency.** The source spec's 150–200ms target assumes 20–30ms micro-chunking. With
  a 1120ms chunker the honest goal is *continuity*, not absolute latency: the user should never see
  the stream stop, which this achieves, rather than see each word within 200ms of saying it, which
  it cannot.
