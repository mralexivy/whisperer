# Phase: Preflight

## Purpose

Runs before all agents. Gathers context, writes shared state to `.claude/review-state/`, and loads the knowledge snapshot so agents don't re-read disk.

## Actions

### 1. Initialize State Directory

```bash
mkdir -p .claude/review-state/findings
```

### 2. Determine Pass Number

Read `.claude/review-state/context.json` if it exists (pass_number field). This is pass N if the file exists, pass 1 if not.

### 3. Write diff.patch and changed-files.txt

```bash
# Generate diff from last commit (or against main for first pass)
git diff HEAD > .claude/review-state/diff.patch
git diff HEAD --name-only > .claude/review-state/changed-files.txt
```

If diff is empty (no uncommitted changes), diff against the last 3 commits:
```bash
git diff HEAD~3 HEAD > .claude/review-state/diff.patch
git diff HEAD~3 HEAD --name-only > .claude/review-state/changed-files.txt
```

### 4. Determine Changed Buckets

Read `changed-files.txt` and categorize into buckets:
- `audio` — any file under `Whisperer/Audio/`
- `transcription` — any file under `Whisperer/Transcription/` (excluding LLM and Nemotron)
- `llm` — any file under `Whisperer/Transcription/LLM/`
- `nemotron` — `NemotronBridge.swift`, `FluidAudioBridge.swift`, any FluidAudio file
- `ui` — any file under `Whisperer/UI/`
- `text-injection` — any file under `Whisperer/TextInjection/`
- `state` — `AppState.swift`
- `store` — `Store/`, `Licensing/`
- `always` — always enabled (agents 7 and 11 always run)

### 5. Write context.json

```json
{
  "pass_number": N,
  "branch": "<current git branch>",
  "buckets": ["audio", "ui", ...],
  "changed_files": ["Whisperer/Audio/AudioRecorder.swift", ...],
  "build_status": "unknown"
}
```

### 6. Load Knowledge Snapshot

Read all `docs/knowledge/<domain>/rules.md` files that exist and concatenate them into `.claude/review-state/knowledge-snapshot.md`:

```
# Knowledge Snapshot — loaded from docs/knowledge/
[timestamp]

## audio rules
[contents of docs/knowledge/audio/rules.md]

## transcription rules
[contents of docs/knowledge/transcription/rules.md]

## concurrency rules
[contents of docs/knowledge/concurrency/rules.md]

## memory rules
[contents of docs/knowledge/memory/rules.md]

## ui rules
[contents of docs/knowledge/ui/rules.md]

## app-store rules
[contents of docs/knowledge/app-store/rules.md]

## state rules
[contents of docs/knowledge/state/rules.md]
```

If a domain folder doesn't exist, skip it (no error).

### 7. Report

Return one line:
```
Preflight: Pass #N, M files changed, buckets: [list], knowledge-rules-loaded: K rules
```
