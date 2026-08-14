# Technical Debt Tracker

## High Priority

(None currently)

## Medium Priority

- **`print()` statements in production code** — GlobalKeyListener, TextInjector, and PermissionManager use `print()` instead of `Logger`. Should migrate to `Logger.info/debug()` with appropriate subsystems per AGENTS.md conventions.
- **The post-processing LLM is loaded twice** — `AppState.llmPostProcessor` (dictation) and `MeetingEngines.llmInstance` (title / overview / Ask AI) are separate `LLMPostProcessor` instances. Since both now default to `.qwen2_5_1_5B`, a meeting recorded with dictation post-processing enabled holds the *same* ~1.6 GB of weights twice — roughly what the 4B alone cost before the swap. Sharing one instance means reconciling two different KV-cache policies (dictation warms a per-mode prefix and reuses it constantly; meetings deliberately pass `reuseWarmCache: false` so a one-shot overview does not evict it) and two different ownership lifetimes (`MeetingEngines.borrowLLM()` refcounts with a 60s idle unload; `AppState` keeps its instance for the session). Worth doing, not worth doing casually.
- **Carbon API deprecation risk** — `RegisterEventHotKey` is a Carbon API. While it still works on macOS 15 and is used by many shipping apps, Apple may deprecate it. Monitor WWDC for modern alternatives (e.g., `NSEvent.addGlobalMonitorForEvents` for hotkeys if Apple adds press/release support).

## Low Priority

- **Clipboard restore timing** — The 100ms delay after `simulatePaste()` before restoring clipboard is a best-guess value. If users report clipboard content loss, this may need tuning or a more robust mechanism (e.g., pasteboard change count monitoring).
- **`NSAppleEventsUsageDescription` in Info.plist** — Currently present but the app no longer uses Apple Events/automation. Could be removed if not needed for any remaining functionality.

## Resolved

- **Three-layer key detection complexity** — Replaced CGEventTap + IOKit HID + NSEvent with flagsChanged + Carbon hotkeys. Simpler, App Store compliant. (v1.0 build 2)
- **Text injection latency (2.4s+)** — Removed background dispatch, added AX messaging timeouts. (v1.0 build 2)
- **Audio engine crash on repeated recordings** — Added format validation, universal retry with engine teardown, `cleanupEngineState()` helper. (v1.0 build 2)
- **Input Monitoring permission requirement** — Removed entirely. No longer needed with current key detection approach. (v1.0 build 2)
