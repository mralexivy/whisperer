# Planning & Execution

## Active Plans

See [docs/exec-plans/](docs/exec-plans/) for active and completed execution plans.

## Tech Debt

Tracked in [docs/exec-plans/tech-debt.md](docs/exec-plans/tech-debt.md).

## Planning Process

1. Feature proposals start as GitHub issues or discussions
2. Complex features get design docs in [docs/design-docs/](docs/design-docs/)
3. Execution plans go in [docs/exec-plans/](docs/exec-plans/) with clear acceptance criteria
4. Completed plans are marked as such but retained for reference

## Current Focus Areas

- App Store resubmission (v1.0 build 2) — awaiting review after Guideline 2.4.5 compliance fix
- Workspace window polish and UX refinement
- Dictionary & spell correction accuracy

## Completed

- **App Store Guideline 2.4.5 compliance** — Removed CGEventTap, IOHIDManager, global keyDown/keyUp monitors. Replaced with flagsChanged + Carbon hotkeys. Removed Input Monitoring permission. See [docs/exec-plans/app-store-submission.md](docs/exec-plans/app-store-submission.md).
- **Text injection latency fix** — Removed background dispatch that caused 2.4s+ delays from queue contention. Added AX messaging timeouts (100ms).
- **Audio engine crash protection** — Added universal retry logic with engine teardown and format validation for transient device errors (error 1852797029).
