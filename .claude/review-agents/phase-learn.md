# Phase: Learn

## Purpose

Extracts new knowledge from fixed P0/P1 findings and writes rules to `docs/knowledge/<domain>/rules.md`. Runs after `phase-fix.md`. Makes agents self-improving — every bug fixed becomes a check in future runs.

## Actions

### 1. Read fix-report.md

Parse `.claude/review-state/fix-report.md` for all "Applied (P0)" and "Applied (P1)" entries.

For each fixed finding, extract:
- `Learn:` domain field from the original finding in `findings/agent-NN.md`
- The file:line reference
- The finding title and fix description

### 2. Ensure Domain Folder Exists

For each domain encountered, ensure the folder exists:

```bash
mkdir -p docs/knowledge/<domain>
```

Create `knowledge.md`, `hypotheses.md`, and `rules.md` if they don't exist (empty files with headers).

### 3. Classify New vs Known

For each P0/P1 finding, check if a rule with a matching `Check:` pattern already exists in the domain's `rules.md`. If it does: no duplicate — skip. If it doesn't: new rule → append.

### 4. Append New Rules

For each novel P0/P1 finding, append to `docs/knowledge/<domain>/rules.md`:

```markdown
## RULE-<YYYYMMDD>-<short-kebab-slug>
Source: [final-review] agent-NN, pass #N
What: <one-line description of the anti-pattern that was found>
Why: <what broke when this shipped — reference the specific bug code if known>
Check: <grep command or code pattern that detects this anti-pattern>
Fix: <exact change required — one line>
```

### 5. Update docs/knowledge/INDEX.md

If a new domain folder was created, add a line to `docs/knowledge/INDEX.md`:

```markdown
- [domain/](domain/) — <one-line description of what this domain covers>
```

### 6. For Hypotheses

If a finding is P2 or was skipped (uncertain severity), append to `docs/knowledge/<domain>/hypotheses.md`:

```markdown
## HYPO-<YYYYMMDD>-<slug>
Observed: <what triggered the hypothesis>
Hypothesis: <tentative rule>
Needs: <what would confirm this — 3 occurrences, a crash report, etc.>
```

When a hypothesis is confirmed 3+ times across review runs, promote it to `rules.md` and remove from `hypotheses.md`.

### 7. Confirm Hypothesis Promotions

Scan all `hypotheses.md` files. If any hypothesis has been observed 3+ times (count occurrences in the fix history by searching for the slug in past `fix-report.md` files), promote to `rules.md` with `Source: promoted from hypothesis`.

### 8. Return

Return one line:
```
Learn: N new rules written, M hypotheses updated, K hypotheses promoted to rules → docs/knowledge/
```
