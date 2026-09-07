# Recon Playbook — Repository (OSS or Local Clone)

Use this playbook when the target is a GitHub/GitLab URL, a local git clone, or a named product whose source is publicly available.

---

## Step 1 — Whole-repo snapshot (prefer repomix)

For a **remote** GitHub/GitLab URL:
```
Use mcp__repomix__pack_remote_repository with the URL.
Then use mcp__repomix__grep_repomix_output for targeted searches.
```

For a **local clone**:
```bash
# Directory survey
find <repo> -type f | grep -vE "\.git/|node_modules/|__pycache__|\.DS_Store" | sort | head -200

# Top-level README
head -100 <repo>/README.md

# Entrypoint / package manifest
cat <repo>/Package.swift 2>/dev/null || cat <repo>/package.json 2>/dev/null || cat <repo>/Cargo.toml 2>/dev/null || cat <repo>/pyproject.toml 2>/dev/null | head -80
```

If the repo is indexed with CodeGraph (`codegraph_status` returns healthy): use `codegraph_context` and `codegraph_explore` for architecture questions — they're faster and more accurate than grep.

---

## Step 2 — Architecture Q&A (public repos via deepwiki)

```
mcp__deepwiki__ask_question:
  repo: <owner/repo>
  question: "What is the overall architecture? How does audio capture and transcription work end to end?"

Follow-up questions as needed:
  "How does it handle text injection / delivery to the target app?"
  "What ASR models does it use and how are they loaded?"
  "How does the live preview / streaming transcription work?"
  "What post-processing or LLM polish happens after transcription?"
  "How does it handle speaker diarization in meeting mode?"
  "What is the hotkey / recording model?"
  "What is the resource utilization profile (memory, GPU, idle cost)?"
```

Record each answer verbatim with attribution.

---

## Step 3 — PR and issue archaeology

```bash
# Recent merged PRs (gh CLI)
gh pr list --repo <owner/repo> --state merged --limit 50 --json title,mergedAt,body | jq '.[] | "\(.mergedAt)  \(.title)"' | head -50

# Closed issues — look for feature requests they implemented
gh issue list --repo <owner/repo> --state closed --limit 50 --json title,closedAt,labels | jq '.[] | "\(.closedAt)  \(.title)"' | head -50

# Reverted PRs (what they tried and pulled back — equally informative)
gh pr list --repo <owner/repo> --state merged --limit 100 --json title,mergedAt,body | jq '.[] | select(.title | test("revert"; "i")) | "\(.mergedAt)  \(.title)"'

# Release notes
gh release list --repo <owner/repo> --limit 20
gh release view <tag> --repo <owner/repo>
```

What to look for: features tried and reverted (tells you what's hard), feature roadmap items mentioned in issues, performance regression fixes (tells you where they struggled), and security / privacy patches.

---

## Step 4 — Targeted code reads (after mapping the structure)

After Step 1–3 give you the layout, do targeted reads of the hot files. Common areas to focus on:

**Audio capture:**
- Search: `AVCaptureDevice`, `AVAudioEngine`, `AudioQueue`, `PortAudio`, `PyAudio`, `sounddevice`
- What sample rate? Mono vs stereo? Resampling?

**ASR integration:**
- Search: `whisper`, `WhisperKit`, `mlx_whisper`, `faster-whisper`, `openai.audio`, `AssemblyAI`, `Deepgram`
- Is it streaming (chunks) or batch (whole recording)? Chunk size?

**Text delivery:**
- Search: `AXUIElement`, `CGEventPost`, `CGEvent`, `NSPasteboard`, `pbcopy`, `xdotool`, `ydotool`
- Is it privileged helper or same-process? Sandboxed or not?

**Post-processing:**
- Search: `openai.ChatCompletion`, `anthropic`, `mlx`, `CoreML`, `formatText`, `punctuation`, `capitalize`
- Does it have a dictionary / correction system?

**Streaming / live preview:**
- Search for token streaming, chunk callbacks, partial results, progressive display
- What's the display latency between speech and text appearing?

**Meeting / diarization:**
- Search: `diarize`, `speaker`, `whisperx`, `pyannote`, `CoreML` speaker embeddings
- How are speakers labeled? Is it on-device or cloud?

---

## Step 5 — Public documentation and changelog

Use WebFetch / WebSearch:

1. Product homepage — feature list and positioning copy
2. Official changelog / release notes page (not just GitHub releases)
3. Blog posts: look for "how we built X", "behind the scenes", "v2 architecture" posts
4. HN / Reddit discussions: `site:news.ycombinator.com <name>`, `site:reddit.com <name>`
5. ProductHunt listing comments — often capture early design decisions
6. YouTube demos — describe what you observe in the UI (timestamps, UI states)
7. Twitter/X threads from founders describing technical decisions

---

## Step 6 — Dependency graph

```bash
# Swift Package Manager
cat <repo>/Package.swift | grep -A3 "\.package("

# Python
cat <repo>/requirements*.txt 2>/dev/null; cat <repo>/pyproject.toml 2>/dev/null

# Node / Electron
cat <repo>/package.json | python3 -m json.tool | grep -A1 '"dependencies"' | head -40
```

Notable dependencies and what they reveal:
| Dependency | Inference |
|---|---|
| `whisper.cpp` (vendored or submodule) | Local Metal/CPU inference — same stack as us |
| `faster-whisper` | CTranslate2 backend — optimized CPU inference |
| `WhisperKit` | Apple's official Swift wrapper — Core ML ANE path |
| `mlx` or `mlx-whisper` | Apple MLX on Apple Silicon — ANE + GPU hybrid |
| `pyannote-audio` | Speaker diarization (requires HuggingFace token, not fully offline) |
| `openai` SDK | Cloud ASR fallback or LLM post-processing |
| `anthropic` SDK | Claude for post-processing |
| `ollama` | Local LLM inference |
| `electron` | Cross-platform Electron app |
| `tauri` | Rust + WebView cross-platform (lighter than Electron) |

---

## Evidence format reminder

Every finding goes into `$RUN/10-evidence-<slug>.md` as:
```
SIGNAL: <what was observed — quote, file path, PR title, etc.>
SOURCE: <URL / path:line / gh command used>
FACT: <one sentence conclusion>
```

Mark any non-literal inference as `Inference:` inside the FACT line.
