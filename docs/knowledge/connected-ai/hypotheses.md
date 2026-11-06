# Connected AI — hypotheses

- **`agy -p` needs a pty.** Secondary sources say it prints nothing when stdout is not a
  terminal; `AntigravityProvider` retries an empty success under `script -q /dev/null`.
  Unverified — `agy` was not installed. Test: run the adapter's `Test` button with agy present.
- **Responses `text.format: json_schema` on the ChatGPT plan route.** Not in the documented
  unsupported list, so it is sent; a 400 retries with the schema inline. Confirm on a live
  plan-usage token.
- **CLI scaffolding cost dominates short meetings** (1.85k tokens for Claude, 15k for Codex on
  a two-line transcript). For a 60-minute meeting (~12k tokens) it should be noise; measure on
  real meetings before tuning prompts per provider.
- **Frontier models need no map-reduce.** The connected path sends the whole timestamped
  transcript (with speakers) up to 400k chars. Check quality vs. the local ladder on the
  benchmark meetings (he/en/ru, 5/30/90 min).
