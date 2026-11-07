# App Store feature unlock — what can ship safely, and how

Researched 2026-11-06. Sources are linked inline; where evidence is thin it says so.
Context: [app-store-submission.md](app-store-submission.md) (four 2.4.5 rejections for Accessibility),
[connected-ai-providers.md](connected-ai-providers.md).

## Verdicts

| Feature | Gated because | App-Store-safe route | Verdict | Effort |
|---|---|---|---|---|
| Dictation Polish / AI Post-Processing settings | Card sits inside an `#if !APP_STORE` block (`WhispererApp.swift:2568`, `LLMPageView.swift:49`) that only the Rewrite rows need | Move the gate down to the Rewrite rows | **Ship now** | 1–2 h |
| Feedback sidebar item (`HistoryWindowView`) | Gated with Command Mode; no AX/shell of its own — verify | Ungate if it uses no shell or blocked Mail path | **Ship now** (verify) | 1 h |
| MCP one-click install — Cursor, VS Code, LM Studio | Installer writes other apps' config files | Deep links via `NSWorkspace.open`: `cursor://anysphere.cursor-deeplink/mcp/install?name=whisperer&config=<base64>` ([docs](https://cursor.com/docs/context/mcp/install-links)); `vscode:mcp/install?<json>` (community format — test); `lmstudio://add_mcp?...` ([docs](https://lmstudio.ai/docs/app/mcp/deeplink); test `add_mcp` vs `add-mcp`) | **Ship now** | 0.5 day |
| MCP install — Claude Code, Codex | Same | `NSOpenPanel` pre-pointed at the config (`showsHiddenFiles`), merge via `files.user-selected.read-write`, keep a security-scoped bookmark (add `com.apple.security.files.bookmarks.app-scope`); also a copyable `claude mcp add --transport http …` | **Ship now** | 1 day |
| MCP install — Claude Desktop | Same | `.mcpb` Desktop Extension opened with `NSWorkspace` ([docs](https://www.anthropic.com/engineering/desktop-extensions)); needs a small stdio→HTTP proxy inside the bundle | Needs work | 1–2 days |
| Rewrite selected text | Reads the selection via Accessibility | `NSServices` "Rewrite with Whisperer" (`NSSendTypes`/`NSReturnTypes` string, `NSKeyEquivalent`, generous `NSTimeout`) + an App Intent for Shortcuts Quick Actions. Works in AppKit apps and Safari; Electron is inconsistent | **Needs work — safe** | 2–3 days |
| Browser meeting detection | Reads window titles via Accessibility | (1) existing per-process mic attribution + calendar meeting link + frontmost app — now; (2) bundled Safari Web Extension scoped to meet.google.com / teams.microsoft.com, `sendNativeMessage` → App Group ([docs](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)). Chrome native messaging fails from the sandbox; skip window titles (needs Screen Recording) | (1) Ship now, (2) Needs work | (1) 0.5 day, (2) 2–3 days |
| Correction learning | Reads the target app's field via Accessibility | Learn only from edits inside Whisperer (History, transcript editor) | Needs work | 1–2 days |
| Call audio (other participants) | Not gated; new on branch `worktree-agent-a5296f8ee5d1d87e2` | Core Audio process taps need no documented entitlement (`NSAudioCaptureUsageDescription` only). **Test the sandboxed AppStore build first.** Fallback: ScreenCaptureKit audio-only (works sandboxed, used on the store, broader Screen Recording prompt). Explain in review notes | Needs work (verify) | 0.5 day test; 2–3 days fallback |
| Command Mode | Voice → LLM → `/bin/zsh` | Free-form shell is a sandbox escape. Alternatives: App Intents + Shortcuts, or `NSUserUnixTask` for scripts the user places in `~/Library/Application Scripts/<bundle id>` | Not allowed as built | 2–4 days redesign |
| Automatic paste into other apps | Accessibility / `CGEvent.post` | None. Apple DTS: AX APIs "are not compatible with the App Sandbox" ([thread 820594](https://developer.apple.com/forums/thread/820594)); dictation apps rejected for this in 2026 ([WhisperPad](https://www.mitmllc.com/blog/apple-rejected-my-dictation-app/), [Whisper Notes](https://whispernotes.app/blog/why-whisper-notes-left-mac-app-store)); Input Methods can't ship on the MAS ([thread 134115](https://developer.apple.com/forums/thread/134115)). Best available: clipboard + ⌘V, restore the previous clipboard, optional "Insert last dictation" Service | Not allowed | — |
| Privacy Shield | Installs a Core Audio HAL plug-in (root) | AudioDriverKit is hardware-only ([WWDC21](https://developer.apple.com/videos/play/wwdc2021/10190/)) | Not allowed — direct build only | — |

## AI providers in the App Store build

Apple is not the blocker for any of these; the vendors are. Apple's requirement is
**5.1.2(i)**: disclose and get explicit permission before sharing personal data with a third-party
AI (per-provider consent sheet + privacy label/policy). 4.8 (login services) does not apply —
there is no Whisperer account.

| Provider | Verdict | Blocker | Next step |
|---|---|---|---|
| OpenAI / Anthropic / Gemini API keys | **Possible now** | — | Keep the consent sheet. Gemini free tier: Google may use content to improve products, and free tier is not allowed for EEA/UK/CH users ([terms](https://aistudio.google.com/docs/terms)) — disclose or require a paid key |
| ChatGPT plan (Sign in with ChatGPT) | After OpenAI approval | OpenAI: plan usage is documented for open-source/local apps; paid apps go through the [interest form](https://openai.com/form/sign-in-with-chatgpt-interest/) ("offered to a select group of commercial partners", ~16 at DevDay 2026-09-29) | Submit the form; ask in writing about the reported "no additional payment" clause (terms page unverified — 403). Meanwhile build the required branding (Continue with ChatGPT, one-time welcome, "Using ChatGPT plan · Manage usage") and error states (429 usage limit, 403 not eligible, refresh failure, 503) from `/siwc/ui-ux-guidelines` and `/errors-and-recovery`. Flip `ChatGPTAuth.isPreviewEnabled` only after written approval |
| Codex | After OpenAI approval; low value | Same approval (`codex app-server` + `ACCESS_TOKEN` sits under the same docs) | Technically: embed the signed binary with `app-sandbox` + `inherit`, `CODEX_HOME` in the container, disable its own Seatbelt/shell/updates. Adds nothing over the direct Responses call — skip unless OpenAI requires it |
| Claude plan | **Not possible** | Anthropic: "does not permit third-party developers to offer Claude.ai login… or to route requests through Free, Pro, Max… plan credentials" ([legal](https://code.claude.com/docs/en/legal-and-compliance)). No "Sign in with Claude" programme | App Store: Anthropic API key only. Direct build: launching the user's unmodified `claude` looks allowed under the same page. Written approval via Anthropic sales if wanted |
| Gemini plan (Antigravity) | **Not possible** | Google: third-party use of Gemini CLI OAuth "is a violation"; accounts were suspended Feb 2026 | API key only; treat even the direct-build `agy` adapter as high risk |

Never: temporary-exception entitlements (rejected for new MAS apps), reading `~/.codex/auth.json`
or `~/.claude` via a bookmark (impersonates another vendor's client; explicitly forbidden for Claude).

## Suggested order

1. Quick wins (≈2 days): ungate Dictation Polish + Feedback, MCP deep links + file-picker install,
   browser-call signals from mic attribution + calendar link.
2. Test call audio in the sandboxed AppStore build; merge the branch or switch to ScreenCaptureKit.
3. Services/App Intent rewrite.
4. OpenAI interest form now; ChatGPT branding and error states ready for the approval.
5. Safari Web Extension; in-app correction learning; `.mcpb` for Claude Desktop.

## Update 2026-11-06 — launching the user's own CLI (precedent research)

The question: is it allowed for Whisperer to launch the vendor CLI the user installed and signed in
to themselves (`claude -p`, `codex exec`, `agy -p`), never touching their credentials?

| Vendor | Direct-download build | App Store build | Evidence |
|---|---|---|---|
| Anthropic (Claude plan via `claude`) | **Allowed** — "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude subscription." Running Claude Code in a product may require accepting the Commercial Terms; binary must be unmodified; each user authenticates themselves | Not possible: a child process inherits the sandbox (Quinn, [thread 123873](https://developer.apple.com/forums/thread/123873)) and can't read `~/.claude` or Claude's Keychain item | [legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance), [support 15036540](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan) ("`claude -p`, and third-party app usage still draw from your subscription limits") |
| OpenAI (ChatGPT plan via `codex`) | **Grey, leaning allowed** for `codex exec` (local, not hosted). App-server auth "has never been permitted for commercial or hosted services". Safest: the Sign in with ChatGPT partner waitlist | After OpenAI approval only (Sign in with ChatGPT) | [app-server docs](https://learn.chatgpt.com/docs/app-server) |
| Google (Gemini plan via `agy`) | **Not allowed** — Antigravity terms §6: using third-party software to access the Service "is a breach… grounds for suspension". Gemini CLI consumer login ended 18 June 2026 | Not possible | [antigravity terms](https://antigravity.google/terms) |

Every enforcement action found (OpenCode/Cline Jan 2026, OpenClaw Apr 2026, Google Feb 2026) was
against **token reuse or client spoofing**, not against spawning the official binary. No report of a
user suspended only because another app ran the official CLI.

MCP sampling is not a route: the 2026-07-28 spec removed server-initiated sampling, and Claude Code /
Claude Desktop never supported it. The user-initiated route ("Claude, write notes for my last
meeting" → Whisperer's MCP tools) is allowed and works today, including in the App Store build.

A separately downloaded helper for the App Store build is a grey area under 4.2.3 and 2.4.5(iv); no
precedent found.

Safe-side rules for the CLI adapters (direct build): user installs and signs in to the CLI; Whisperer
never reads tokens, Keychain or auth files and never passes auth flags; never bundles or modifies the
binary; off by default with explicit opt-in and the disclosure "Runs the Claude Code installed on
your Mac; usage counts toward your plan's limits"; one run per meeting, no fan-out or background
loops; API key offered as the alternative; plain-text vendor names, no logos as feature names.
