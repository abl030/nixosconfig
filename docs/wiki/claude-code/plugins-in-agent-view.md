# Plugins & MCP in Agent View / background sessions

> Researched + fixed: 2026-06-26 | Claude Code v2.1.187 | Status: **Fixed** (this repo)

## Symptom

Claude Code plugins (and their skills) plus the `mcp-nixos` MCP server were
available in foreground `claude` but **missing in Agent View** (`claude agents`)
and any `claude --bg` / background session. The `ce-*` skills
(compound-engineering), `home-assistant-best-practices` (ha-skills), and the
`mcp-nixos` tools simply weren't there when a session was dispatched from the
Agent View dashboard.

## Root cause

Agent View runs background sessions via a **persistent supervisor daemon**
(`cc-daemon-<uid>`). The supervisor pre-warms and self-respawns worker
processes by exec'ing the **unwrapped** binary directly
(`.../bin/.claude-unwrapped --bg-spare ...`) with a **fixed argv**.

This repo loaded plugins + MCP only through a Nix `claude` **wrapper** that
appended `--plugin-dir <store>` / `--mcp-config <store>` to argv
(`programs.claude-code.plugins` + `enableMcpIntegration` →
`makeWrapper`/symlinkJoin). Because the supervisor self-respawns the unwrapped
binary, those flags never reach background workers.

Live proof on doc1 (2026-06-26): of all running `claude` processes, **only the
foreground Agent-View UI** (`claude --plugin-dir ... agents`) carried the flags;
every `.claude-unwrapped --bg-spare` worker had **none**. Foreground hit the
wrapper, background didn't.

> Not the same as the `skills:`-in-subagents bugs — see
> [skills-in-subagents.md](skills-in-subagents.md). That's about subagent
> frontmatter; this is about the wrapper-vs-supervisor argv gap.

## Fix (this repo)

Stop loading via argv. Register plugins + MCP as **argv-independent on-disk
config** — the same mechanism `pyright-lsp` already uses, which every session
(foreground, Agent View, `claude --bg`, and the systemd `claude -p` diagnosis
runs that already call the unwrapped binary) reads identically.

In `modules/home-manager/profiles/base.nix`:

1. **Dropped** `programs.claude-code.plugins` and `enableMcpIntegration` → the
   HM module no longer builds a wrapper at all (`claude` on PATH is the raw
   package). One binary, one config path, no bypass.
2. The `claudeConfig` home-activation (idempotent jq merges, tmp+mv, never a
   read-only store symlink) now writes:
   - `~/.claude/settings.json` → `enabledPlugins` for both plugins.
   - `~/.claude/plugins/known_marketplaces.json` → two `directory`-source
     marketplaces (`homelab-ha`, `homelab-ce`) with `installLocation` pointing
     **directly at the read-only /nix/store paths** (no copy).
   - `~/.claude/plugins/installed_plugins.json` → matching installed records,
     `installPath` at the same store paths.
   - `~/.claude.json` → `mcpServers.mcp-nixos` (user scope), replacing the old
     `--mcp-config` carrier.

Store-path churn (the reason an earlier marketplace attempt was abandoned) is
handled by rewriting all four files every activation, so records always point at
the current generation's store paths, which are GC-rooted by the activation
script.

### Why not `CLAUDE_CODE_PLUGIN_SEED_DIR`?

It's the documented "bake plugins into a container image" env var (read by the
supervisor too), but it requires the **same** `known_marketplaces.json` +
`installed_plugins.json` + `enabledPlugins` structures staged in a seed dir that
Claude copies into `~/.claude/plugins` at bootstrap — and it **still** needs
`enabledPlugins` plus a supervisor restart to pick up the new env. Writing the
structures straight into place is simpler, needs no env plumbing or daemon
restart, and is what we verified.

## Verification

Run the **unwrapped** binary (what the supervisor spawns) with **no
`--plugin-dir`**, pointed at a config dir holding only the on-disk records:

```
.claude-unwrapped plugin list      # both plugins → "Status: ✔ enabled"
.claude-unwrapped plugin details compound-engineering@homelab-ce  # 27 skills resolved
.claude-unwrapped mcp list         # mcp-nixos: ✔ Connected
```

All pass from disk config alone. The generated `claudeConfig` activation was run
against a throwaway `$HOME` and produced valid JSON that the unwrapped binary
loads.

After deploy: dispatch a real Agent View session and confirm a plugin skill is
present (covers the upstream background-loading caveat below). A one-time
`claude kill-supervisor` after the first deploy forces pre-warmed workers to
re-warm against the new config.

## Upstream caveats / when to revisit

- Plugin/MCP loading into Agent View requires **v2.1.142+** (we're on 2.1.187).
- `CLAUDE_CODE_PLUGIN_SEED_DIR` is undocumented upstream — issue
  [#35140](https://github.com/anthropics/claude-code/issues/35140).
- Background-session config inheritance has rough edges (e.g. user-`agents`
  loading, [#58729](https://github.com/anthropics/claude-code/issues/58729)).
  If a future version loads `enabledPlugins` differently in background workers,
  re-run the `plugin list` check on the unwrapped binary.
- If the upstream HM module ever gains an argv-independent `enabledPlugins`
  writer that doesn't seize `settings.json` as a read-only symlink, fold this
  activation back into the module options.
