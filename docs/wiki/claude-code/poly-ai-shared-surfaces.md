# Shared Claude Code and Codex Surfaces

**Date researched:** 2026-07-11
**Status:** Working on Codex CLI 0.144.1 and the fleet Claude Code package
**Scope:** Repository instructions, skills, specialist agents, MCP, and durable memory

## Decision

The repository uses one authored source per concept and only generates adapters
where Claude Code and Codex require different file formats. We do not maintain
parallel hand-edited Claude and Codex copies.

| Concept | Authored source | Adapter |
|---|---|---|
| Project instructions | `CLAUDE.md` | `AGENTS.md -> CLAUDE.md` |
| Skills | `.claude/skills/` | `.agents/skills -> ../.claude/skills` |
| Specialist agents | `.claude/agents/*.md` | generated `.codex/agents/*.toml` |
| Project MCP | `.mcp.json` | generated `.codex/config.toml` |
| Durable learning | `.claude/memory/`, `docs/wiki/`, Forgejo | none |

The `.claude` name remains for the authored skill and agent trees because moving
the established sources to a neutral namespace would create widespread path
churn without improving behavior. The adapters make the ownership explicit.

## Generator

Run after changing `.claude/agents/*.md` or `.mcp.json`:

```bash
python3 scripts/generate-ai-adapters.py
python3 scripts/generate-ai-adapters.py --check
```

The generator:

1. Parses the common subset of Claude agent YAML frontmatter.
2. Copies each agent body into Codex `developer_instructions`.
3. Converts agent-scoped `mcpServers` into Codex `mcp_servers` tables.
4. Converts `.mcp.json` into the trusted project `.codex/config.toml` layer.
5. Validates generated TOML with Python `tomllib`.

Generated files are committed so a fresh checkout works without an activation
step. Never edit them directly. `aiPortabilityCheck` in `nix flake check` rejects
stale or missing outputs.

## Skills

Current Codex discovers repository skills from `.agents/skills`; Claude Code
discovers them from `.claude/skills`. The symlink exposes the same `SKILL.md`
files to both. The old `.codex/skills` adapter was removed after a Codex
`debug prompt-input` smoke test showed all project skills loading from the new
path. The previously lowercase `.claude/skills/drift/skill.md` was renamed to
`SKILL.md`, making it visible to both clients.

Skill authors should use the shared Agent Skills shape and ordinary procedural
language. Claude-only tool names or frontmatter belong only where the workflow
genuinely requires them; the project instruction file supplies basic tool-name
compatibility for older material.

## Memory

Do not synchronize Claude auto-memory internals with Codex native memory.

- Claude auto-memory writes Markdown in the configured project memory folder.
- Codex native memory is enabled as a personal recall layer. It is generated
  local state under `~/.codex/memories`, not a hand-edited or repository control
  surface. Home Manager keeps generation and use enabled while setting
  `disable_on_external_context = true`, so tasks that actually used MCP, web, or
  tool-search context do not become memory inputs.
- Client-local memory is useful recall, but it is not durable project truth.

Both clients instead read `.claude/memory/MEMORY.md` at session start. That file
is a maximum-15-line index of critical quirks and links. Detailed discoveries go
in a focused memory file, `docs/wiki/`, or a Forgejo issue. This promotion step is
what makes something learned by one client available to the other.

`scripts/merge-toml-settings.py` applies managed Codex user settings without
taking ownership of the mutable file. It preserves comments and unknown
Codex/plugin keys, validates the full document with `tomllib`, and atomically
replaces the file only when values changed.

## Context Budget

The former root guide was 435 lines and 30,789 bytes, close to Codex's default
32 KiB project-instruction limit and well beyond Claude's recommended concise
instruction size. It also contained stale operational facts. The shared guide is
now budgeted at 300 lines and 24 KiB, with current procedures and rationale moved
behind skills and wiki links. `MEMORY.md` is capped at 15 lines. The portability
check enforces both budgets.

## MCP Scope

There are three deliberate scopes:

- Home Manager's `programs.mcp` is the global declaration for tools such as
  `mcp-nixos` that should work outside this repository.
- `.mcp.json` is the repository declaration and feeds both clients.
- Agent frontmatter owns sensitive or noisy specialist MCP servers so they load
  only inside the corresponding agent.

The same MCP may appear at global and project scope when the intended scopes
overlap. Values must be identical; project Codex config wins by normal config
precedence. Secrets stay behind wrapper scripts and `/run/secrets`; generated
TOML must never contain credentials.

## Verification

```bash
python3 scripts/generate-ai-adapters.py --check
codex debug prompt-input "adapter smoke test"
codex --strict-config doctor --summary --ascii
codex mcp list
nix build .#checks.x86_64-linux.aiPortabilityCheck
```

The `doctor` command may report `TERMINFO unreadable` in non-interactive agent
PTYs; that is unrelated to project configuration. The relevant configuration and
MCP checks must be green.

## Revisit When

- Claude Code or Codex adopts the other's custom-agent file format.
- Codex removes either `.agents/skills` or project-scoped custom agents.
- Agent frontmatter needs nested YAML beyond the generator's intentionally small
  supported subset.
- A shared memory standard emerges that is both plain-text and repository-safe.
