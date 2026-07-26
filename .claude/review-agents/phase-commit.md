# Phase: Commit

## Purpose

Commits each logical fix as a separate commit. Runs after `phase-verify.md` confirms all builds pass.

## Precondition

Only run if `verification.md` shows all three builds as SUCCEEDED and all 4 grep gates as PASS.

## Actions

### 1. Read fix-report.md

Parse `.claude/review-state/fix-report.md` for all applied fixes with their file references.

### 2. Group by Logical Unit

Group fixes that belong to the same logical change (same bug, same file, or tightly related pattern):
- All `[weak self]` additions across files → one commit
- Each P0 bug fix → its own commit
- Related P1 fixes in the same file → one commit
- Learning protocol outputs (`docs/knowledge/` rule additions) → separate commit at the end

### 3. Commit Each Group

For each group, stage only the relevant files and commit:

```bash
git add <specific files only, never git add -A>
git commit -m "[final-review] <fix description> (agent N)"
```

Commit message format: `[final-review] <imperative verb> <what was fixed> (agent N)`

Examples:
- `[final-review] Fix stopAsync race in stopRecording path (agent 6)`
- `[final-review] Guard previewBridge as CPU-only in ModelPool (agent 9)`
- `[final-review] Replace ENABLE_APP_SANDBOX with APP_STORE flag (agents 3, 7)`
- `[final-review] Add weak self to NemotronBridge callback captures (agent 1)`
- `[final-review] Write new rules to docs/knowledge/ (phase-learn)`

### 4. Learning Commit (Last)

Stage and commit all `docs/knowledge/` changes as the final commit:

```bash
git add docs/knowledge/
git commit -m "[final-review] Write new rules to docs/knowledge/ (phase-learn)"
```

### 5. Return

Return one line:
```
Commit: N commits made (M fixes + 1 knowledge update)
```

## Notes

- Never `git add -A` or `git add .` — always add specific files by name
- Never use `--no-verify` — hooks must run
- Never amend previous commits — always create new commits
- If a commit fails (hook failure), fix the underlying issue and retry — do NOT skip hooks
