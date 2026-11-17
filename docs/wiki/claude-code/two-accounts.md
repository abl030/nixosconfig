# Two Claude Code logins (personal + work) on one host

Verified: 2026-11-17 (Claude Code 2.1.325, doc1)

## What

`homelab.claudeWorkAccount` (modules/home-manager/services/claude-work-account.nix)
runs a second subscription beside the personal one, chosen by working directory.
On doc1 it is the Cullen Wines subscription for the Cullen repos.

| Started in… | Account | Config |
|---|---|---|
| a listed directory (or below) | work (`cullen`) | `~/.claude-cullen/` |
| anywhere else | personal | `~/.claude/` + `~/.claude.json` |
| any dir, `claude-cullen` | work, forced | |
| any dir, `claude-me` | personal, forced | |

## How it works

- Claude Code keeps everything (credentials, `.claude.json`, settings, transcripts,
  jobs, the background daemon) in `$CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`
  with `.claude.json` in `$HOME`. **Personal means the variable is unset**: setting
  it to `~/.claude` looks for `~/.claude/.claude.json` and loses the login.
- A `claude` wrapper (hiPrio over the package) sets the variable from `pwd -P`.
  An inherited `CLAUDE_CONFIG_DIR` always wins, so subagents, background jobs and
  `claude -p` children stay on their parent session's account, even after a `cd`.
- The work account is used only once `~/.claude-cullen/.credentials.json` exists;
  until then the wrapper falls back to personal with a stderr note, so unattended
  `claude -p` runs (brain-sweep) never break on a missing login.
- Activation (`claudeWorkAccount`, after `claudeConfig` and `aiAgentNotifications`)
  re-asserts the fleet-managed settings keys (env, statusLine, deniedMcpServers,
  enabledPlugins, hooks, permissions), the plugin registrations and mcp-nixos into
  the work dir, and symlinks `CLAUDE.md`, `hooks/`, `skills/` to `~/.claude`.
  Model/effort and other `/config` choices stay per account.
- Project-scoped things (repo `.claude/`, `.mcp.json`, auto-memory dirs) follow the
  directory, so they are the same whichever account runs.

## Per-account, not shared

- Background jobs / Agent View: one daemon per config dir, so two job lists.
  `claude-agents` goes through the router, so run it from the directory whose
  jobs you want (or `claude-cullen --verbose agents …`).
- claude.ai side: Artifacts, connectors (Calendar, Drive, Docs), routines belong to
  the account that made them. A page republished from the other account gets a new URL.
- Session history and `/resume`.
- Usage ledger: `claude-usage-statusline` writes to
  `~/.local/state/claude-usage/<configdir-basename>/` for a non-default dir.
- Retention (`ai-retention`, doc1 `agent-disk-cleanup`) sweep `~/.claude-*` too.
- talk-to-me registers `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/…`.

## First login

```
cd ~/cullen-assistant && claude-cullen   # then /login with the work account
```

Check: `claude-cullen` → `/status` shows the work org; `claude-me` → personal.
Codex is not covered; `CODEX_HOME` would be the equivalent.
