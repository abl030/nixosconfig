# Claude usage-limit ledger

**Date:** 2026-10-17 · **Status:** active · **Revisit:** once ~4 weeks of ledger data exist, or if Claude Code changes the status-line `rate_limits` schema.

## Why

Codex writes its subscription-limit reading (`rate_limits.primary.used_percent`, `plan_type`) into every rollout
under `~/.codex/sessions/`, so its history is directly measurable. Claude Code records nothing like that: the
only on-disk reading is a single `cachedUsageUtilization` snapshot in `~/.claude.json`, and transcripts are deleted
after 30 days (`cleanupPeriodDays`). A 2026-10-17 analysis had to reconstruct Claude's weekly % from one snapshot,
one weekly-limit hit and four 5-hour-limit hits (published as the "Limit Meter" artifact). Findings at the time:

- Max 5x weekly limit ≈ US$1,150 at Anthropic API prices (1% ≈ $11.49); 5h window ≈ $92–137.
- July 2026 Max 5x weeks ran $1,220–1,855 with no logged limit hits, so the allowance per API dollar was likely
  looser then (or extra-usage credits absorbed it). That estimate depends on `stats-cache.json` correction factors.
- `~/.claude/stats-cache.json` `dailyModelTokens` counts every transcript line, not each API response once
  (2–4× inflation by model) and buckets by UTC day. Divide before using it.
- Forked/resumed Codex rollouts replay the parent's `token_count` events; dedupe across files before analysis.
- Hermes (`hermes/config/default/config.yaml`, provider `openai-codex`) draws on the ChatGPT/Codex limit and
  logs to `~/.hermes/state.db` `session_model_usage`, not `~/.codex`.

## What runs

`scripts/claude-usage-statusline.sh`, packaged as `claude-usage-statusline` in
`modules/home-manager/profiles/base.nix` and set as `statusLine` by the `claudeConfig` activation on every
Home Manager host. The activation only claims `statusLine` when none is set or the current one is ours.

On each status-line render it prints `Model · 5h N% · wk N% (reset)` and, only when the 5h/7d percentage changes or
the session's `cost.total_cost_usd` grows by ≥ $1, appends one record to
`~/.local/state/claude-usage/limits.jsonl` (mode 0600) and sends the same JSON to journald with tag
`claude-usage` (shipped to Loki on journald hosts; Loki keeps 31 days, the local file is the durable copy).

Record fields: `ts, host, sid, model, reason (limits|cost), cost_usd (session cumulative, API-equivalent),
five_hour, five_hour_resets, seven_day, seven_day_resets`. No cwd, paths, prompts or account identifiers.

## Privacy posture (audit 2026-10-17)

- Anthropic account training toggle ("Help improve our AI models", `grove_enabled` from
  `GET /api/oauth/account/settings`) is **off** since 2026-05-08.
- Claude Code env via `claudeConfig`: `DISABLE_TELEMETRY`, `DISABLE_ERROR_REPORTING`, `DISABLE_AUTOUPDATER`,
  `CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY`, and (added) `DISABLE_BUG_COMMAND` + `DISABLE_FEEDBACK_COMMAND`, which
  block the two commands that upload a transcript. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is deliberately not
  set: it is an umbrella switch that may also stop the usage fetch feeding this ledger. Re-test before adding it.
- `claudeConfig` now `chmod 600`s `settings.json` and `~/.claude.json` after its tmp+mv rewrite (it was leaving
  `~/.claude.json`, which holds the OAuth account profile, at 0644).
- Codex: `analytics.enabled = false`; memories skip sessions with external context.
- Transcript secret scan (counts only, encrypted/signature blobs excluded) found no live credentials; the only
  private key was a throwaway `CN=music.vm.test` VM-test cert. AWS hits were key IDs only.
- Open items needing a decision: claude.ai connectors (Gmail/Drive/Calendar) load into Claude Code sessions
  (`disableClaudeAiConnectors` / `deniedMcpServers` can stop them); Codex has `gmail@openai-curated` enabled;
  nothing prunes `~/.codex/sessions` (14.7 GB, 277 days), `~/.claude/jobs` (22.9 GB) or `~/.hermes/state.db`.
  Keep `cleanupPeriodDays` at the 30-day default: this ledger replaces the reason to keep transcripts longer.

## Using it

- Dollars per 1% of the week: for consecutive `seven_day` changes within one `seven_day_resets` window, sum each
  session's `cost_usd` delta between the two timestamps and divide by the percentage-point change.
- Fleet view (last 31 days): Grafana Explore, `{host=~".+"} |= "claude-usage"`, or Loki
  `query_range` with that selector.
- Coverage gap: the status line renders only in interactive sessions. Background `claude --bg`/`-p` spend still
  moves the percentage but logs no cost line; recover it from transcripts while they exist (≤ 30 days).
