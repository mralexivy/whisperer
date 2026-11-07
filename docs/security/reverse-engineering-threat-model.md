# Reverse-engineering threat model — Whisperer (Mac App Store)

Status: Phase 1–2 ground truth (2026-11-07). Branch `feature/app-protection`, isolated worktree;
no change reaches the submission path until reviewed and merged. Release-binary RE assessment
(Phase 2 with otool/nm/Hopper) is pending free compute and is marked TODO below.

## Attacker model

The attacker has the installed `.app` and full control of their own Apple Silicon Mac (can run
LLDB, Hopper/Ghidra, Frida on their own copy, disable SIP on their machine). This is the baseline
for any locally distributed app. We do **not** claim native binaries or on-disk model weights can be
made unextractable; the goal is to raise cost and remove accidental disclosure.

## Assets, attacks, realistic protection

| Asset | Attack | Realistic protection | Residual risk |
|---|---|---|---|
| Proprietary Swift logic (ASR routing, `LanguageRouter`/`ModelRouter`/`ScriptAnalyzer`, meeting pipeline, polish/editor) | Decompile, read Swift metadata and names | `-O` + whole-module + Swift symbol strip raises the floor; names in public API remain | High — determined RE can follow logic |
| Bundled/downloaded model weights (whisper ggml, Nemotron, Qwen, Parakeet, mmBERT, the new shield `.wspn`) | Copy files from the bundle / Application Support | None for confidentiality; integrity only (signatures) | High — weights are extractable by design |
| Secrets/credentials | Extract from binary or resources | None needed: source scan found no live secrets; only `http://localhost` (MCP) | Low |
| User data (recordings, transcripts, meetings) | Read another user's data | OS file perms + sandbox container; stays on device | Low (same-user access is inherent) |
| Commercial entitlement (Pro Pack IAP) | Patch the check to unlock Pro | StoreKit 2 verified transactions; hardened runtime + signature make patching a signed MAS build non-trivial | Medium — a cracked unsigned copy is always possible |
| Binary integrity | Modify code/resources and redistribute | Hardened Runtime + code signature + notarization/MAS signature; macroOS Gatekeeper rejects broken signatures | Medium |

## Ground truth found (repo `90384789`)

- **App Store entitlements** (`Whisperer/whisperer.entitlements`): app-sandbox, network.client,
  network.server (MCP loopback), files.user-selected.read-write, device.audio-input, device.camera.
  All map to shipped features. No `get-task-allow` (no debug entitlement). Direct build uses
  `whisperer-nosandbox.entitlements`.
- **Release/AppStore hardening already present**: `ENABLE_HARDENED_RUNTIME=YES`,
  `ENABLE_APP_SANDBOX=YES` (AppStore), `STRIP_INSTALLED_PRODUCT=YES`, `STRIP_SWIFT_SYMBOLS=YES`,
  `DEAD_CODE_STRIPPING=YES`, `COPY_PHASE_STRIP=YES`, `SWIFT_COMPILATION_MODE=wholemodule`,
  `DEBUG_INFORMATION_FORMAT=dwarf-with-dsym` (dSYM preserved — crash symbolication kept).
- **Headline gap (fixed on this branch)**: `SWIFT_OPTIMIZATION_LEVEL` was **unset** for Release and
  AppStore, so the Swift compiler default `-Onone` applied — the shipping app was unoptimized.
  Unoptimized Swift both runs slower and is markedly easier to read. Added `-O` to both shipping
  configs; `-showBuildSettings` now reports `-O`. Build + benchmark verification: **pending**.
- **Secrets**: none in source (scanned for OpenAI/AWS/GitHub/PEM patterns). Only `http://localhost`.
- **Privacy manifest**: none existed. Added `Whisperer/PrivacyInfo.xcprivacy` (UserDefaults CA92.1,
  file-timestamp DDA9.1, system-boot-time 35F9.1; no tracking, no collected data).

## TODO (needs free compute / tools)

- Build Release + AppStore, run `codesign -dvvv`, `otool -l`, `nm`, `strings`, `swift-demangle`,
  `dwarfdump --uuid` on the product; record recoverable symbols and time-to-understand a target
  function, before vs after `-O`.
- Confirm `-O` causes no functional/accuracy regression (full test suite + inference benchmark).
- Decide resource-integrity scope: a signed manifest of bundled model files, verified at load, to
  detect tampering (authenticity, not confidentiality).
