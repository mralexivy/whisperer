---
name: competitor-forensics
description: >
  Deep competitive intelligence skill — reverse-engineer any rival voice-to-text, dictation,
  or meeting-notes app and produce feature specs that explain WHY they're winning and what
  Whisperer can learn from them. Triggers on: "competitor analysis", "reverse engineer",
  "teardown", "forensics on", "compare us to", "what are we missing vs", "how does <app> do",
  "analyze <app>", "benchmark <app> against us", "what features does <app> have that we don't",
  "intelligence on <app>", "study <app>", "look at <app>". Target can be an installed .app
  path, a local git clone, a GitHub/GitLab URL, or a product name for public-source analysis.
  Produces: docs/competitive/<slug>-<date>/FEATURE-SPECS.md + SUMMARY.md.
metadata:
  version: 1.1.0
  category: intelligence
  tags: [competitive, forensics, product, analysis, planning]
---

# competitor-forensics — Competitor Intelligence & Feature Teardown

## ACTION REQUIRED (do these BEFORE reading the rest)

1. **NOW**: Identify the target(s) from the user's message. If genuinely unresolvable, fire one `AskUserQuestion`. Otherwise infer and proceed.
2. **NOW**: Create `docs/competitive/<slug>-$(date +%Y-%m-%d)/` and ensure `docs/competitive/` is in `.gitignore`.
3. **NOW**: Run the Phase 0 preflight block (baseline snapshot) before launching any agents.
4. **NEXT**: Classify each target (app-bundle / repo / both) → pick the right recon playbook.
5. **ACT**: Launch Phase 1 recon agents in a single parallel batch (one Agent call per target).

## Purpose

Point this skill at any rival — an installed `.app`, a local repo clone, or a GitHub URL — and
get back structured feature specs explaining what they do better, what we're missing entirely,
and what's worth copying. Output is on disk in `docs/competitive/` and is intentionally **never
committed** (gitignored). It's intelligence, not source.

---

## GUARDRAILS (non-negotiable — read before doing anything)

1. **Read-only.** Never modify, patch, re-sign, or bypass licensing / DRM / trial gates of any target.
2. **Clean-room analysis.** Record behavior and architecture. Never paste competitor source into Whisperer source.
3. **No competitor names in Whisperer source.** Findings live only in `docs/competitive/`. This is a standing rule from repo commits `01843e5` / `d32ee9f`.
4. **No model/asset extraction.** Record that a model exists and its shape (size, quantization, file name). Never copy bytes.
5. **Evidence-only claims.** Every finding must cite a path + line, a `strings` hit, or a linked public doc. Speculation gets an explicit `Inference:` prefix. Fabrication is worse than silence.
6. **App Store framing hygiene (our side).** Any adaptation idea must pass the CLAUDE.md Critical Rules filter before being written as ADOPT — especially Guideline 2.4.5 (no global event tap / IOHIDManager / `keyDown` monitor), MainActor confinement, and the sandboxing constraints.

---

## Workflow

### Phase 0 — Preflight (orchestrator, inline — do NOT delegate)

```bash
# 1. Resolve target(s) from the user's message.
#    If the target is genuinely ambiguous, ask one AskUserQuestion — otherwise infer.

# 2. Create run directory. docs/competitive/ is gitignored so nothing ships.
SLUG=$(echo "$TARGET" | tr '/' '-' | sed 's/\.app//' | tr '[:upper:]' '[:lower:]' | xargs basename)
RUN="docs/competitive/${SLUG}-$(date +%Y-%m-%d)"
mkdir -p "$RUN"

# Make sure docs/competitive/ is gitignored
grep -qx "docs/competitive/" .gitignore 2>/dev/null || echo "docs/competitive/" >> .gitignore

# 3. Build our baseline so dimension agents compare against facts, not memory.
git log --oneline > "$RUN/00-baseline.md"
echo "\n---FEATURES---\n" >> "$RUN/00-baseline.md"
grep "^## " docs/FEATURES.md >> "$RUN/00-baseline.md"
echo "\n---KNOWLEDGE INDEX---\n" >> "$RUN/00-baseline.md"
cat docs/knowledge/INDEX.md >> "$RUN/00-baseline.md"
```

4. Classify each target: is it an `app-bundle`, `repo`, or `both`?
   - Path ending in `.app` or found in `/Applications/` → `app-bundle` → use `references/recon-app-bundle.md`
   - Local directory with a git history, or a `github.com/` / `gitlab.com/` URL → `repo` → use `references/recon-repo.md`
   - Named product with no path → `repo` (public source search) + optional `app-bundle` if installed

Write a one-line classification for each target into `$RUN/00-targets.txt`.

---

### Phase 1 — Evidence Collection (parallel — one Agent per target)

Launch all recon agents **in a single response with multiple Agent tool calls**. Each agent:

- Reads **only** the applicable playbook (`references/recon-app-bundle.md` or `references/recon-repo.md`)
- Produces `$RUN/10-evidence-<slug>.md` — raw facts with provenance, zero comparison
- The format for each finding in the evidence file is:
  ```
  SIGNAL: <what was observed, e.g. `strings` hit, file found, doc quote>
  SOURCE: <path:line or URL>
  FACT: <one sentence statement of fact>
  ```

Agent prompt template:
```
You are a competitive recon agent studying <TARGET>.
Read the playbook at .claude/skills/competitor-forensics/references/recon-<TYPE>.md and follow it exactly.
Target: <TARGET>
Write all findings to <RUN>/10-evidence-<SLUG>.md.
Format every finding as SIGNAL / SOURCE / FACT.
Do not compare. Do not recommend. Only facts with provenance.
The guardrails at the top of .claude/skills/competitor-forensics/SKILL.md apply — read them first.
```

Wait for all Phase 1 agents to complete before proceeding.

---

### Phase 2 — Dimension Analysis (parallel — one Agent per dimension)

Read `references/dimensions.md`. For each of the 9 dimensions, check whether `$RUN/10-evidence-*.md` contains enough evidence to say something meaningful. **Skip dimensions with no evidence rather than fabricate.**

Launch all dimension agents in a single response. Each agent:

- Reads `$RUN/00-baseline.md` and all `$RUN/10-evidence-*.md`
- Reads its own section in `references/dimensions.md` (passed in the prompt)
- Uses `codegraph_context` / `codegraph_explore` (per CLAUDE.md) to confirm what Whisperer actually does before judging
- Writes `$RUN/20-<dimension-slug>.md` with findings tagged `AHEAD`, `GAP`, or `BEHIND`:
  - `AHEAD` — they beat us; state mechanism and delta
  - `GAP` — we have no equivalent at all
  - `BEHIND` — we're stronger; record it so we protect the lead
- Uses the spec format from `references/spec-template.md` for every finding

Agent prompt template:
```
You are a competitive analysis agent for dimension: <DIMENSION NAME>.

Context files to read first:
- <RUN>/00-baseline.md  (Whisperer's current capabilities — compare against this)
- <RUN>/10-evidence-*.md (all evidence files from Phase 1)

Your dimension definition (paste the relevant section from references/dimensions.md here):
<DIMENSION SECTION TEXT>

Instructions:
1. Use codegraph_context and codegraph_explore to confirm what Whisperer actually does for this dimension before judging.
2. For each meaningful difference, write a finding block using the template in .claude/skills/competitor-forensics/references/spec-template.md.
3. Tag every finding AHEAD, GAP, or BEHIND.
4. Cite evidence from the evidence files. Mark speculation as Inference:.
5. Guardrails: .claude/skills/competitor-forensics/SKILL.md — read them.
6. Write output to <RUN>/20-<dimension-slug>.md.
```

Wait for all Phase 2 agents to complete.

---

### Phase 3 — Reconcile (orchestrator, inline)

1. Read all `$RUN/20-*.md` files.
2. Merge all `AHEAD` and `GAP` findings into `$RUN/FEATURE-SPECS.md`:
   - Sort by impact (H → M → L)
   - Within same impact, AHEAD before GAP (they're actively beating us, not just a gap we haven't noticed)
   - Use the full spec format from `references/spec-template.md`
3. Write `$RUN/SUMMARY.md`:
   ```markdown
   # Competitive Summary — <TARGET> vs Whisperer — <DATE>
   
   ## Top 5 things to steal
   1. …
   
   ## Top 3 things they do that we should NOT copy
   1. … (reason: conflicts with CLAUDE.md constraint / product philosophy / App Store rule)
   
   ## Product philosophy delta
   One paragraph comparing their product thesis to ours (docs/PRODUCT_SENSE.md).
   
   ## Files to read before planning
   List the $RUN/20-*.md files most relevant to any adoption work.
   ```
4. Report to user:
   - Path to FEATURE-SPECS.md and SUMMARY.md
   - Count of AHEAD / GAP / BEHIND findings
   - Top 3 AHEAD/GAP items by impact in a brief bulleted list
   - Note that nothing was committed — the intel lives in docs/competitive/ (gitignored)

---

## Evidence ID System

Every finding in the evidence files gets a stable ID: `E-{three-digit-number}` (e.g. `E-001`).
Use the ID to cross-reference between evidence files and dimension analysis files.

### Evidence validation levels

| Level | Evidence bar | When to use |
|---|---|---|
| `preliminary` | 1 source | Initial string hit or doc quote — not enough to claim as a confirmed feature |
| `candidate` | 1 source + inference is plausible | Defensible hypothesis; report as candidate in FEATURE-SPECS |
| **validated** | **≥2 independent sources** (e.g. strings hit + public doc, or repo + App Store listing) | Required before tagging ADOPT in FEATURE-SPECS |

A single evidence item alone MUST NOT promote a finding to `validated`. Record `E-insufficient-evidence` if you want to flag something as real but can't confirm it.

Evidence format (use in `10-evidence-<slug>.md`):
```
### E-{nnn}
- title: <one-line description>
- source_type: strings | plist | framework | prefs | repo | public-doc | strings-hit | file
- source_ref: <path:line or URL>
- repro_command: |
    <exact shell command that produced this signal, or "manual read of <URL>">
- raw_excerpt: |
    <verbatim quote or output — desensitize model names from competitor source if needed>
- validation_level: preliminary | candidate | validated
- linked_finding: F-{nnn} | n/a
```

---

## Analysis Blindspot Cookbook

Common mistakes dimension agents make — check these before promoting a finding to ADOPT.

| Blindspot | Wrong inference | Correct approach |
|---|---|---|
| Framework linked ≠ feature used | `CoreML.framework` linked → "they use Core ML for ASR" | Check `strings` for CoreML calls near ASR code; `otool` tells you it's linked, not that it's on the hot path |
| Model file present ≠ model loaded | A `.gguf` in Resources → "they ship local LLM" | Also check prefs for model path; check size — a 4MB `.bin` is probably tokenizer vocab, not a model |
| No Accessibility entitlement ≠ no injection | Missing entitlement → "they can't inject text" | They may use a non-sandboxed Dev build or a privileged helper — check for XPC service, login item, entitlement in helper |
| Public doc ≠ current implementation | Blog post from 2024 → "they use X" | Release notes often contradict blog posts; changelog is more reliable; strings confirm |
| Big number ≠ user impact | "They have 40 languages" → we need 40 languages | Check which 5 languages cover 95% of their user reviews; quality > count |
| BEHIND = safe to ignore | We beat them on X → no action needed | Record BEHIND explicitly — it's a lead to protect; log what makes us better so we don't accidentally regress |
| Our code = what we ship | Our source says X | Check whether X is gated behind `#if !APP_STORE` — it may not be in the binary users download |

---

## Quick reference — agent launch count

| Scenario | Phase 1 agents | Phase 2 agents (max) |
|---|---|---|
| 1 target | 1 | up to 9 |
| 2 targets | 2 | up to 9 |
| N targets | N | up to 9 |

Phase 2 agents are per-dimension, not per-target. The dimension agents read all evidence files.

---

## Output location

```
docs/competitive/<slug>-<date>/
  00-baseline.md          (our capability snapshot)
  00-targets.txt          (target classification)
  10-evidence-<slug>.md   (per-target facts with E-nnn IDs)
  20-<dimension>.md       (per-dimension analysis, up to 9)
  FEATURE-SPECS.md        (merged specs sorted by impact)
  SUMMARY.md              (executive brief)
```

None of these files are ever committed. `docs/competitive/` is gitignored on first run.

---

## Completion Checklist (MUST pass before reporting done)

- [ ] Did I write `00-baseline.md` with our actual capability snapshot (not from memory)?
- [ ] Did I launch Phase 1 recon agents in parallel (not sequentially)?
- [ ] Does every evidence finding have an `E-nnn` ID and a `source_ref`?
- [ ] Did I skip any dimension that had no evidence (rather than fabricating findings)?
- [ ] Does every ADOPT verdict have `validated` evidence (≥2 independent sources)?
- [ ] Did I check each ADOPT against the Blindspot Cookbook before writing it?
- [ ] Did I check each ADOPT against CLAUDE.md Critical Rules and App Store framing?
- [ ] Is `docs/competitive/` in `.gitignore`? (grep to confirm, don't trust memory)
- [ ] Does `SUMMARY.md` include the "top 3 things NOT to copy" section?
- [ ] Are any competitor names or evidence paths visible anywhere under `Whisperer/`? (They must not be.)
