# Phase: Fix

## Purpose

Aggregates findings from all agents, resolves conflicts, applies fixes, writes fix-report.

## Actions

### 1. Aggregate All Findings

Read every `.claude/review-state/findings/agent-NN.md` file. Parse all findings into a list sorted by:
1. Severity (P0 first)
2. File path
3. Line number

### 2. Resolve Conflicts

Apply `_conflict-resolution.md` rules:
- Same file:line covered by multiple agents → keep highest severity; other agent notes "covered by agent N"
- SafeLock beats Swift actor for blocking C code
- Memory `[weak self]` beats Concurrency `[unowned self]`
- App Store concerns always win over any other concern
- No re-litigating decisions already committed in git history

### 3. Deduplicate

Combine findings that refer to the same file:line even if from different agents. Prefer the version with the highest severity and most specific fix.

### 4. Apply Fixes — P0 First

For each finding in priority order:
1. Read the affected file
2. Apply the Fix instruction exactly as specified in the finding
3. Verify the fix compiles (run `swiftc -parse` or check syntax)
4. Never defer with "requires manual review" — do the work

Specific fix rules:
- **Missing `[weak self]`**: add `[weak self]` to the capture list and add `guard let self = self else { return }` as the first line
- **`print()` → Logger**: replace with `Logger.debug/info/warning/error("...", subsystem: .<subsystem>)` with the correct subsystem
- **`#if ENABLE_APP_SANDBOX` → `#if APP_STORE`**: simple text replacement
- **`transcriber.stop()` → `await transcriber.stopAsync()`**: add `await` and change method name; ensure calling function is `async`
- **`NSScreen.main` → mouse-location screen**: apply the standard 3-line guard block from agent-10
- **AX call without timeout**: prepend `AXUIElementSetMessagingTimeout(appElement, 0.1)` and `AXUIElementSetMessagingTimeout(focusedElement, 0.1)`
- **Banned API outside `#if !APP_STORE`**: wrap the offending code block in `#if !APP_STORE ... #endif`
- **`==` threshold**: replace `== threshold` with `>= threshold`
- **Missing `guard !isRecovering`**: add guard at the top of every recovery entry point

### 5. Write fix-report.md

Write to `.claude/review-state/fix-report.md`:

```
# Fix Report — Pass #N
[timestamp]

## Applied (P0)
- file:line — [finding title]: [what was changed]

## Applied (P1)
- file:line — [finding title]: [what was changed]

## Applied (P2)
- file:line — [finding title]: [what was changed]

## Skipped
- file:line — [finding title]: [reason skipped] (only for genuine blockers — not "too complex")

## Findings Forwarded to phase-learn
- [domain] — [rule slug]: [what the new rule captures]
```

### 6. Return

Return one line:
```
Fix: N P0 fixed, M P1 fixed, K P2 fixed, J skipped
```
