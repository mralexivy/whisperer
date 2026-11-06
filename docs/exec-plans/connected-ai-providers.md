# Connected AI — meeting notes and Ask AI on the user's own AI subscription

Status: **implemented, unreleased** (2026-11-06). Code in `Whisperer/Meetings/Intelligence/`;
tests in `WhispererTests/ConnectedAI*.swift`; findings in
[docs/knowledge/connected-ai/](../knowledge/connected-ai/knowledge.md).

### Implementation status (2026-11-06)

| Piece | State |
|---|---|
| `MeetingIntelligenceProvider` contract, `MeetingNotesSchema` (strict-mode JSON schema, lenient decode, streamed title) | Done, tested |
| Router + `ConnectedAIStore` (local default, per-provider consent, keep-local switch, Keychain keys, readiness, fallback notice) | Done, tested |
| `MeetingAIService`: connected-first for notes and Ask AI, local ladder untouched as fallback, provenance | Done, tested with fake providers |
| Claude Code adapter (`claude -p --json-schema`, stream-json title) | Done, **verified live** on claude 2.1.308 (subscription sign-in) |
| Codex adapter (`codex exec --output-schema`, incl. the copy bundled in ChatGPT.app) | Done, **verified live** on codex 0.166 (ChatGPT plan) |
| Antigravity adapter (`agy -p`, pty retry) | Done, **unverified** — agy not installed; marked Preview |
| OpenAI / Anthropic / Gemini API-key providers (SSE) | Done, tested against a URLProtocol stub |
| ChatGPT OAuth (PKCE, loopback, dynamic registration, rotating refresh) + plan-route Responses | Done, **verified live on a real ChatGPT plan**; **DEBUG-only until OpenAI approves commercial use** (`connectedAI.enableChatGPTPreview` in release) |
| Workspace → Connected AI page, Settings summary card, consent sheet, key sheet, Ask AI "answers by" chip + streaming, overview provenance pill + Regenerate-with menu, fallback banner | Done; layout/render tests in the unit-test host |
| Settings interaction tests (`ConnectedAISettingsInteractionTests`): every button path through `ConnectedAIPageController`, consent gating, sheets, render in every provider state | Done |
| MCP (outside this plan, same change): optional token on loopback, `/mcp` streamable HTTP + JSON mode + sessionless, legacy `/sse`, `/health`, client catalog with snippets, Codex fix (`http_headers`, `default_tools_approval_mode`), read-only tool annotations | Done; **verified live** with Claude Code and Codex as MCP clients (with and without token) and the MCP Swift SDK client |
| Workspace **LLM** page (replaces "Connected AI"): one list — On this Mac, subscriptions (signed-in first), API keys — with consent / sign-in / key entry unfolding inline, a manage panel on the row in use, dictation polish (local LLM) and privacy on the same page | Done; click-tested (`LLMPageClickTests`) — the tests caught a stroke overlay that swallowed every row click |
| Transcript polish with the chosen AI (`MeetingTranscriptPolisher`): chunked, per-card acceptance guard (length, script), original kept in `rawText`, undo, "Polished by …" | Done; **verified live** with Claude Code and Codex (English + Hebrew, fillers out, ids kept) |
| Meeting UI says which AI did what: provider marks on the overview, Ask AI chip / placeholder / per-answer "via", polish bar, meeting list rows | Done |
| MCP page redesign: one flow (turn on → pick app → one button → auto-test), installed apps first, Advanced collapsed | Done; click-tested (`MCPConnectPageClickTests`) |
| Vendor go/no-go for shipping CLI adapters commercially (Anthropic, Google) | **Open** — business step, not code |
| ChatGPT sign-in against a real account | **Verified live** 2026-11-06: browser sign-in in the Debug app, plan usage granted; English + Hebrew notes (6–7 s) and Ask AI through the plan route (`testChatGPTPlan`) |
| Click-level settings tests (`ConnectedAISettingsClickTests`): real mouse events through `NSWindow.sendEvent` on the hosted page — chooser chips, consent Allow/Cancel, keep-local switch, card buttons, key sheet | Done |
| VS Code accepts the generated entry (`code --add-mcp` into a throwaway profile writes exactly our `servers.whisperer {type: http, url}`) | Verified |
| Antigravity CLI; Cursor / Windsurf; VS Code / Inspector as *connecting* MCP clients | **Open** — agy, Cursor and Windsurf are not installed; the editor clients cannot be driven headlessly; running the MCP Inspector via `npx` needs permission |

## Goal

When a user connects an AI they already pay for, Whisperer uses it, **inside the app**, for:

1. **Meeting notes**: title, overview, topics, decisions, open questions, next meeting, action
   items. Generated automatically after a meeting stops, and on Regenerate.
2. **Ask AI**: questions about a meeting in the Meeting Studio assistant panel.

The user never leaves Whisperer. Recording, ASR, transcript refinement and storage stay local.
The local Qwen model stays the default and the offline fallback.

**Out of scope for this plan**:
- **MCP.** The existing server already serves "the assistant calls Whisperer". This plan is the
  opposite direction and touches no MCP code.
- **Dictation polish, Rewrite and Command Mode.** They keep using the local model. The provider
  seam built here can be reused for them later, but no UI exposes it.

## Integration options (checked 2026-11-06)

| Provider | How Whisperer calls it | Subscription | Build | Status |
|---|---|---|---|---|
| **Codex CLI** (ChatGPT plan) | `codex exec` (one-shot) or `codex app-server` (JSON-RPC over stdio, persistent) | Yes, eligible ChatGPT plans, via the user's own `codex login` | Direct download only | Phase 1 PoC |
| **Claude Code** (Pro/Max) | `claude -p --output-format json\|stream-json --json-schema …` | Draws on plan limits when the user is signed in to their own binary | Direct download only | Phase 1 PoC; **commercial terms must be cleared before release** |
| **Antigravity CLI** (Google AI Pro/Ultra) | `agy -p` / `agy acp` | Yes, via the user's own Google sign-in | Direct download only | Phase 1 PoC; terms must be cleared |
| **ChatGPT** | Sign in with ChatGPT OAuth → Responses API | Yes, Go/Plus/Pro | **Both builds** | Phase 2; release needs OpenAI commercial approval |
| OpenAI / Anthropic / Google API key | HTTPS | Separately billed, or plan API credits | Both builds | Phase 3 |
| Local MLX (Qwen3.5-4B MTP) | in-process | none | Both builds | Exists; stays the default |

**Why the CLIs are direct-download only:**
- The App Store build is sandboxed (`ENABLE_APP_SANDBOX = YES`). A child process inherits the
  sandbox, so it cannot read `~/.codex`, `~/.claude` or the agy keyring, and cannot find a
  binary in `/opt/homebrew/bin`.
- Every existing `Process` use is already `#if !APP_STORE`.
- So in the App Store build the subscription path is ChatGPT OAuth only.

**The legal line, which no PoC result changes:**
- **What Whisperer never does:** read, copy or forward another vendor's subscription tokens.
- **What Whisperer only does:** launch the *unmodified, user-installed, user-authenticated*
  binary.
- Anthropic separates end-user use of its own binary from third-party routing of subscription
  traffic. It says third-party products may not offer claude.ai login or use its rate limits
  without prior approval.
- Google's terms prohibit piggybacking on its authentication.
- So each CLI adapter ships only after a written go/no-go per vendor (Phase 1 exit). OpenAI's
  Codex is the most likely to clear, because Codex app-server is documented as an integration
  surface.

### CLI facts the PoC must confirm (from docs and secondary sources; unverified on our machines)

- **Codex**:
  - `codex exec` is read-only sandbox by default. `--json` emits JSONL events.
    `--output-schema <file>` constrains the final message, and `-o <file>` writes it.
  - `--skip-git-repo-check` is needed outside a repo. A prompt piped on stdin works.
  - `codex app-server` speaks JSON-RPC over stdio and keeps thread history locally.
- **Claude Code**:
  - `-p` with `--output-format json` puts schema output in `structured_output`.
  - `--json-schema` validates the final output and retries on mismatch.
  - `stream-json` needs `--verbose`; `--include-partial-messages` gives token deltas.
  - Still to verify: the flag that disables all tools, and the one that turns off session
    persistence.
- **Antigravity**:
  - `agy -p` with `--output-format json|stream-json` and `--json-schema`.
  - **`agy -p` reportedly prints nothing when stdout is not a TTY**, so it may need a pty.
  - `agy acp` is an Agent Client Protocol server over stdio. Its sandbox and tool-disable
    semantics are undocumented.

## What exists today that this builds on

- `MeetingAIService` (`actor`, `Whisperer/Meetings/MeetingAIService.swift:44`):
  - **Notes**: `generateOverview(segments:meetingID:)` (`:275`) runs a rung ladder.
    - Rung 0 is the line-format prompt.
    - Rung 1 is the same with `assistantPrefill`.
    - Rung 2 is a narrow prose prompt.
    - Rung 3 is an extractive floor with no LLM.
    - Map-reduce runs for long meetings (`:347-404`).
  - **Ask**: `ask(question:meetingID:segments:)` (`:127`) puts the whole transcript in the
    system prompt, prefilters with BM25 for long transcripts, and parses `[Ns]` citations with
    `parseCitations` (`:894`).
  - Both get the LLM from `acquireLLM()` (`:88`), which is `MeetingEngines.borrowLLM()`.
- **Output type**: `MeetingAISummary` (`MeetingSegment.swift:159`) is `Codable` **with a lenient
  decoder**: fields that are missing or malformed decode to empty.
  - The title lives on `MeetingRecord.title`, guarded by `titleIsUserSet` (`MeetingRecord.swift:36`).
  - `MeetingOverviewParser.parse` (`:111`) turns local line-format output into
    `MeetingAISummary`.
  - `StreamingTitleWatcher` applies the title mid-stream.
- **Callers**:
  - `MeetingJobQueue.swift:336,357`: the post-stop pipeline, which checks cancellation only
    between stages.
  - `MeetingOverviewView.swift:444` (Regenerate) and `MeetingAssistantPanel.swift:425` (Ask).
- **No Keychain, no OAuth, no inference HTTP client, no cloud-consent concept.** The App Store
  build already has `network.client` + `network.server`, which covers the HTTPS client and a
  `127.0.0.1` OAuth callback.

## Decisions

1. **The provider interface is task-level, not chat-level.** The CLIs are agents, not
   completion endpoints, and the two meeting operations are all we need. A
   `MeetingIntelligenceProvider` exposes `generateNotes` and `ask`, not a generic `complete()`.
2. **One output contract, `MeetingNotes`**: `title` + the existing `MeetingAISummary`.
   - Cloud providers return **JSON** constrained by one schema (`MeetingNotesSchema.json`,
     generated from the Swift types and checked into Resources).
   - Every provider decodes it with the existing lenient decoder.
   - The local provider keeps its line format + `MeetingOverviewParser` (tuned for Qwen 4B) and
     maps the result into the same `MeetingNotes`. Every consumer downstream sees one type.
3. **`title` is the first field in the schema.** On a streaming provider, a tolerant
   partial-JSON scan lifts the title as soon as `"title": "…"` closes. This keeps today's early
   title for the cloud path. Non-streaming providers set the title when the result arrives.
4. **A user-set title is never overwritten**, whatever the provider (`titleIsUserSet`).
5. **The transcript goes in as text with `[Ns]` timestamps.** It is piped on stdin or put in the
   request body, never written to a file the CLI can wander around. Audio never leaves the Mac.
6. **No map-reduce on cloud providers.** Their context windows hold multi-hour meetings. If a
   transcript exceeds `capabilities.contextTokens`, fall back to the existing BM25 evidence
   selection, not to splitting.
7. **Local stays the default.** Connecting a provider does not change where meetings go. The
   user picks **Meeting AI: On this Mac / <provider>** and consents once per provider.
8. **Failure never loses notes.** On any provider error, fall back to local if it is ready,
   otherwise to the extractive rung. Show one non-modal status line. Stamp provenance either way.

## Architecture

```
Whisperer/Meetings/Intelligence/            (synchronized group; no pbxproj edit)
  MeetingIntelligenceProvider.swift         protocol, MeetingNotes, AskRequest/AskEvent, errors, capabilities
  MeetingIntelligenceRouter.swift           @MainActor: selected provider, consent, readiness, fallback
  MeetingNotesSchema.swift                  JSON schema (+ Resources/MeetingNotesSchema.json), partial-title scanner
  MeetingPrompts.swift                      cloud prompts for notes and ask (local prompts stay where they are)
  Providers/
    LocalMeetingProvider.swift              wraps today's MeetingAIService ladder; no behavior change
    CLI/
      CLIProcessRunner.swift                Process + pipes (+ pty for agy), env scrub, temp cwd, timeout, kill
      CLIDiscovery.swift                    finds binaries, version, signed-in probe
      CodexProvider.swift                   exec first; app-server if the PoC says it pays off
      ClaudeCodeProvider.swift
      AntigravityProvider.swift
    ChatGPTOAuthProvider.swift              Phase 2
    APIKeyProviders.swift                   Phase 3: OpenAI, Anthropic, Gemini
  Auth/
    KeychainStore.swift                     Phase 2
    ChatGPTOAuth.swift                      Phase 2
  UI/
    ConnectedAIPageView.swift
    ProviderCardView.swift
    CloudConsentSheet.swift
```

### Contract

```swift
nonisolated struct MeetingNotes: Codable, Sendable {
    var title: String?
    var summary: MeetingAISummary
}

nonisolated struct MeetingTranscriptInput: Sendable {
    var text: String              // "[123s] Speaker: …" lines
    var languageHint: String?     // notes in the meeting's language
    var durationSeconds: Int
}

nonisolated enum AskEvent: Sendable { case delta(String), done(answer: String) }

protocol MeetingIntelligenceProvider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }   // streaming, contextTokens, isLocal, isSubscription
    func readiness() async -> ProviderReadiness      // .ready / .notInstalled / .notSignedIn / .quotaExhausted(until:) / .unavailable(String)
    func generateNotes(_ input: MeetingTranscriptInput,
                       onTitle: @Sendable (String) -> Void) async throws -> MeetingNotes
    func ask(question: String, transcript: MeetingTranscriptInput,
             history: [MeetingChatTurn]) -> AsyncThrowingStream<AskEvent, Error>
}
```

- `MeetingAIService.generateOverview` / `ask` keep their signatures. Inside, they ask the router
  for a provider. Local → today's code path, unchanged. Otherwise → provider, then fallback.
  Callers (`MeetingJobQueue`, `MeetingOverviewView`, `MeetingAssistantPanel`) do not change.
- **Cancellation is structured:**
  - Cancelling the job or panel task terminates the child process (SIGTERM, then SIGKILL after
    2 s) or cancels the `URLSession` task.
  - This gives cloud paths mid-generation cancel, which local still lacks.
  - Optional: fix local too, by checking `Task.isCancelled` in the MTP `onToken` path.
- **Ask citations**: the cloud prompt asks for `[Ns]`, and `parseCitations` stays as is. Answers
  are free text, not JSON, so they can stream into the panel. Add delta rendering to
  `MeetingAssistantPanel`, which shows only the final answer today.
- **Errors**: `.notInstalled`, `.notSignedIn`, `.consentRequired`, `.quotaExhausted(retryAfter:)`,
  `.rateLimited(retryAfter:)`, `.timeout`, `.schemaMismatch(raw:)`, `.processFailed(exit:, stderrTail:)`,
  `.offline`. stderr is logged only after redaction.

### CLI process safety (applies to every CLI adapter)

These CLIs are coding agents. Whisperer uses them as text-in, JSON-out functions, so everything
agentic gets turned off:

- **Working directory**: a fresh empty temp dir per call, deleted afterwards. Never `$HOME` or
  the meetings store.
- **Tools off / read-only**: Codex `--sandbox read-only`, Claude tools disabled (flag confirmed in
  the PoC), and the agy equivalent. If a CLI cannot run with tools off, it does not ship.
- **No inherited MCP servers**: the user's own `~/.claude.json` / `~/.codex/config.toml` may
  include *Whisperer's own MCP server* (our installer writes it), plus others. The PoC checks the
  per-CLI flag to ignore user MCP config, since a loop back into Whisperer is the case to avoid.
- **Input**: the prompt and transcript go in on stdin, with no transcript in argv (argv is visible
  in `ps`). The schema is a file in the temp dir.
- **Environment**: pass `PATH`, `HOME`, `LANG` and the vendor's own auth variables only. Never
  pass our secrets.
- **Binary resolution**: an explicit search of `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`,
  npm global bin and `~/.bun/bin`, plus a user override path. Record the resolved path + `--version`
  per call for diagnostics. Never run through a shell.
- **Limits**: a wall-clock timeout scaled by transcript length, an output byte cap, and one
  call in flight per provider.
- **Signed-in probe**: run each CLI's status/whoami command, or a 1-token dry prompt, only when
  the user opens the page or presses Test. Never at launch.
- All `#if !APP_STORE`. Run `app-store-check` on the diff.

## Workspace UI: Settings → Connected AI

A new sidebar item **Connected AI** (`HistorySidebarItem.connectedAI`, after AI Modes), plus a
one-line summary row in Settings that links to it. Use `SettingsCard` / `SettingsSectionHeader`
and run `design-check`.

1. **Meeting AI** picker at the top: *On this Mac (offline)* · each **ready** provider. Under it,
   one line saying what this changes: "Meeting notes and Ask AI use <provider>. Dictation stays
   on this Mac."
2. **Provider cards**:
   - Codex · Claude Code · Antigravity (direct build).
     - States: *Not installed*, with a link to install docs; *Installed, not signed in*, showing
       the exact command to run in Terminal (Whisperer does not run the login for them);
       *Ready* (plan / account if the CLI reports it); *Quota reached until …*
     - **Test** button.
   - ChatGPT (both builds): **Continue with ChatGPT** opens the browser, then shows the account,
     whether plan usage was granted, and Disconnect.
   - API keys (Phase 3): paste the key, Test, Remove.
3. **Privacy**:
   - First selection of a provider opens `CloudConsentSheet`. It states that the meeting
     transcript text and your questions go to <provider> under your account, that audio never
     does, and links the provider's data policy.
   - Consent is stored per provider.
   - A **Keep all meeting AI on this Mac** switch overrides the picker.
4. **In the meeting itself**:
   - A provenance pill on the overview: "Notes by Claude · 2m ago".
   - Regenerate gets a provider menu, for a one-off run on another provider.
   - The Ask panel header shows which AI answers.

Copy: onboarding and marketing change "100% Offline" / "nothing leaves your Mac" to "Offline by
default" wording (`OnboardingView.swift:349,358,468,478-480`, `WhispererApp.swift:4635,4888`).

## Phases

### Phase 1: CLI proof of concept, then production adapters (direct-download build)

**1a. PoC (a DEBUG-only harness plus a scoped test suite, `ConnectedAICLIPoCTests`, opt-in and
skipped when a CLI is missing).** For Codex (exec and app-server), Claude Code and Antigravity
(`-p`, and `acp` if `-p` cannot run headless):

- Detect and probe sign-in. Run notes on the benchmark meetings: 3 lengths (5 / 30 / 90 min) × 2
  languages (English, Hebrew).
- Record:
  - time to first title and total latency,
  - whether the output passes the schema without a retry,
  - quality against the local model, scored side by side by the owner,
  - the token or quota usage the CLI reports,
  - cold-start cost, for a persistent protocol vs one process per call.
- Confirm each process-safety flag above actually holds:
  - With tools off, ask the agent to list the cwd → it must refuse or fail.
  - With Whisperer's MCP server running and configured in the CLI, the CLI must not call it.
- Write results to `docs/knowledge/meetings/` (knowledge + hypotheses).

**PoC exit, per CLI (all must hold):**
1. Tools can be fully disabled.
2. Schema output is reliable (≥ 95% first-try across the matrix).
3. A quota or not-signed-in error is distinguishable from other failures.
4. Total latency is acceptable for a background job (target ≤ 60 s for a 30-minute meeting).
5. **Commercial terms are cleared in writing by the vendor.** Until then it stays behind a DEBUG
   flag.

**1b. Production adapters** for the CLIs that pass:
- `MeetingIntelligenceRouter` and the `LocalMeetingProvider` wrap, with no behavior change for
  local users.
- The Connected AI page (CLI cards + picker + consent), provenance, fallback, streaming Ask, and
  the copy changes.

**Acceptance:**
- Local-only users see identical behavior: the existing scoped meeting suites pass, but not the
  slow `MeetingPolishTests` / `MeetingOverviewMapReduceTests` unless opted in.
- New tests:
  - `MeetingIntelligenceRouterTests`: fallback on each error kind, and consent gating, which
    asserts zero process launches before consent.
  - `CLIProcessRunnerTests`: a fake CLI script for timeout, kill, output cap, stderr redaction
    and env scrub.
  - `MeetingNotesSchemaTests`: lenient decode, plus the partial-title scan on chunked input.
- Cancelling a meeting job kills the child within 2 s.
- A user-set title is never touched.

### Phase 2: ChatGPT OAuth (both builds)

- **Business**: apply now for OpenAI's Sign in with ChatGPT commercial trial. Building can start
  in DEBUG immediately; release waits for approval.
- `KeychainStore`: generic password, `AfterFirstUnlockThisDeviceOnly`, no iCloud sync.
- `ChatGPTOAuth`:
  - Flow:
    - PKCE S256.
    - A `NWListener` on `127.0.0.1:<ephemeral>/auth/callback`, started before the browser
      opens; `localhost` is not allowed.
    - Dynamic client registration (`dynamic_agent_client` → saved `oaiapp_…`).
    - Scopes `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`,
      resource `https://api.openai.com/v1`.
    - **Verify the granted scopes include plan usage.**
  - Rotating refresh token, written atomically (access + expiry + scopes + refresh in one item).
  - Refresh at 80% of expiry, with a single in-flight refresh.
- `ChatGPTOAuthProvider`, Responses API:
  - Request shape: `store:false`, `stream:true`, the system prompt in `instructions`, full
    history in `input` each call.
  - **Must not** send `temperature`, `top_p`, `max_output_tokens`, `truncation`, `metadata`,
    `user` or `previous_response_id`.
  - Structured notes go through the Responses `text.format` JSON schema, if the plan route accepts
    it (verify). Otherwise use a prompt-level schema + lenient decode.
- **Acceptance**:
  - Sign-in, sign-out, a declined plan scope, and expiry mid-meeting each end in the right state.
  - A revoked token → "Sign-in expired" + local fallback.
  - An encoder test asserts that no unsupported field is ever serialized.

### Phase 3: API keys (both builds)

- OpenAI (Responses + `json_schema`), Anthropic (Messages + a tool-use or JSON schema, with
  `cache_control` on the transcript for repeat Ask turns), and Gemini (`responseSchema`).
- They share the Keychain, the `SSEStreamParser` (`nonisolated`, unit-tested on split frames and
  multibyte UTF-8) and the error mapping.
- Mention in copy that Claude Max / Ultra and some ChatGPT plans include monthly API credits a key
  can draw on.
- **Acceptance**: `URLProtocol`-stubbed tests per provider (stream, 401, 429 + retry-after, cancel,
  context too long), and opt-in live smoke tests per provider.

## Risks

- **A vendor says no to the CLI route.** Then only the ChatGPT OAuth and API-key paths remain;
  the architecture does not change. That is why the PoC is cheap and the go/no-go is per vendor.
- **CLIs change flags or output.** Pin a minimum version per adapter and parse defensively. If the
  probe sees an unknown version, show *"Untested version — may not work"* instead of failing
  silently.
- **App Store review**: the CLI code is compiled out. The App Store build needs a privacy label
  update for the OAuth and API paths, plus review notes that cloud use is opt-in.
- **Secrets in logs**: run a `Logger` redaction pass for `Authorization`, `sk-…` and `oaiapp_…`,
  and add the check to `conventions-check`.
- **Prompt drift across models**: one cloud prompt, schema-constrained, and a lenient decoder. A
  per-provider prompt variant only if the PoC shows it is needed.

## Open questions for the owner

1. Apply to OpenAI's commercial trial now? It gates Phase 2's release, not its build.
2. Who contacts Anthropic and Google for written clearance of the CLI route, and should Phase 1b
   wait for it or ship Codex alone first?
3. Should Regenerate's one-off provider menu ship in Phase 1b, or is the global picker enough?
