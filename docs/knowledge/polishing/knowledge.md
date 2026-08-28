# Polishing — Knowledge

The deterministic transcript editor (`Whisperer/Transcription/Graph/`) and the gated generative
pass over it (`Whisperer/Transcription/Editing/`): protect → alias → normalize → format, every
edit judged individually, nothing generated without a diff behind it.

## A guarantee that depends on ASR evidence is a guarantee on one engine

Only whisper.cpp and WhisperKit expose per-word evidence. Nemotron, FluidAudio and
SpeechAnalyzer expose none — the shared `TranscriptionBackend` protocol carries only `String`,
and Nemotron does not even sit behind that protocol: it is fed samples and returns one `String`
for the whole session. **Meetings run on Nemotron**, so "no evidence" is not an edge case, it is
half the product.

`ASRCapabilities` makes the dependency explicit rather than implicit, and the contract is
stated on the type: *every gate must define its behaviour at `[]`, and that behaviour is the
conservative one — KEEP.* Absent evidence never loosens a threshold; it only removes an *extra*
reason to edit. A token with no `asrProbability` is judged by the text thresholds alone and can
never be edited on weaker grounds than a token that has one.

That is a claim about code, so it is tested as one. `PolishBenchmarkTests`
`testQualityIsIdenticalAtZeroCapability` polishes all 400 fixtures twice — once through
`from(words:)` carrying full whisper.cpp evidence, once through `from(text:)` carrying none —
and asserts **0 divergences**. The synthetic evidence is deliberately hostile: probabilities
alternate 0.02 / 0.98 word by word, so a gate that read them would diverge on nearly every
fixture rather than subtly. `ConfidenceGateTests.testVerdictsAreIdenticalWithAndWithoutEvidence`
asserts the same property one level down.

The seam for evidence that *does* pay is `ConfidenceGate.requireAcousticSupport`, defaulted off.
Turning it on is a per-engine feature by construction, not a silent regression on Nemotron.

Also load-bearing for this: `from(text:)` defaults to `ASRCapabilities = []`, so forgetting to
declare evidence degrades to conservative behaviour rather than to a wrong assumption.

## Filler removal must never empty an utterance

Found by the meeting suite against real data, not by reading the code: segment 72 of meeting
`EFF8E485…` is the single word `כאילו`, and filler removal deleted it — replacing a timestamped,
playable transcript row with the empty string.

Two reasons that is the wrong answer rather than an edge case:

- **A segment is addressable.** It has a timestamp, a speaker and an audio span the UI plays, so
  emptying one deletes a row rather than tidying it.
- **A discourse marker alone is the turn.** `כאילו` or `so` between other words is noise; as the
  whole utterance it is an answer to a question, and the utterance carries no context to decide
  otherwise.

`TranscriptNormalizer.fillerEdits` therefore collects deletions by *target* and returns `[]`
when `doomed.count == words.count`. Counted by target rather than by edit because a phrase match
emits one deletion per word, so comparing `edits.count` to `words.count` would start
over-counting the moment a token could be targeted twice.

Precision over recall is the general shape here: leaving a filler in is annoying, deleting the
user's only word is data loss.

## A token-level diff is what makes a generative model gateable

`LLMPostProcessor` returns prose, and the only decision a caller can make about prose is
accept-all or reject-all — which is why `TranscriptPostValidator` threw away thirty-nine good
corrections to stop one bad one. `TranscriptDiff` aligns the model's rewrite back against the
token graph it was produced from, turning one irreversible decision into forty reversible ones,
each judged by `ConfidenceGate` on its own. The partial outcome — the model's text everywhere
the gate agreed, the original text on a hard-protected span or a refused edit — is the feature.

**Why a real alignment rather than changed character ranges.** Hebrew, Russian and English mix
inside one utterance, and there UTF-16 offsets, grapheme counts and visual order all disagree
silently. Token alignment has none of those failure modes: the unit of comparison is a whole
token; Swift string equality is canonical-equivalence based, so differently-composed niqqud or a
Cyrillic breve compares equal instead of showing up as an edit; and the result is addressed by
`TokenID`, which survives every insertion and deletion around it.

**Byte-exactness comes from the tokenizer, not from a test.** The revised text is tokenized by
`TokenGraph`'s own tokenizer and whitespace is a first-class token kind, so `render()` is a plain
concatenation and applying every emitted edit reproduces the model's output character for
character wherever the graph permits it. The same property is what let M1 verify the graph was
inert: `render()` is byte-identical to its input across all 400 golden transcripts and all 400
real history transcripts, on both builders.

**An empty rewrite is a failed model, not a decision.** A model returning no letters for an
input that had them would diff to one deletion per token — the literal diff and the worst
possible outcome — so that case is refused before alignment runs, and logged.

## Wispr Flow edit distribution (1,639 en pairs, 60,878 words, measured 2026-08-27)

From `~/wispr_corpus/corpus.jsonl` — Wispr's production cloud polisher against the user's own dictation:

| edit class | volume | fraction |
|---|---|---|
| trailing punctuation | large | ~30% of words changed |
| casing | large | ~15% of words changed |
| filler / disfluency deletion | 2,064 word deletions | `like` 910, `so` 280, `and` 259, `basically` 231 |
| **function-word insertion** | 1,521 inserts | 94% single-word; `the` 444, `a` 295, `is` 112, `are` 81, `an` 78 |
| **1:1 word replacement** | 982 | 41% share a prefix (`ask→asked`, `need→needs`, `we→we're`) |
| **merge / split** | 299 compound merges + 146 splits | `drop down→dropdown`, `up check→upcheck` |
| **paragraph breaks** | 103 outputs with newlines | 33% of outputs ≥60 words are split |
| **list structure** | 50 pairs | VS Code / Claude desktop / Chrome destinations |

Destination effect — edit rate by app:
- VS Code: 0.163 edits/word, 8% paragraph break rate
- Cursor: 0.096 edits/word, 3% paragraph break rate  
- Chrome: 0.159 edits/word, 5% paragraph break rate
- Claude desktop: 0.109 edits/word, **18%** paragraph break rate
- Slack: 0.124 edits/word, 8% paragraph break rate

**1.7× spread in edit rate, 6× spread in paragraph rate across destinations** — the polisher is context-conditioned, not a pure function of the transcript.

Insert vocabulary coverage (K=top-K words): K=50 → 92.4%, K=98 → ~96%, K=200 → 100%.

## mmBERT Wispr retrain (2026-08-27): first calibration of 8-head model

Run 4 of the model. Extended from 4 to 8 heads (append/repl/merge/para + destination conditioning). First time new heads were calibrated. No cells certified, which is expected at this data volume.

Key findings:
- **Append head is active**: making proposals (n=63-82 for `the`) but low precision (0.13-0.28). Model identifies when to insert but not which word. Needs more data or higher append loss weight.
- **Merge MERGE_SPACE at P=1.00, n=10**: perfect precision, too few examples (needs 300). Will certify as Wispr corpus accumulates.
- **Repl CONTRACT at P=0.81, n=16**: approaching useful. Needs more contraction examples.
- **Para head makes zero proposals**: either too conservative or label sparsity in training. Needs investigation.
- **Old heads worse than run 2b** (punct `.` P=0.582 vs 0.919): expected — adding 4 new heads creates more loss competition. Needs higher weights or more epochs for the old heads.

The Wispr corpus (1,169 train pairs) is the first real dictation→formatted target data the model has trained on. All prior runs used synthetic Wikipedia corruption.

## Measured rates over 400 real transcripts (18,099 words)

Kept together because each of these is the answer to "is this pass doing anything, and is it
doing too much":

| Pass | Rate |
|---|---|
| Protection — hard | 1.5% of words |
| Protection — soft | 0.1% of words |
| Alias substitutions | 7 edits |
| Filler / duplicate removal | 53 words (0.29%), across 30 of 400 fixtures |
| `ListFormatter` reformats | 8 of 400, unchanged after adding he/ru marker tables |
| Clear `needsGenerativePass` outright | 131 of 400 |

The last row is the one with a product consequence: it replaced
`AppState.applyLLMPostProcessing`'s `text.count <= 15` short-circuit with a content predicate,
dropping the dictation LLM invocation rate to ~67% on this corpus before any model work. Length
was never the right question — a 200-character sentence that already reads as finished prose
gained nothing from a 4B decode, and a 12-character fragment that needed punctuation was skipped
for being short.
