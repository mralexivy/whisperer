---
name: xcode-debug-logs
description: >
  Retrieves and parses the latest Xcode debug session console output for Whisperer.
  Extracts warnings, errors, and Whisperer session blocks from the xcresult bundle.
  Use when debugging a specific run, checking what happened in the last session,
  or when the user says "show me the xcode logs", "debug session logs", "console output",
  "what happened last run", "check xcresult", or "latest session logs".
metadata:
  version: 2.0.0
  category: debug
  tags: [debug, xcode, logs, console, xcresult, session]
---

# xcode-debug-logs — Retrieve latest Xcode debug session logs

Whisperer's Xcode launch sessions store full console output in `.xcresult` bundles under DerivedData.
This skill finds the latest session, extracts its console log, and presents it in a structured form.

**Prefer the native Xcode MCP server (`xcode`) when it is connected; fall back to the xcresult procedure below only if it is not.**

## Xcode MCP (preferred)

Apple's `mcpbridge` exposes Xcode's live IDE state as MCP tools (`mcp__xcode__*`). Tools are deferred — load schemas with `ToolSearch` (`select:mcp__xcode__GetConsoleOutput,...`) before calling.

| Need | Tool |
|---|---|
| Find the open workspace (`tabIdentifier`/workspace id) | `XcodeListWorkspaces` (open it with `XcodeOpenWorkspace` if empty) |
| Console of running/last launch (regex filter supported) | `GetConsoleOutput` |
| Build errors/warnings | `BuildProject`, `GetBuildLog` |
| Per-file compiler diagnostics without building | `XcodeRefreshCodeIssuesInFile` |
| Run / stop the app | `RunProject`, `StopProject` |
| Scoped tests | `GetTestList`, `RunSomeTests` (never `RunAllTests` — see CLAUDE.md) |
| Live lldb | `InvokeDebuggerCommand` |
| Crash triage | `GetTopCrashIssues`, `GetCrashIssueLogs` |
| Apple API docs | `DocumentationSearch` |

Workflow: `XcodeListWorkspaces` (if it errors "agent isn't approved", call `XcodeOpenWorkspace` on `Whisperer.xcodeproj` — that triggers the approval) → `GetConsoleOutput` with a regex like `\[ERROR\]|\[WARN\]|Stall|FAIL` for the summary, then unfiltered for the tail. Then continue at Step 4 (rolling log) and Step 5 (summary) below.

**Limits — when the user pressed Run in Xcode themselves:**
- `GetConsoleOutput` only sees launches started via `RunProject`; a user-started run returns "No active launch session". Don't conclude there are no logs.
- The `.xcresult` for a run is only written when the run **ends**. While the app is still running, the newest bundle is the *previous* run (often empty: console is just the title `Run whisperer - Console`). Compare its timestamp with the run shown in Xcode before trusting it.
- **For a live/running session, read the rolling log (Step 4) — it holds the same Logger lines in real time.** Use `grep -E ' [EW] |Stall'` for errors/warnings (format: `+offset LEVEL cat ~ msg @file:line`) and `tail -40` for the latest activity.

### Setup / troubleshooting

Check first: `claude mcp list | grep xcode`. If missing or failing:

1. Xcode (27.x) > Settings > Intelligence > Model Context Protocol: enable **Allow external agents to use Xcode tools**. Xcode must be running with the Whisperer project open; the first call triggers an approval dialog in Xcode — accept it.
2. `xcrun mcpbridge` fails with `unable to find utility "mcpbridge"` when `xcode-select -p` points at `/Library/Developer/CommandLineTools`. Fix with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, or sidestep it by registering the absolute path:
   ```bash
   claude mcp add --scope user --transport stdio xcode \
     --env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
     -- /Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge
   ```
   (Put `--env` before `--`; `-e` is variadic and swallows the command name.)
3. Restart Claude Code after adding the server so the tools load.

## Fallback: xcresult procedure

## When to invoke

Trigger when the user mentions:
- "xcode logs" / "debug session logs" / "session logs"
- "console output" / "console log"
- "xcresult" / "latest run" / "last session"
- "what happened" / "check logs" / "show logs"
- Pasting a timestamp that matches a recent run

## Procedure

Run all steps as bash commands. Parse fast with Python inline scripts.

### Step 1 — Find the latest xcresult

`xcresulttool` fails with `unable to find utility` when `xcode-select -p` is CommandLineTools — prefix every `xcrun` call below with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XCRESULT=$(find ~/Library/Developer/Xcode/DerivedData/Whisperer-*/Logs/Launch \
  -name "*.xcresult" -type d 2>/dev/null | LC_ALL=C sort | tail -1)
echo "Session: $(basename "$XCRESULT")"
echo "Modified: $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "$XCRESULT" 2>/dev/null)"
```

If no xcresult is found, report "No Xcode debug sessions found" and stop.

### Step 2 — Extract console log (fast, single command)

```bash
xcrun xcresulttool get log \
  --path "$XCRESULT" --type console --compact 2>/dev/null \
  | python3 -c "
import json, sys, re

NOISE = re.compile(
    r'AddInstanceForFactory|'
    r'\[plugin\]|'
    r'nw_protocol|'
    r'NSWindow warning|'
    r'CoreText|'
    r'fontd\[|'
    r'HIToolbox|'
    r'WARNING: Secure coding|'
    r'_UIConstraintBasedLayout|'
    r'_TtGCs23_ContiguousArrayStorage'
)

def collect(node, out):
    if isinstance(node, str):
        s = node.strip()
        if s and not NOISE.search(s):
            out.append(s)
    elif isinstance(node, dict):
        for v in node.values():
            collect(v, out)
    elif isinstance(node, list):
        for item in node:
            collect(item, out)

data = json.load(sys.stdin)
all_lines = []
collect(data, all_lines)

# De-duplicate: prefer Whisperer packed-log lines (start with '[YYYY')
# over the raw console lines for the same message.
seen_content = set()
deduped = []
for line in all_lines:
    m = re.match(r'\[[\d-]+ [\d:.]+\] \[\w+\] \[\w+\] \[[\w.]+:\d+\] (.+)', line)
    if m:
        key = m.group(1).strip()[:100]
        if key not in seen_content:
            seen_content.add(key)
            deduped.append(line)
    else:
        payload = re.sub(r'^\d{4}-\d{2}-\d{2} [\d:.]+[+-]\d{4} \w+\[\d+:\d+\] \[\w+\] ', '', line).strip()[:100]
        if payload not in seen_content:
            seen_content.add(payload)
            deduped.append(line)

errors   = [l for l in deduped if re.search(r'\[ERROR\]|\[CRITICAL\]|FAIL|fatal|crash|exception|Stall', l, re.I)]
warnings = [l for l in deduped if re.search(r'\[WARN\]', l) and l not in errors]

print(f'=== ERRORS & CRITICAL ({len(errors)}) ===')
for l in errors[-30:]:
    print(l)

print(f'\n=== WARNINGS ({len(warnings)}) ===')
for l in warnings[-20:]:
    print(l)

print(f'\n--- Total lines: {len(all_lines)} -> de-duped: {len(deduped)} ---')
"
```

### Step 3 — Show last 60 Whisperer log lines (chronological tail)

```bash
xcrun xcresulttool get log \
  --path "$XCRESULT" --type console --compact 2>/dev/null \
  | python3 -c "
import json, sys, re

NOISE = re.compile(r'AddInstanceForFactory|\[plugin\]|nw_protocol|NSWindow|CoreText|fontd\[|HIToolbox|WARNING: Secure|_UIConstraint')

def collect(node, out):
    if isinstance(node, str):
        s = node.strip()
        if s and not NOISE.search(s) and s.startswith('[20'):
            out.append(s)
    elif isinstance(node, dict):
        for v in node.values(): collect(v, out)
    elif isinstance(node, list):
        for item in node: collect(item, out)

data = json.load(sys.stdin)
lines = []
collect(data, lines)
print(f'--- Whisperer log lines (last 60 of {len(lines)}) ---')
for l in lines[-60:]:
    print(l)
"
```

### Step 4 — Check the rolling log for packed session blocks

```bash
LOG=~/Library/Logs/Whisperer/whisperer-$(date +%Y-%m-%d).log
if [ -f "$LOG" ]; then
    python3 -c "
import sys, re
raw = open('$LOG').read()
lines = raw.split('\n')
legend = [l for l in lines if l.startswith('#')]
blocks = []
start = None
for i, l in enumerate(lines):
    if l.startswith('>ses '):
        start = i
    elif l.startswith('<ses ') and start is not None:
        blocks.append((start, i, 'FAIL' in l))
        start = None

print('LEGEND:', ' | '.join(legend[:6]))
print(f'Total sessions today: {len(blocks)}')
sorted_b = sorted(blocks, key=lambda x: (not x[2], -x[0]))[:5]
sorted_b.sort(key=lambda x: x[0])
for s, e, fail in sorted_b:
    print()
    print('\n'.join(lines[s:e+1]))
" 2>/dev/null
else
    echo "(No rolling log for today)"
fi
```

### Step 5 — Summarise

After running the commands, produce this structured output:

```
## Debug Session: <xcresult filename>
**Started:** <timestamp from filename>

**Errors/Critical (N):**
<list>

**Warnings (N):**
<list>

**Session blocks (N total, FAIL first):**
<>ses ... <ses blocks>

**Last 20 log lines:**
<chronological tail>

**Root cause / key observations:**
<evidence-backed conclusions>
```

## Notes

- The xcresult path changes on every Xcode run — always re-resolve with `find`.
- `xcresulttool get log --type console` returns all stdout/stderr captured by Xcode debugger.
- De-duplication is necessary: Whisperer's Logger writes to both `os_log` (raw line) and its own file (`[YYYY-MM-DD...]` line) — both appear in the console capture.
- Session blocks (`>ses`/`<ses`) only appear in the rolling log, not in the console output.
- The rolling log format is packed `k=v` — see `docs/references/log-format.md` for legend.
- For a stall/stuck-state dump, use the `stuck-dump-analyze` skill instead.
- If `xcresulttool` returns empty, fall back to: `log show --last 4h --predicate 'subsystem BEGINSWITH "com.ivy.whisperer"' --style compact`
