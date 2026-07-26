# Phase: Summary

## Purpose

Produces a human-readable final report. Runs after `phase-commit.md`.

## Actions

### 1. Read All State Files

- `.claude/review-state/context.json` — pass number, branch, buckets
- `.claude/review-state/findings/agent-NN.md` — all agent findings (12 files)
- `.claude/review-state/fix-report.md` — what was fixed
- `.claude/review-state/verification.md` — build and grep gate results
- `docs/knowledge/*/rules.md` — to count new rules added this pass

### 2. Build Summary Output

```
═══════════════════════════════════════════════════════
FINAL REVIEW SUMMARY — Pass #N
Branch: <branch>
Buckets reviewed: <list>
═══════════════════════════════════════════════════════

FINDINGS BY AGENT
─────────────────
Agent 1  (Memory & Lifecycle)          P0: X  P1: Y  P2: Z
Agent 2  (Concurrency & Thread Safety) P0: X  P1: Y  P2: Z
Agent 3  (Architecture & Deps)         P0: X  P1: Y  P2: Z
Agent 4  (Consistency & DRY)           P0: X  P1: Y  P2: Z
Agent 5  (Platform & Performance)      P0: X  P1: Y  P2: Z
Agent 6  (State & Reliability)         P0: X  P1: Y  P2: Z
Agent 7  (Security & Logging)          P0: X  P1: Y  P2: Z
Agent 8  (Audio & Real-Time)           P0: X  P1: Y  P2: Z
Agent 9  (Whisper/GPU/ANE)             P0: X  P1: Y  P2: Z
Agent 10 (HUD & UX)                    P0: X  P1: Y  P2: Z
Agent 11 (App Store Binary)            P0: X  P1: Y  P2: Z
Agent 12 (LLM & Nemotron)             P0: X  P1: Y  P2: Z
─────────────────────────────────────────────────────
TOTAL                                  P0: X  P1: Y  P2: Z

FIXES APPLIED
─────────────
P0 Fixes (N):
  • file:line — [title] → [what was changed]

P1 Fixes (N):
  • file:line — [title] → [what was changed]

P2 Fixes (N):
  • file:line — [title] → [what was changed]

Skipped (N):
  • file:line — [title] → [reason]

BUILD RESULTS
─────────────
Debug:    ✓ PASS  /  ✗ FAIL (first error: ...)
Release:  ✓ PASS  /  ✗ FAIL (first error: ...)
AppStore: ✓ PASS  /  ✗ FAIL (first error: ...)

GREP GATES
──────────
No print():        ✓ PASS  /  ✗ FAIL
No banned APIs:    ✓ PASS  /  ✗ FAIL
stopAsync():       ✓ PASS  /  ✗ FAIL
Binary strings:    ✓ PASS  /  ✗ FAIL  /  — SKIPPED

KNOWLEDGE WRITTEN
─────────────────
N new rules added to docs/knowledge/:
  • audio/rules.md: RULE-<date>-<slug>
  • transcription/rules.md: RULE-<date>-<slug>
  ...
M hypotheses updated (need 3 confirmations to promote)

CONVERGENCE VERDICT
───────────────────
```

### 3. Convergence Verdict Table

| Condition | Verdict |
|---|---|
| Any P0 NOT fixed AND build failing | **BLOCKED — do not merge** |
| Any P0 fixed this pass | **ANOTHER PASS NEEDED — new P0s may have been exposed** |
| > 3 P1 fixes this pass | **LIKELY NEEDS ANOTHER PASS** |
| 1–3 P1 fixes, all builds pass | **LIKELY CONVERGED** |
| 0 P1 fixes, P2 only, all builds pass | **CONVERGED** |
| 0 fixes of any kind | **CONVERGED — no issues found** |

### 4. Next Steps Line

```
Next steps: [BLOCKED: fix P0 before merge] OR [Run /final-review again] OR [Ready to merge]
```

### 5. Return

Print the full summary to the user. No file write needed — this is the human-facing output.

Return one line to the orchestrator:
```
Summary: Pass #N complete — [verdict]
```
