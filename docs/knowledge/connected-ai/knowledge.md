# Connected AI — knowledge

Facts established while building meeting notes / Ask AI on the user's own AI subscription
(2026-11-06). Plan: [connected-ai-providers.md](../../exec-plans/connected-ai-providers.md).

## CLI adapters (verified by real runs on this Mac)

- **Claude Code 2.1.308** — `claude -p --output-format json --json-schema '<schema>' --tools ""
  --strict-mcp-config --no-session-persistence --disable-slash-commands --system-prompt '…'`
  with the transcript on stdin returned schema-valid JSON in `structured_output` in ~5 s on a
  two-line transcript (signed in with `authMethod: claude.ai`, i.e. the subscription).
  - With `--json-schema`, the schema output is a *tool call*: in `stream-json` mode the
    deltas arrive as `input_json_delta.partial_json`, not `text_delta`. A parser that only
    reads `text` never sees the title stream. `stop_reason` is `tool_use`.
  - `--bare` skips keychain reads — it would break subscription auth. Do not use it.
  - `claude auth status --json` → `{"loggedIn": bool, "authMethod": "claude.ai" | …}`.
  - Even a two-line prompt costs ~1.85k cache-creation tokens (Claude Code's own system
    scaffolding survives `--system-prompt`).
- **Codex** — the ChatGPT desktop app bundles it at
  `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (0.166.0-alpha.5.1 here);
  nothing is on PATH. `codex login status` → `Logged in using ChatGPT`.
  - `codex exec --skip-git-repo-check --sandbox read-only --ephemeral --ignore-user-config
    --ignore-rules --color never --output-schema schema.json -o out.txt "<prompt>"` with the
    transcript piped: stdin is appended to the prompt as a `<stdin>` block. ~4.5 s, schema-valid.
  - `--ignore-user-config` skips `config.toml` (so no user MCP servers start, including
    Whisperer's own) while auth still comes from `CODEX_HOME`.
  - ~15k tokens for a trivial request — Codex's agent scaffolding dominates small prompts.
- **Why Codex failed to connect to Whisperer's MCP server.** The installer wrote `headers =`
  under `[mcp_servers.whisperer]`; the real key is `http_headers`. Codex's schema type is
  `deny_unknown_fields`, but codex 0.166 *silently drops* the unknown key rather than rejecting
  the file (verified against a throwaway `CODEX_HOME`), so Codex connected with no
  `Authorization` header and the always-on token check answered 401. Other Codex versions may
  reject the whole `config.toml` instead — either way, write only documented keys.

## Whisperer's MCP server with real clients (verified 2026-11-06)

- Claude Code 2.1.308 (`claude -p --mcp-config <the Snippet button's JSON> --strict-mcp-config`)
  and Codex 0.166 (`codex exec -c mcp_servers.whisperer.…`) both connect and call
  `list_meetings`, with and without the token (`MCPClientInteropTests`, opt-in live half).
  The MCP Swift SDK client passes in streaming and plain-JSON modes in every run.
- **`codex exec` refuses MCP tool calls by default**: "Tool call requires approval, but approval
  policy is set to never". The Codex snippet therefore carries
  `default_tools_approval_mode = "approve"` (values: auto, prompt, writes, approve), and every
  Whisperer tool declares `readOnlyHint: true`. `codex mcp add` can set neither the approval
  mode nor a static token, so the Codex card offers the TOML only.
- `auth.openai.com/api/accounts/authorize` sits behind a Cloudflare browser challenge (403 to
  curl), so the ChatGPT sign-in can only be exercised from a real browser.

## ChatGPT plan route (verified live 2026-11-06)

- Authorize `https://auth.openai.com/api/accounts/authorize`, token
  `https://auth.openai.com/api/accounts/oauth/token`, loopback redirect on `127.0.0.1`
  (never `localhost`), dynamic registration via `client_id=dynamic_agent_client`.
- Responses requests must be `store:false, stream:true`; `temperature`, `max_output_tokens`,
  `top_p`, `previous_response_id` and a `role:"system"` item are rejected.
- Live: the loopback PKCE flow with dynamic registration signed in and granted
  `chatgpt.tokens.use.direct`; `/v1/models` listed `gpt-5.6-*`, `gpt-6-*`, `gpt-6.1-*` slugs; the
  Responses plan route returned schema-valid notes (en + he, 6–7 s) and a cited Ask AI answer.
- Commercial apps need OpenAI's approval; the flow is DEBUG-only / behind
  `connectedAI.enableChatGPTPreview` until then.

## Test-host notes

- An `NSHostingView` / `ImageRenderer` of a SwiftUI page renders fine in the unit-test host,
  which is enough to catch layout crashes in settings UI without a UI-test target.
- `CLIProcessRunner` is testable with `#!/bin/sh` scripts in the temp dir: stdin round
  trip, 2 MB stdin (pipe-buffer deadlock), timeout, cancellation-kill and output cap.

## MCP meeting tools for agents (2026-11-06)

- `get_meeting` used to return every segment as pretty-printed JSON — a 2,000-line meeting is
  ~300k characters (~75k tokens) in one tool result. It now returns summary, notes, outline and
  transcript size only; `get_meeting_transcript` pages compact `[mm:ss] Speaker: text` lines
  (12k chars default, cursor, time window, speaker); `search_meetings` returns snippets.
- `list_meetings` used to `JSONSerialization`-parse every meeting's transcript just to count
  segments. Counts now come from a substring scan; nothing is decoded for a list.
- Notes written by AI apps (`add_meeting_note`) carry `author`; AI apps can change only notes
  with an author, never the user's. During a live recording the `MeetingSession` owns notes in
  memory and saves the whole array, so MCP writes go through the session
  (`MeetingNotesService`), otherwise through an atomic Core Data read-modify-write.
- Verified live: Claude Code (`--allowedTools mcp__whisperer__get_meeting,mcp__whisperer__add_meeting_note`)
  read the newest meeting and added a note authored "Claude", which Ask AI's context then contained.
