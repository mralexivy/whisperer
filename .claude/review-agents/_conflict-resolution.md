# Conflict Resolution — Whisperer Review Agents

When two agents flag the same line with conflicting recommendations, use this table. First matching row wins.

## Precedence Table

| Conflict | Winner | Reason |
|---|---|---|
| Concurrency "use Swift actor" vs Whisper/GPU "use SafeLock" | Whisper/GPU — SafeLock | Blocking C code; Swift actors suspend, not block; `CLAUDE.md` explicit |
| Memory "`[weak self]`" vs Concurrency "`[unowned self]`" | Memory — `[weak self]` | Safer default; `[unowned self]` requires proof of lifetime outliving closure |
| Architecture "extract protocol" vs Consistency "single conformer" | Consistency — single conformer | No unit tests exist; protocols-for-testability has no payoff here |
| HUD/UX "skip animation" vs Consistency "keep typewriter" | HUD/UX — skip for RTL only | Language-conditional; animation is wrong for RTL scripts |
| State/Reliability "add retry" vs Architecture "keep simple" | State/Reliability — for I/O paths | I/O can fail transiently; reliability over simplicity |
| Platform "AX inline on caller thread" vs any "dispatch to background" | Platform — inline | Queue contention causes multi-second delays (BUG-S05); `ARCHITECTURE.md` §5 |
| App Store binary "remove string/code" vs Consistency "keep for feature" | App Store — remove | Ship-blocker; binary contents cause rejection |
| Two agents flag same line with same severity | Higher-numbered agent defers | Lower agent number wrote first; higher adds "covered by agent N" note |
| Two agents flag same line with different severity | Higher severity wins | Other agent notes "covered at higher severity by agent N" |
| Any agent recommendation vs established codebase pattern | Codebase pattern | Do not break working conventions for theoretical improvement |
| LLM mode "skip CorrectionEngine" vs any "apply corrections" | LLM mode — skip | BUG-T06: dictionary corrections corrupt LLM input; CLAUDE.md |

## P0 Absolute Rules

P0 findings from any agent can never be downgraded by another agent. If two agents disagree on severity and one says P0, P0 stands.

**P0 findings that must never be skipped regardless of conflict:**
- Data races on `StreamingTranscriber` unprotected properties
- `ModelPool.warmBackends` mutation without serialization
- Preview bridge `useGPU: true`
- ModelPool warm-check comparing full `ModelProfile` (language included)
- AX call without 100ms timeout
- `transcriber.stop()` instead of `stopAsync()`
- LLM warmup during recording
- Concurrent CoreML/ANE models without await
- Banned App Store APIs outside `#if !APP_STORE`
- AX direct-write as sole injection path

## Pass 2+ Discipline

In pass 2 or later:
1. Read commit messages on this branch before flagging anything
2. Do not re-flag decisions that were consciously committed in a prior pass
3. Only flag issues *introduced by* a prior pass fix
4. Do not propose refactoring that was not blocked by a real bug
5. Aim for convergence — the goal is "CONVERGED" verdict, not exhaustive coverage

## Fix Priority Order

Apply in this order: P0 → P1 → P2. Skip findings below P2 threshold. Never batch P0 and P2 in the same commit.
