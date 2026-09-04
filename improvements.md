# Whisperer: Verified Improvement Roadmap

**Prepared:** 2026-09-04  
**Method:** 8 parallel source-code audits, each verifying proposals against actual Swift files with file:line citations. All verdicts below are evidence-based. Line numbers are approximate landmarks — use symbol names for navigation; files change.

---

## Audit corrections to the original document

All 15 P0/P1 findings were confirmed as factually accurate. Four corrections to framing:

| Correction | Detail |
|---|---|
| P0 #4 and #5 (rewrite, insertion) are lower priority | Both are entirely inside `#if !APP_STORE`; they affect only the Developer ID / direct-download build, not the App Store binary |
| P1 #10 "don't run ensemble on every utterance" moot | There is no ensemble today. The real gap is that WhisperBridge already extracts token-level evidence internally but doesn't expose it through the protocol |
| P2 entity name | The entity is `TranscriptionEntity`, not `DictationEntity`. Renaming triggers a heavyweight migration — do not rename |
| P2 is not a prerequisite for P1 | Targeted additions to existing large files can land P1 features without a seam refactor first. Do a bounded architectural prep instead |

---

## Phase A — Trust foundation (P0)

### A1. MCP security hardening

**Source truth:**
- `mcpEnabled: Bool = true` (AppState.swift:682); no `#if APP_STORE` guard on launch (WhispererApp.swift:218-220) — runs in all three build configs
- `NWListener` is created with `NWParameters(tls: nil, tcp: tcpOptions)` (WhispererMCPServer.swift:44) — no TLS, no interface restriction → binds `0.0.0.0`
- `OriginValidator.disabled` (WhispererMCPServer.swift:131) — any HTTP client can call the server
- `get_transcription` returns full transcript + AI output + notes to any connecting client (MCPTranscriptionTools.swift:150-167)
- Bonjour is already `#if !APP_STORE` (WhispererMCPServer.swift:60-67) — only gap in the App Store build

**Three-item minimal fix (drop the rest as over-engineering for a local developer tool):**

1. **Re-enable Origin validation** — change `OriginValidator.disabled` to the default validator at WhispererMCPServer.swift:131. XS effort, zero regression for well-behaved clients (Claude Desktop, Cursor send correct Origin headers).

2. **Add `mcpLANEnabled` toggle** — when off, set `params.requiredInterfaceType = .loopback` before NWListener creation. Default for new installs and updates: loopback-only. Existing local clients continue to work unchanged. Show the `.local` hostname and LAN URL in the UI only when LAN mode is explicitly on. Files: AppState.swift (add `@Published var mcpLANEnabled`), WhispererMCPServer.swift (conditional binding), menu bar UI (move LAN URL display behind the toggle).

3. **Default MCP off for new installs only** — gate the hardcoded `true` default on `UserDefaults.standard.object(forKey: "mcpEnabled") == nil`. Existing users keep their setting unchanged.

**Drop as over-engineering:** TLS (high implementation cost, low actual risk for local HTTP behind macOS firewall), Keychain-backed pairing tokens with per-client revocation (breaks every existing Claude Desktop/Cursor config without any setup ceremony), per-tool scopes, access log, date/redaction limits.

**Acceptance gates:** Unauthenticated process from another host cannot connect by default; existing local MCP clients continue working; LAN exposure requires explicit opt-in; disabling MCP tears down the listener immediately; the App Store binary is unaffected.

---

### A2. Persistence correctness

**Source truth:**
- `saveTranscription` and `finalizeSession` are declared `async throws` but `context.save()` runs inside `context.perform { do { try context.save() } catch { Logger.error(...) } }` — the outer function cannot propagate the error (HistoryManager.swift:121-123, 182-186)
- Same swallow pattern in `DictionaryManager.addEntry` (DictionaryManager.swift:391-395)
- `CorrectionLearningService.promote()` calls `addEntry`, receives a non-throwing return, then fires `showLearnedEntryToast` on the returned entry regardless of commit status (CorrectionLearningService.swift:134-139) — on next launch the entry is absent
- **Text paste is already decoupled from history save** — `saveRecordingFromTranscriber` runs after `insertText` returns (AppState.swift:4116-4168); propagating errors here cannot abort a paste

**Fix:** Replace `do { try context.save() } catch { Logger.error }` with a rethrowable pattern — capture the error in a local var inside `context.perform`, throw after the closure returns. Gate notifications and toasts on the throw-free path. Mechanical fix: 4 files, ~6 functions.

**Skip:** `HistoryStore` / `DictionaryStore` / `MeetingStore` protocol abstraction. Commit points are already well-defined; a new protocol layer is speculative architecture that adds call-site churn for no behavioral gain.

**Acceptance gates:** Injected Core Data failure reaches the caller; no toast fires on a failed commit; retry is idempotent; paste behavior and latency are unchanged.

---

### A3. Test isolation

**Source truth:**
- `HistoryTestLoader` hard-codes both production db paths and opens them `SQLITE_OPEN_READONLY` — cannot write or delete production rows; absent-safe (returns `[]` and logs a warning when the file doesn't exist)
- The suites using it (`PolishBenchmarkTests`, `PolishCorpusDumpTests`, `MeetingPolishTests`, etc.) are already flagged as opt-in slow suites in CLAUDE.md; a normal scoped test run does not invoke them
- The real write risk is 3 methods in `BugFixRegressionTests / HistoryManagerMergeConflictTests` that call `HistoryManager.shared.beginSession` + `appendChunk` directly, writing to the production CoreData store (BugFixRegressionTests.swift:148, 186, 208) — a crash between write and `discardSession` leaves an orphan `isInProgress=true` row

**Fix:** Give those 3 test methods their own in-memory `NSPersistentContainer`. No production code change; no other test changes needed.

**Skip:** Full `NSPersistentContainer` injection across all managers — L effort with marginal safety gain beyond the 3 culprit methods.

**Acceptance gates:** `xcodebuild test -only-testing:WhispererTests/BugFixRegressionTests` touches zero production Application Support paths; test cleanup is guaranteed even on test host crash.

---

### A4. Selected-text rewrite (Developer ID build only)

**Source truth (all inside `#if !APP_STORE`):**
- `TextSelectionService` is instantiated in `setupComponents()` (WhispererApp.swift:163) but never called — zero callers in the codebase
- `capturedSelectedText` has no write site; it is always `nil` when read (AppState.swift:702, 69, 2464)
- `rewriteSelectedText()` reads `NSPasteboard.general.string(forType: .string)` directly (AppState.swift:3990), not the live selection — so it can transform stale or sensitive clipboard content
- `TextSelectionService.getSelectedText()` already exists and does the right thing: issues Cmd+C, waits for `changeCount` to advance, reads the new pasteboard content, then restores (TextSelectionService.swift:16-51). It just isn't called

**Fix:** Wire `getSelectedText()` into `rewriteSelectedText()`. If it returns nil (empty selection or unchanged changeCount), fall back to the current clipboard read rather than aborting. `ClipboardSnapshot.capture()` / `restore()` already exists in TextInjector and can be reused. ~10 lines of wiring.

**Don't add:** Per-app range replacement via AX write (`kAXValueAttribute`) — silently fails in Chromium-backed fields, which are a large fraction of real destinations.

**Acceptance gates:** `rewriteSelectedText()` reads the live selection before transforming; stale clipboard content is the fallback, not the primary; original clipboard is restored on success, cancel, and failure.

---

### A5. Insertion verification — telemetry first (Developer ID build only)

**Source truth (all inside `#if !APP_STORE`):**
- `enterViaClipboardPaste` always returns `true` after `pasteboard.setString` succeeds — self-documented in its own docstring ("Returns true always; paste is best-effort")
- A silent paste failure (Electron security sandbox, secure text fields, read-only terminals) returns `true`; the Unicode/CGEvent fallback is structurally unreachable
- The correction observer at 400ms post-paste already performs AX field-delta verification and surfaces a `.notVerified` end reason — but this is consumed only by correction learning, not surfaced as telemetry

**Do now — telemetry, not a copy card:**
Promote the existing `.notVerified` observer end reason to a `Logger.event` call (and a counter in `DictationMetricsEntity` once B2 lands). Measure the actual rate of silent failures across destinations.

**Don't add yet — too much regression risk:**
- Full `InsertionOutcome` enum with a "copy card" UI: an AX round-trip on the paste return path adds 50-200ms latency (per CLAUDE.md); a copy card is a perceived-speed regression in the dominant success case
- AX field-delta verification is infeasible as a synchronous pre-return step for Chrome/Electron/Terminal/secure fields — the majority of real destinations return no usable AX value

**Decision gate:** If telemetry shows `.notVerified` rate is >5% across a fleet sample, add the copy card. Until then, the telemetry is the deliverable.

**Acceptance gates:** `.notVerified` events appear in logs / metrics; no latency regression on paste path; no double-injection.

---

### A6. Privacy / storage reconciliation

**Source truth:**

| Claim | Reality |
|---|---|
| Policy: "recordings optionally saved" | AppState.swift:3693 comment: "Audio is always kept now." Audio is saved unconditionally when a dictation produces text. Real misstatement. |
| Policy: "one-time model download" | `PolishModelManager.checkForUpdate()` fetches a manifest from HuggingFace on every launch (PolishModelManager.swift:264-266). Real misstatement. |
| Policy: no mention of MCP | MCP server is on by default, binds all interfaces, no auth. Real omission. |
| AGENTS.md: "5-minute max recording limit" | Zero duration-stop code exists anywhere in AppState, AudioRecorder, or StreamingTranscriber. The claim is stale-false. |

**Doc fixes — do immediately, zero engineering:**
- "optionally saved" → "always saved to your local disk when a dictation produces text"
- Add: "You can configure automatic deletion after 7, 30, 90, or 365 days in Settings → Data Management, or delete manually at any time."
- "one-time model download" → "downloaded on first use. AI enhancement models check for updates in the background."
- Add MCP section: "Whisperer optionally runs a local HTTP server (port 8080, on by default) so AI tools can query your transcription history. No data leaves your Mac. Disable in Settings → MCP."
- Add FileVault note: "App data is protected by macOS FileVault when enabled. No additional application-layer encryption is applied."
- Update AGENTS.md:9 to state no dictation duration cap currently exists.

**Engineering for next release:**
- **Separate audio-only vs. full-record retention** — add `audioOnlyDeleteAfterDays` key to `AudioRetentionService`; add a sweep path that nulls the audio file URL without deleting the CoreData row. S-M.
- **Private dictation mode** — gate `saveRecordingFromTranscriber` with a per-session flag; show a HUD indicator; reset on key release. M.
- **Private-app denylist** — check bundle ID against a user-configured list at `startRecording()`; existing `captureTargetApp()` call already has the bundle ID at that point. M-L.
- **Dictation duration cap with HUD countdown** — start a `Timer` in `startRecording()`; warn at N-30s (HUD badge); call the standard key-release stop path at N so the current audio is transcribed and injected cleanly (nothing lost). Apply **only** to the hold-key dictation path — explicitly not to `MeetingSession`, which runs a completely separate code path. M.

**Drop:** Application-layer encryption on macOS. `NSFileProtection` is a no-op on macOS (iOS-only data protection). Adding Keychain-backed per-record encryption would break Spotlight indexing, require a storage migration, and add maintenance burden with no threat-model benefit when FileVault already encrypts the volume.

**Acceptance gates:** Runtime, settings UI, and PrivacyPolicy.md agree on audio retention; private dictations leave zero history/audio rows; duration cap never fires during meeting recording; MCP disclosure is accurate.

---

## Phase A-prime — Bounded architecture prep

Do after Phase A lands, before adding Phase B/C features. This is NOT the full P2 refactor — it's the subset that reduces friction for new work.

**Source truth:**
- AppState.swift: 4,492 lines; StreamingTranscriber.swift: 4,271 lines; WhispererApp.swift: 4,749 lines
- `StreamingTranscriber` construction is duplicated across two sites in AppState.swift (lines 2949 and 3450) with the same 10+ arguments and 4 shared callbacks (`onLanguageDetected`, `onLanguageForcingUnavailable`, `onChunkCompleted`, `onPreviewTail`, `onStreamingSamples`) repeated verbatim
- 27 concrete type checks (`is WhisperBridge`, `is WhisperKitBridge`) in StreamingTranscriber alone; worst clusters at lines 1386-1447 (abort handling) and 2612-2901 (stopAsync chain)

**What to do:**
1. Extract the two `StreamingTranscriber` construction sites into a shared factory helper in AppState. Consolidate the 4 shared callbacks into the helper. Keep diarization-specific wiring (`onAttributed`, `onPendingTail`, `onLiveSpeaker`) in the meeting-only path.
2. Add protocol methods to `TranscriptionBackend` that correspond to the worst type-check clusters, letting backends implement their own abort and stop behavior instead of requiring the caller to branch on concrete type.

**What NOT to do yet:** Full `DictationSession` type, full `InsertionCoordinator`, `WritingPolicyResolver` type. These are correct directions but L effort and not prerequisites for any specific upcoming feature.

**Do NOT rename** `TranscriptionEntity` to `DictationEntity` — heavyweight migration, no behavior benefit.

**Acceptance gates:** Concrete type-check count in StreamingTranscriber below 10; construction paths consolidated; existing test suite passes without changes; SafeLock and `@MainActor` invariants are unaffected (verify by running `WhisperBridgeTests`, `StreamingTranscriberTests`).

---

## Phase B — Measurement substrate

### B1. TranscriptionEvidence protocol extension (P1 #10)

**Source truth:**
- `TranscriptionBackend.transcribe()` returns only `String` (TranscriptionBackend.swift:103-122)
- WhisperBridge already extracts per-token probability (`whisper_full_get_token_data().p`), word timings (`t0`/`t1`), segment timings, `no_speech_prob`, and `averageLogProbability` internally — packed into `WhisperStreamWord` / `WhisperStreamResult` (WhisperBridge.swift:1388-1447) — but none of this crosses the protocol boundary
- `ASRCapabilities` OptionSet is already used in the polish graph (ConfidenceGate, TokenGraph, PolishFeatureFlags) but wired as a compile-time constant, not returned from a decode call
- 4 real backends need updating: `WhisperBridge`, `WhisperKitBridge`, `SpeechAnalyzerBridge`, `FluidAudioBridge`

**Change:** Add an optional evidence field to the protocol via extension default:

```swift
struct TranscriptionEvidence {
    var words: [WordEvidence]?       // per-word probability + timings
    var avgConfidence: Float?
    var noSpeechProb: Float?
    var languageScores: [LanguageScore]?
    var timings: StageTimings?
}
```

Extension default returns `nil`. `WhisperBridge` and `WhisperKitBridge` fill all fields (data already extracted); `SpeechAnalyzerBridge` and `FluidAudioBridge` return nil at zero cost. No breaking change for any backend.

**What this unlocks:** ConfidenceGate uses real per-word evidence; language detection uses per-decode language scores; D1 (confidence-triggered alternate decode) becomes possible.

**Acceptance gates:** All 4 backends build cleanly; absence of evidence never relaxes a safety gate; WhisperBridge fills all fields; a frozen low-confidence corpus triggers the ConfidenceGate path.

---

### B2. DictationMetrics entity (P1 #13)

**Source truth:**
- `TranscriptionEntity` has 21 attributes, none for stage timings, bundle ID, route evidence, formatter divergence, injection outcome, or observer result (TranscriptionEntity.swift, confirmed from xcdatamodel XML)
- No latency data is stored or logged transiently anywhere in the codebase
- `HistoryDatabase` uses `shouldMigrateStoreAutomatically = true` with inferred mapping — adding a new optional entity is a safe lightweight migration
- CoreData writes in the current code happen on `viewContext` (main thread); adding a metrics write must use a background context

**Change:** Add a new `DictationMetricsEntity` (1:1 optional relationship to `TranscriptionEntity`, created on a background context after paste completes):

```
asrMs, polishMs, injectMs, e2eMs          Int32
backendID, modelManifestHash,              String
  pipelineConfigVersion, appBuildVersion
avgConfidence, noSpeechProb               Float
fallbackReason, insertionOutcome,          Int16 (enum raw values)
  observerEndReason
formatterDivergence, editCount            Int16
thermalState, deviceClass, languageRoute  Int16 (enum raw values)
```

A separate entity (not new columns on `TranscriptionEntity`) keeps main entity fetch paths fast and makes private mode trivial: in private mode, don't create the metrics row at all — no additional logic needed.

**Acceptance gates:** Private mode writes zero metrics rows; all fields are numbers/hashes with no transcript body; metrics write adds <5ms to end-to-end path measured on a warm device; every release can be compared by model/config/device cohort.

---

### B3. Correction observer determinism (P1 #11 partial)

**Source truth:** `CorrectionObservationTests.swift:8-10` self-documents: "The polling loop itself is deliberately not tested (it requires a live AX target and real Task.sleep, which would be slow and flaky)." The observer runs real `Task.sleep` with no injectable clock. The poll schedule array shape is tested statically; execution timing is not.

**Change:** Extract the observer state machine into `CorrectionObserverStateMachine` with injected `Clock` and `AXSnapshotProvider` protocols. The production implementation uses real `Task.sleep` and `AXTextFieldSnapshotReader`; tests inject a deterministic clock and a mock AX snapshot sequence. Move the `correctionPollSchedule` array into the state machine.

This is a prerequisite for C5 (phrase correction extraction) and for asserting any correctness property of the observer lifecycle.

---

### B4. Non-Latin promotion guard (P1 #11 partial)

**Source truth:** `CorrectionPromotion.evaluate()` (CorrectionPromotion.swift:82-101) gates on script-family match, then applies `SpellValidator.isValidEnglishWord` (NSSpellChecker, returns `false` vacuously for non-Latin scripts) and a custom ASCII-biased Soundex (PhoneticMatcher.swift). A Cyrillic→Cyrillic pair can reach `.automatic` via the vacuous English gate + accidentally matching Soundex. The current code promotes silently — there is no "uncalibrated = suggestion" fallback for unmatched language policies.

**Change:** Add one guard before the English/Soundex gates:

```swift
guard scriptFamilies(in: observed).contains("latin") else {
    return .suggestion // non-Latin: requires calibrated phonetic policy to auto-promote
}
```

Zero impact on existing Latin promotion behavior. Non-Latin corrections become suggestions (user sees and confirms) rather than silent auto-promotes until calibrated per-language policies exist.

**Acceptance gates:** Zero automatic non-Latin promotions; existing Latin promotion precision unchanged; undo and tombstone work for the suggestion tier.

---

## Phase C — User-visible differentiation

### C1. Spoken edit commands (P1 #12)

**Source truth:** Zero structured command parsing exists. `SentenceTerminator` inserts only `.` by self-documentation. AI modes are pure LLM prompts (AIMode.swift:175-220). No detection of "scratch that", "new line", "literal mode", or any other dictation command anywhere in the codebase.

**Change:** Pre-LLM command parser that pattern-matches a closed whitelist of whole-utterance commands before the polish graph:

| Utterance (whole utterance only) | Action |
|---|---|
| "scratch that" / "undo that" | Emit undo event; insert no text |
| "new line" | Insert `\n` |
| "new paragraph" | Insert `\n\n` |
| "period" / "comma" / "exclamation point" / "question mark" | Insert explicit punctuation |
| "open quote" / "close quote" | Insert `"` / `"` |
| "open paren" / "close paren" | Insert `(` / `)` |

Whole-utterance-only match prevents false triggers mid-sentence. Unrecognized utterances fall through unchanged. Multilingual commands need a separate localized whitelist — do not extend English list for non-English; leave unimplemented for v1.

**Don't build yet:** Select/replace dictated spans (requires AX write, fragile on Chromium). Code symbol / identifier commands (depends on WritingContext landing first).

**Acceptance gates:** Recognized commands never appear in final text; unrecognized utterances are byte-for-byte unchanged; "scratch that" is undoable; "literal mode: new line" inserts the text "new line" verbatim.

---

### C2. App writing policy engine (P1 #8)

**Source truth:** `AppStyleProfile` defines `messaging`, `code`, `prose`, `unknown`. `.code` and `.prose` produce zero behavioral difference from `.unknown` today — confirmed by tracing all callsites. Only `.messaging` changes output (trailing period suppression, utterance termination). Classification from bundle ID is already correct and captured at the right moment.

**Change:** Add `AppWritingPolicy` struct resolved from `AppStyleProfile` + explicit user override:

```swift
struct AppWritingPolicy {
    var cleanupLevel: CleanupLevel        // verbatim, light, standard, concise
    var finalPeriodBehavior: FinalPeriodBehavior
    var paragraphStyle: ParagraphStyle    // none, auto, markdown
    var fillerHandling: FillerHandling
    var codeProtection: Bool
    var preferredAIMode: AIMode?
    var trailingSpace: Bool
}
```

Default mappings:
- `unknown` → `verbatim` cleanup, current behavior (safe for existing users — no change)
- `messaging` → light cleanup, no final period (current behavior preserved)
- `code` → verbatim + codeProtection (no capitalization, no final period)
- `prose` → standard cleanup, auto-period

Explicit user overrides per bundle ID outrank inferred defaults. The `verbatim` mapping for `unknown` means no existing user sees different output unless they explicitly configure an override.

**Acceptance gates:** Same utterance produces different output in a terminal vs. chat vs. document editor; the difference is visible in the history diff view; overrides round-trip through Settings; `unknown` apps produce identical output to today.

---

### C3. Ephemeral WritingContext (P1 #7)

**Source truth:** Bundle ID and style class are captured at recording start (AppState.swift:3392-3397) — correct behavior. No caret-adjacent text, field role, or document title is captured. The prompt injection experiment already ran twice and failed:
- Run 1 (naive miner): +0.0423 WER, 7 leaks, 1 better / 26 worse
- Run 2 (fixed miner): +0.0142 WER, 1 leak, 4 better / 12 worse

Do not attempt prompt injection again without clearing the existing experiment gates in `docs/knowledge/transcription/knowledge.md`.

**Change:** Capture an ephemeral `WritingContext` at recording start alongside the existing `captureTargetApp()` call:

```swift
struct WritingContext {
    var bundleID: String?
    var fieldRole: AXFieldRole?        // textField, webArea, terminal, secure, unknown
    var documentTitle: String?         // safe title only, no body content
    var sensitivity: SensitivityClass  // normal, secure, privateApp
}
```

Capture `fieldRole` from `kAXRoleAttribute` (fast single AX call) and `sensitivity` from `kAXIsProtected` + private-app denylist. Sensitive/private-app contexts get a restricted policy; nothing is logged.

**Do NOT capture** caret-adjacent text or field content — this is the failed prompt injection path.

**Use context only for:**
- App profile / policy selection (already done via bundle ID; `fieldRole` refines it)
- Punctuation and paragraph policy per `AppWritingPolicy` (C2)
- Code-token protection flag
- AI mode default

**Never persist** `WritingContext`. It is ephemeral to the recording session.

**Acceptance gates:** Zero context in history/logs; `kAXIsProtected` fields receive verbatim policy; context cannot alter protected spans; a new recording in a different app class produces a different policy without any user action; sensitive-field detection gates the AX read (password manager fields never have content captured).

---

### C4. Exact snippets (P1 #9)

**Source truth:** `DictionaryEntry` has no `kind`, `trigger`, or `expansion` fields — confirmed from the struct definition. The Wispr importer intentionally skips snippet-style rows ("Snippets … importing them would silently rewrite dictation" — WisprDictionaryImporter.swift:15-23). Adding optional columns to `DictionaryEntryEntity` is a safe lightweight migration under the current inferred-migration settings.

**Change:**
1. Add `DictionaryEntryKind` enum: `.vocabulary`, `.correction`, `.snippet`
2. Add optional columns to `DictionaryEntryEntity`: `kind` (Int16), `trigger` (String?), `expansion` (String?), `wholeUtteranceOnly` (Bool, default true), `appScopeBundleID` (String?), `locale` (String?)
3. Add uniqueness constraint on `normalizedKey` and a fetch index on `kind`
4. Evaluate snippets as exact whole-utterance matches **before** any punctuation normalization or polish step. Exclude snippet entries from all fuzzy correction indexes (gate on `kind == .snippet`)

Whole-utterance-only is the correct default tradeoff: partial-phrase false triggers ("btw" expanding mid-sentence) are worse than the restriction.

**Acceptance gates:** Partial phrases never expand; exact trigger matches correctly even with trailing comma; collisions are surfaced to the user; app-scoped snippets don't expand in other apps; undo works; the migration preserves all existing dictionary entries.

---

### C5. Correction Learning 2.0 — phrase corrections (P1 #11 remainder)

**Source truth:** The extractor self-documents at CorrectionLearning.swift:43: "Returns only isolated 1:1 word substitutions. Insertions, deletions and phrase rewrites are intentionally absent." Only `removed==1, inserted==1` pairs are extracted — "New York" → "Newark" (2→1) is silently ignored.

**Prerequisite:** B3 (deterministic state machine) must be in place before extending the extractor.

**Change:** Extend the extractor to handle 1:2 and 2:1 word swaps. Auto-promote phrase corrections only above a calibrated precision gate (minimum 5 observations, precision ≥ 0.9 on a validation corpus). Sub-threshold become suggestions. Locale/language from `lastDetectedLanguage` (already live in AppState) feeds every observation.

**Acceptance gates:** Phrase corrections are detected and tracked; false-promotion precision is certified with a stated lower-confidence bound; undo and tombstone are transactional.

---

## Phase D — Adaptive quality (locked behind measurement gates)

### D1. Confidence-triggered alternate decoding

**Prerequisite:** B1 (TranscriptionEvidence in protocol) AND a frozen baseline corpus from DictationMetrics (B2) showing the distribution of `avgConfidence` in practice.

When `avgConfidence` falls below a threshold calibrated from real user data, trigger a narrow re-decode of the low-confidence segment with a different decoding strategy (greedy vs. beam, or reduced `audio_ctx`). Do NOT run full second-model inference on every utterance.

**Gate:** This path cannot ship without (a) a frozen corpus showing the re-decode improves more fixtures than it harms, and (b) a latency measurement showing it stays within the acceptable window measured via DictationMetrics.

---

### D2. Local shadow evaluation

**Prerequisite:** B2 (DictationMetrics).

An opt-in background runner compares candidate ASR or formatter configurations against the current production configuration on locally retained recordings. Runs during idle periods on a background thread. Persists scores only when the user's retention policy allows. Never blocks or delays the paste path.

---

### D3. ASR prompt experiment — permanently locked

This path is locked behind the experiment gate documented in `docs/knowledge/transcription/knowledge.md`. The experiment ran twice and failed both times. Do not reopen without:
1. A pre-registered corpus with stated success/failure criteria
2. A WER gate passing on held-out recordings (not just training data)
3. A latency gate passing on the target device class

---

## Data model changes (concrete and pruned)

### New entity: `DictationMetricsEntity`

1:1 optional relationship to `TranscriptionEntity`. All attributes optional numerics or hashes — no text blobs. Write on background context after paste completes.

Attributes: `asrMs`, `polishMs`, `injectMs`, `e2eMs` (Int32); `backendID`, `modelManifestHash`, `pipelineConfigVersion`, `appBuildVersion` (String); `avgConfidence`, `noSpeechProb` (Float); `fallbackReason`, `insertionOutcome`, `observerEndReason`, `formatterDivergence`, `editCount`, `thermalState`, `deviceClass`, `languageRoute` (Int16 enum raw values).

Lightweight migration: new entity with all optional attributes — safe with inferred mapping.

---

### `DictionaryEntryEntity` additions

Optional columns (lightweight migration — all optional): `kind` (Int16), `trigger` (String?), `expansion` (String?), `wholeUtteranceOnly` (Bool), `appScopeBundleID` (String?), `locale` (String?).

Add uniqueness constraint on `normalizedKey`. Add fetch indexes on `kind` and `normalizedKey`.

---

### Meeting storage — incremental fixes (avoid heavyweight migration)

**Do NOT** split `segmentsJSON` into a normalized entity yet. That requires a heavyweight migration with a custom mapping model — high risk of destroying existing meeting data on upgrade.

Instead, three incremental improvements that are lightweight-migration-safe:

1. **In-memory segment cache in MeetingManager** — decode `segmentsJSON` once on first access, append to the in-memory array, write back to the JSON only at chunk boundaries and on stop. Eliminates O(n) decode-on-every-append. S effort.

2. **`MeetingProcessingJobEntity`** — new optional CoreData entity (lightweight migration) replacing the sidecar JSON files: `meetingID` (String, unique), `stage`, `status`, `attempts`, `errorCode`, `updatedAt`. Eliminates the silent compactMap-out of failed JSON decodes. M effort.

3. **Fetch indexes** — add indexes on `TranscriptionEntity.timestamp` and `TranscriptionEntity.isInProgress` (common query patterns, zero migration risk).

---

### Model manifests — additive

Bundle `WhisperModelManifest.json` in app resources (or fetch alongside model from HuggingFace) with: `sha256`, `upstream_revision`, `backend`, `quantization`, `license`, `byteCount`. Validate SHA-256 at install time against the manifest. On first load, compare self-computed hash against manifest hash if present — do not accept a tampered first-download. S effort.

---

## Anti-requirements

These are confirmed by the audit and are non-negotiable:

- No global key tap or key-content capture.
- No raw AX / window context body persisted by default.
- No cloud dependency in the core dictation path.
- No `initial_prompt` injection from history / app vocabulary — the experiment failed twice; locked behind gate.
- No full multi-engine ensemble on every utterance without a measured confidence gate and corpus validation.
- No UI success state before the underlying commit / insertion is known to be committed.
- No application-layer encryption on macOS — `NSFileProtection` is a no-op on macOS; FileVault covers the volume.
- No `TranscriptionEntity` → `DictationEntity` rename — heavyweight migration, zero behavior benefit.

---

## Delivery sequence

| Phase | Prerequisite | Effort |
|---|---|---|
| **A1–A6 (P0 trust)** | — | A1: S; A2: S; A3: S; A4: S; A5: XS; A6-docs: XS; A6-eng: M |
| **A-prime (architecture prep)** | A complete | M |
| **B1 (evidence protocol)** | A-prime | M |
| **B2 (metrics entity)** | A | M |
| **B3 (observer determinism)** | A2 | M |
| **B4 (non-Latin guard)** | — | S |
| **C1 (spoken commands)** | — | S |
| **C2 (app policy engine)** | A-prime | M |
| **C3 (WritingContext)** | C2 | M |
| **C4 (snippets)** | — | S–M |
| **C5 (phrase corrections)** | B3 | M |
| **D1 (confidence decode)** | B1 + B2 data | M |
| **D2 (shadow eval)** | B2 | M |
| **D3 (ASR prompt)** | Corpus + gate | locked |

**Do now, zero engineering:** A6 doc fixes (PrivacyPolicy.md, AGENTS.md), B4 (3-line guard in CorrectionPromotion).

---

## Metrics that confirm progress

- **Trust:** Zero unauthenticated remote history access by default; zero production DB touched by normal test runs; privacy-mode metrics rows contain no transcript bodies.
- **Reliability:** All Core Data commit failures surface to callers; silent loss rate trends to zero; crash-replay of meeting jobs is idempotent.
- **Quality:** Non-Latin auto-promotion rate is zero before calibrated policies exist; correction false-promotion precision is certified per language; alternate decode (D1) improves more frozen fixtures than it harms.
- **Latency:** Measure warm key-up→raw, key-up→final, ASR, polish, injection, and queue time by device/model/language (B2) before setting numeric targets; no shadow or context task extends the critical path.
- **Personalization:** Per-app policy differences are observable in history diffs; learned corrections have verified reuse and undo rates.
