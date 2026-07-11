# Claude Code + Codex → native home-manager modules

**Date:** 2026-05-29
**Status:** Historical migration record; runtime details have since changed. See
[`poly-ai-shared-surfaces.md`](poly-ai-shared-surfaces.md) for the current shared
Claude Code/Codex contract and
[`plugins-in-agent-view.md`](plugins-in-agent-view.md) for current Claude plugin
registration.
**Issue:** #261
**Pinned home-manager:** `1a95e2ef` (2026-05-25)

## What changed

Replaced the hand-rolled `homelab.claudeCode` module (~380 lines:
`modules/home-manager/services/claude-code.nix`) with the upstream
`programs.claude-code` / `programs.codex` / `programs.mcp` modules. The custom
module + its `.md` are deleted; config now lives in:

- `modules/home-manager/profiles/base.nix` — `programs.claude-code`, `programs.mcp`, and a small `home.activation.claudePrivacy`
- `home/utils/common.nix` — `programs.codex` + the pre-existing `codexPrivacy` activation

## The key insight: don't let the native modules own the config files

Both native modules, **the moment you set `settings` (claude) / a non-empty
`settings`-or-MCP-integration (codex), seize the config file as a read-only
`/nix/store` symlink** (`programs.claude-code.settings` → `~/.claude/settings.json`;
`programs.codex.settings` / `mcp_servers` → `~/.codex/config.toml`).

That is destructive here, because both files are **runtime-mutable and
agent-owned**:

- `~/.claude/settings.json` accumulates `effortLevel`, `skipDangerousModePermissionPrompt`, interactively-installed plugins (`enabledPlugins`), hooks, etc.
- `~/.codex/config.toml` is rewritten constantly by codex — per-project `trust_level`s, plugin enables, model-migration notices, model/personality/effort.

Owning either read-only would wipe all of that and block future `/config` changes.

**Solution: leave `settings` UNSET on both modules.** The native module then only
seizes the file when those are set, so with them empty it still does everything
useful — installs the package, loads plugins, wires MCP, symlinks skills — while
**never touching `settings.json` / `config.toml`.** The few keys that genuinely
must live *inside* `settings.json` (privacy env flags — they have to reach the
systemd `claude -p` diagnosis runs, which read settings.json regardless of shell
env) are merged in by a tiny idempotent `jq` activation that touches only the
keys we manage. Same pattern as the long-standing codex `[analytics]` script.

## How plugins work now (`--plugin-dir`, not the marketplace flow)

`programs.claude-code.plugins` is a `listOf (either package path)`. Each entry is
passed as `--plugin-dir <path>` to a wrapper around `claude`. This:

- **force-enables** the plugin for the session — no `enabledPlugins` entry, no marketplace registration, no `~/.claude/plugins/cache` machinery (all of which the old module hand-built);
- namespaces skills/agents/commands from the plugin's `plugin.json` `name`;
- reads fine from read-only store paths (`claude plugin list` shows them as `@inline ✔ loaded`).

So we use `plugins` ONLY and skip `marketplaces` (which just writes a
`known_marketplaces.json` / `extraKnownMarketplaces` that would fight the
runtime-mutable copy claude maintains for other plugins).

Point `--plugin-dir` at the dir that directly contains `.claude-plugin/plugin.json`:

- `inputs.claude-plugin-ha-skills` — repo root *is* the plugin (root has both `marketplace.json` and `plugin.json`).
- `"${inputs.claude-plugin-compound-engineering}/plugins/compound-engineering"` — multi-plugin marketplace, so point at the plugin subdir.

**Obsolete risk:** the old module had elaborate `--preserve-symlinks` /
`realpathSync` / `hooks.json` patching for node ESM resolution. The current
compound-engineering plugin (v3.9.0) is **pure markdown** — no bundled MCP
servers, no hooks, no node scripts — so none of that is needed. If a future
plugin version ships bundled node MCP/hooks that `npm install` at runtime,
re-evaluate (a read-only store path can't be written into).

## MCP

`programs.mcp.servers.mcp-nixos = { command = "uvx"; args = ["mcp-nixos"]; }` is
the single shared definition. `programs.claude-code.enableMcpIntegration = true`
folds it into claude's main-chat MCP set (via an auto-generated `@inline` plugin
holding `.mcp.json`) and `programs.mcp` also writes `~/.config/mcp/mcp.json`.

Subagent-only MCPs (unifi/pfsense/playwright/HA) stay out of `programs.mcp.servers`
— they remain scoped to `.claude/agents/`. Vinsight is installed but registered
per-repo via that repo's `.mcp.json`.

## mcp-nixos on Codex (append, don't own)

The native `enableMcpIntegration = true` path can't be used — it writes
`mcp_servers` into `config.toml` and so would seize the mutable file (see
above). Instead the `codexConfig` activation in `common.nix` idempotently
**appends** the table when its header is missing — the same append-if-absent
trick as the `[analytics]` opt-out:

```toml
[mcp_servers.mcp-nixos]
command = "uvx"
args = ["mcp-nixos"]
```

codex keeps it like any other runtime key; the rest of `config.toml` is
untouched. Verified with `codex mcp list` → `mcp-nixos … enabled`. Re-running
activation does not duplicate the block (grep-guarded on the header).

This is deliberately less "pure" than a module flag, but it's the only way to
declare codex MCP without owning the file codex constantly rewrites.

## Manual step: compound-engineering on Codex

Codex's module has no plugin option and the install is interactive. To get CE on
Codex: register the marketplace → install via `/plugins` → `bunx
@every-env/compound-plugin` to add the agents (Codex's plugin spec doesn't
install custom agents yet, per upstream). Keep the version aligned with the
Claude CE plugin (currently 3.9.0). Documented inline in `common.nix`.

## Migration debris cleanup

Deleting the old module removed the `~/.claude/plugins/marketplaces/*` symlinks
it created, so the stale `enabledPlugins` + `known_marketplaces.json` +
`installed_plugins.json` records for `compound-engineering`,
`home-assistant-skills`, and `episodic-memory` started throwing
`Marketplace … failed to load: cache-miss` on every session. The `claudePrivacy`
activation idempotently strips exactly those three entries from all three files
(CE + ha are now `@inline`; episodic-memory is retired). It never recreates the
machinery and leaves working entries (e.g. `pyright-lsp@claude-plugins-official`)
untouched.

## Verification (proxmox-vm)

- `claude plugin list` → `pyright-lsp ✔ enabled`; `claude-code-home-manager`, `home-assistant-skills`, `compound-engineering` all `@inline ✔ loaded`; zero cache-miss.
- `~/.claude/settings.json` — `effortLevel`, `skipDangerousModePermissionPrompt`, `pyright-lsp` preserved; `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` removed; 4 privacy keys present.
- `~/.codex/config.toml` — runtime state intact (trust levels / plugin enables / migrations); `[analytics]` + `[mcp_servers.mcp-nixos]` appended; talk-to-me skill symlinked into `~/.codex/skills/`. `codex mcp list` → `mcp-nixos … enabled`.
