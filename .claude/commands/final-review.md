# Final Review — Whisperer Multi-Agent PR Review

Twelve specialist agents run in parallel via the Agent tool, each writing findings to disk. Agents read their full instructions from `.claude/review-agents/agent-NN-*.md`, which embed every real historical bug as a specific check pattern. The system is self-improving: every fixed P0/P1 writes a new rule to `docs/knowledge/`, which future runs automatically check.

**Constraint priority (every agent):** Correctness → UX latency → Throughput → Developer velocity.

---

## Step 0 — Preflight (orchestrator runs inline)

```bash
mkdir -p .claude/review-state/findings

# Write diff and changed files
BASE=$(git merge-base HEAD main 2>/dev/null || git rev-parse HEAD~3)
git diff "$BASE"..HEAD > .claude/review-state/diff.patch
git diff "$BASE"..HEAD --name-only > .claude/review-state/changed-files.txt

# Pass detection
PASS=$(git log --oneline "$BASE"..HEAD | grep -c "final-review" || echo 0)
echo "Pass #$((PASS + 1))"

# Determine buckets
cat .claude/review-state/changed-files.txt | awk -F/ '{print $1"/"$2}' | sort -u

# Log tail scan
tail -n 500 ~/Library/Logs/Whisperer/whisperer.log 2>/dev/null \
  | grep -iE "lock timeout|Metal|audio engine retry|Stuck state dump|kAudioUnitErr|-10877" | tail -20

# Load knowledge snapshot
for domain in audio transcription concurrency memory ui app-store state; do
  if [ -f "docs/knowledge/$domain/rules.md" ]; then
    echo "=== $domain ===" >> .claude/review-state/knowledge-snapshot.md
    cat "docs/knowledge/$domain/rules.md" >> .claude/review-state/knowledge-snapshot.md
  fi
done
```

Write `context.json` with `{ pass_number, branch, buckets, changed_files }`.

**Diff-scope gating table:**

| Bucket changed | Agents to run |
|---|---|
| `Whisperer/Audio/` | 1, 2, 6, 8, 10 |
| `Whisperer/Transcription/` (non-LLM) | 1, 2, 3, 4, 6, 8, 9, 10 |
| `Whisperer/Transcription/LLM/` | 2, 9, 12 |
| `Whisperer/Transcription/FluidAudio/NemotronBridge.swift` | 2, 9, 12 |
| `Whisperer/TextInjection/` | 5, 7, 10 |
| `Whisperer/UI/` | 4, 5, 10 |
| `WhispererApp.swift` or `AppState.swift` | 1, 2, 3, 6, 10 |
| `Store/` or `Licensing/` | 7, 11 |
| Always (regardless of diff) | 7, 11 |

---

## Step 1 — Launch All Selected Agents in One Parallel Batch

Send ALL selected agents as a **single message with multiple Agent tool calls** so they run concurrently. Do not send agents one at a time.

Each agent prompt follows this template (fill in `NN` and `Name`):

```
Read your full instructions from .claude/review-agents/agent-NN-<name>.md

Context:
- Diff: .claude/review-state/diff.patch
- Changed files: .claude/review-state/changed-files.txt
- Project rules snapshot: .claude/review-state/knowledge-snapshot.md (includes all docs/knowledge/ rules)
- Finding schema: .claude/review-agents/_shared-format.md
- Conflict rules: .claude/review-agents/_conflict-resolution.md

[If pass >= 2]: This is pass #N. Read commit messages on this branch before recommending reversals.
Focus on issues introduced since the previous pass, not decisions already committed.

Write ALL findings to .claude/review-state/findings/agent-NN.md using the schema from _shared-format.md.
Include the Learn: field on every P0 and P1 finding.

After writing the file, return exactly one line:
Agent N (Name): X P0, Y P1, Z P2
```

### Agent 1 — Memory & Lifecycle
Full instructions: `.claude/review-agents/agent-01-memory-lifecycle.md`
Learn domain: `memory`

### Agent 2 — Concurrency & Thread Safety
Full instructions: `.claude/review-agents/agent-02-concurrency-thread-safety.md`
Learn domain: `concurrency`

### Agent 3 — Architecture & Dependency Direction
Full instructions: `.claude/review-agents/agent-03-architecture-deps.md`
Learn domain: `transcription`

### Agent 4 — Codebase Consistency & DRY
Full instructions: `.claude/review-agents/agent-04-consistency-dry.md`
Learn domain: `ui`

### Agent 5 — macOS Platform & Performance
Full instructions: `.claude/review-agents/agent-05-platform-performance.md`
Learn domain: `ui`

### Agent 6 — State & Reliability
Full instructions: `.claude/review-agents/agent-06-state-reliability.md`
Learn domain: `state`

### Agent 7 — Security, Privacy & Logging
Full instructions: `.claude/review-agents/agent-07-security-logging.md`
Learn domain: `app-store`
**Always runs.**

### Agent 8 — Audio Pipeline & Real-Time Safety
Full instructions: `.claude/review-agents/agent-08-audio-realtime.md`
Learn domain: `audio`

### Agent 9 — whisper.cpp, GPU & ANE
Full instructions: `.claude/review-agents/agent-09-whisper-gpu-ane.md`
Learn domain: `transcription`

### Agent 10 — HUD, UX & Injection Latency
Full instructions: `.claude/review-agents/agent-10-hud-ux-latency.md`
Learn domain: `ui`

### Agent 11 — App Store Binary Auditor
Full instructions: `.claude/review-agents/agent-11-appstore-binary.md`
Learn domain: `app-store`
**Always runs.**

### Agent 12 — LLM Post-Processing & Nemotron (only when LLM/Nemotron files changed)
Full instructions: `.claude/review-agents/agent-12-llm-nemotron.md`
Learn domain: `transcription`

---

## Step 2 — Conflict Resolution

Read `_conflict-resolution.md` and all `findings/agent-NN.md` files. Apply the precedence table:
- P0 from any agent cannot be downgraded
- Same file:line from multiple agents → highest severity wins; others note "covered by agent N"
- SafeLock beats Swift actor for blocking C code
- Memory `[weak self]` beats Concurrency `[unowned self]`
- App Store concerns always win
- Platform: inline AX beats background dispatch

In pass 2+: read commit messages before recommending reversals. Do not re-litigate committed decisions.

---

## Step 3 — Apply Fixes

Follow `phase-fix.md` instructions:
- Sort P0 → P1 → P2
- Apply all fixes in order; never defer P0/P1 with "requires manual review"
- Specific fix patterns documented in `phase-fix.md`
- Write `.claude/review-state/fix-report.md`

---

## Step 4 — Learning Protocol

Follow `phase-learn.md` instructions:
- For each fixed P0/P1, append a new `RULE-<date>-<slug>` entry to `docs/knowledge/<domain>/rules.md`
- Update `docs/knowledge/INDEX.md` for new domains
- Promote hypotheses confirmed 3+ times to rules

---

## Step 5 — Verification

Follow `phase-verify.md` instructions. Run three-config parallel builds and four grep gates:

```bash
# Build all three configs
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Debug -destination "platform=macOS" ARCHS=arm64 2>&1 | tail -3 &
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration Release -destination "platform=macOS" ARCHS=arm64 2>&1 | tail -3 &
xcodebuild build -project Whisperer.xcodeproj -scheme whisperer -configuration AppStore -destination "platform=macOS" ARCHS=arm64 CODE_SIGN_ENTITLEMENTS=Whisperer/whisperer.entitlements ENABLE_APP_SANDBOX=YES 2>&1 | tail -3 &
wait

# Gate 1: No print()
grep -rn 'print(' Whisperer/ --include='*.swift' | grep -v 'Logger\|// debug' || echo "PASS"

# Gate 2: No banned APIs
grep -rn 'CGEventTap\|CGEvent\.tapCreate\|IOHIDManager\|IOKit\.hid\|addGlobalMonitorForEvents.*\.keyDown\|addGlobalMonitorForEvents.*\.keyUp\|IOHIDCheckAccess\|IOHIDRequestAccess' Whisperer/ --include='*.swift' || echo "PASS"

# Gate 3: stopAsync() only
grep -rn 'transcriber\.stop()\|streamingTranscriber?\.stop()' Whisperer/ --include='*.swift' | grep -v 'Async\|stopRecording\|stopAsync' || echo "PASS"

# Gate 4: Binary strings (AppStore build)
BINARY=$(find ~/Library/Developer/Xcode/DerivedData -name "whisperer" -type f 2>/dev/null | grep AppStore | head -1)
[ -n "$BINARY" ] && /usr/bin/strings "$BINARY" | grep -iE 'AXIsProcessTrusted|AXUIElement|CGEventTap|IOHIDManager|Grant.*Access|Grant.*Permission|Set Up Later|auto.?paste|autoPaste|Enable Auto-Paste|assistive' || echo "PASS"
```

**No unit tests exist.** Do not claim test coverage. State this plainly.

Write `.claude/review-state/verification.md`.

---

## Step 6 — UX/Perf Smoke (diff-scope aware)

Pick relevant items based on changed buckets:

| Bucket | Smoke item |
|---|---|
| `Transcription/`, `Audio/` | Time-to-first-preview-word ≤ 2s after key-down |
| `TextInjection/`, `AppState.swift` | Time-to-text-injected ≤ 200ms after key-up (excluding tail) |
| `AppState.swift` | HUD dismisses concurrent with text appearing |
| `Audio/` | `sudo killall coreaudiod` during recording → watchdog dumps ≤ 15s, HUD returns to `.idle` |
| `Transcription/` | Live preview text never shrinks mid-recording |
| `UI/`, `Transcription/` | RTL: Hebrew dictation → paragraph starts at right margin |
| `Transcription/LanguageRouter/` | Two-language recording → second uses warm fallback, no GPU stall |
| `Audio/AudioRecorder.swift` | Recording > 5 min cap behavior correct |
| `UI/OnboardingView.swift` | Onboarding first-launch flow if changed |

Mark unverified items honestly.

---

## Step 7 — Commit, Push, Summary

Follow `phase-commit.md`: one commit per logical fix, format `[final-review] <fix> (agent N)`.
Final commit: `[final-review] Write new rules to docs/knowledge/ (phase-learn)`.

```bash
git push -u origin HEAD
```

Follow `phase-summary.md`: produce convergence verdict table:

| Condition | Verdict |
|---|---|
| Any P0 NOT fixed AND build failing | **BLOCKED — do not merge** |
| Any P0 fixed this pass | **ANOTHER PASS NEEDED** |
| > 3 P1 fixes | **LIKELY NEEDS ANOTHER PASS** |
| 1–3 P1 fixes, all builds pass | **LIKELY CONVERGED** |
| 0 P1 fixes, P2 only | **CONVERGED** |
| 0 fixes | **CONVERGED — no issues found** |

Include in summary:
- Findings by agent (P0/P1/P2 counts)
- All fixes applied (file:line cited)
- New rules written to `docs/knowledge/`
- Build results and grep gate results
- Stuck dumps found (if any)
- UX smoke items run vs skipped
- Convergence verdict
