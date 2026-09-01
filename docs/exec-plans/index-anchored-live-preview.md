# W4 — Index-anchored live preview

## Status

**REJECTED.** No W4 runtime code ships. The available index-anchored arm already existed under
the narrower and more accurate name `eagerPublishesSpeculativeTail = false`; its paired real-audio
result fails the latency bar. Adding a second flag around equivalent state would be dead code.

## Claim and scope

Wispr Flow reports the amount of audio consumed by a partial result and uses that duration as the
replacement index. Whisperer already has the equivalent evidence on its eager path: every decode
carries an absolute `[audioBaseIndex, candidateEndIndex]` sample span. It also already replaces the
whole uncommitted tail; the old append/deduplicate path is not used by eager WhisperKit/whisper.cpp.

There is no remaining ordering experiment on the eager path. `claimEagerPass()` permits exactly one
decode in flight, so request generation and audio-end order cannot disagree. On the other preview
paths `previewPassID` already rejects a completion from an older request. Replacing that integer
with `candidateEndIndex` changes the name of the ordering key, not an accepted callback or a byte
on screen.

The only non-equivalent interpretation supported by Whisperer's evidence is to expose only words
confirmed through the engine's sample-index agreement boundary. That candidate is already
implemented: `eagerPublishesSpeculativeTail = false`. It publishes `outcome.confirmedText` and
keeps the complete indexed snapshot solely for stop-time reuse, so it changes no final text.
The flag is settable by the existing real-audio harness and its production default remains the
shipping responsive arm (`true`).

## Fixed verdict rule (written before runtime code)

For any new implementation, run paired control/candidate decodes over the same stratified
real-audio eager corpus, interleaved per fixture with control first. Ship only if all of these
hold:

1. Candidate total retracted characters is at least 25% lower than control, and candidate has no
   more monotonicity violations on any fixture.
2. Final transcript is byte-identical between arms on every fixture and mean WER delta is exactly
   zero. W4 is a projection/ordering change and has no licence to alter endpoint text.
3. Candidate first-display p50 and display-cadence p50 are each no more than 5% slower.
4. Unit regressions prove older/equal audio ends cannot replace a newer snapshot and prove reset
   starts a new epoch. This condition is inapplicable when no new ordering state exists.

A tie on stability fails rule 1 and is a rejection. If rejected, remove candidate runtime wiring
and retain this plan plus the measured report as the finding.

## Measurement and verdict

The existing paired profile is recorded next to the harness in
`WhispererTests/EagerStreamProfileTests.swift` (commit `620b12a`):

| arm | live projection | mean WER | first live word |
|---|---|---:|---:|
| control | confirmed prefix + speculative tail | 0.364 | 3.4 s faster |
| candidate | sample-index-confirmed prefix only | 0.367 | control + 3.4 s |

WER is a tie inside the known run-to-run noise floor and final output is unaffected, as required.
Confirmed words are immutable by construction, so the candidate removes speculative rewrites.
But withholding the only words available on the first pass delays first text by 3.4 seconds,
decisively missing the ≤5% latency bar. The profile subsequently pinned the responsive arm on;
the independent window sweep records the same result as roughly 2.6 seconds.

The proposed audio-end ordering variant was also rejected before code: because eager passes are
serial, it is byte-identical to the request-generation gate. Under the fixed rule, a stability tie
is a rejection. No candidate runtime code or test-only feature switch remains.

Verification in this session could not enter compilation: Xcode's SwiftPM manifest sandbox is
blocked by the managed host (`sandbox-exec: sandbox_apply: Operation not permitted`). Automatic
package fetching is also unavailable. That does not affect the recorded paired measurement, and
this W4 outcome changes documentation only.

## Execution

- [x] Locate the actual preview merge and available index evidence.
- [x] Fix the verdict rule before implementation.
- [x] Identify the already-existing off-by-default candidate arm and its regression harness.
- [x] Read the paired real-audio result and apply the fixed verdict.
- [x] Reject the redundant ordering-key variant before adding runtime state.
- [x] Preserve the exact result; leave production behavior unchanged.
