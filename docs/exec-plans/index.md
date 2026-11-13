# Execution Plans

## Active Plans

- [Whisperer Cloud — implementation plan (for approval)](cloud-sync-implementation.md) — the concrete build: cloud layout, API, Mac pieces, App Store Connect setup, milestones A–I
- [Whisperer Cloud — paid, end-to-end encrypted history sync](cloud-sync.md) — plan: GCS + a small Go
  service on Cloud Run, StoreKit subscription, pricing and unit economics; nothing built yet
- [Live transcript paragraphs](live-transcript-paragraphs.md) — implemented 2026-11-12 (timed words,
  segmenter, post-meeting pass); notes on what was measured

- [Connected AI providers](connected-ai-providers.md) — proposed: meeting notes + Ask AI on the
  user's own AI (Codex / Claude Code / Antigravity CLIs, ChatGPT OAuth, API keys), local default

- [W2 — Correction learning](correction-learning.md) — conservative, off-by-default candidate
  collection; automatic dictionary promotion is explicitly not enabled
- [Fast Polish — where we stand](deterministic-polish-status.md) — non-generative polishing on
  `feat/deterministic-polish`; built, measured, behind an off-by-default experimental toggle,
  unmerged

## Completed Plans

- [W1 retry — explicit-correction prompt](explicit-correction-prompt.md) — blocked/unmeasured:
  zero eligible user-created corrections; runtime arm reverted under the fixed rule
- [W4 — Index-anchored live preview](index-anchored-live-preview.md) — rejected: eager previews
  are already sample-index anchored and serial; confirmed-only projection cost 3.4s to first text
- [App Store Submission](app-store-submission.md) — Track A complete, ready for submission
