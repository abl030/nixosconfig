# Agentic Memory: 3-Option Comparison for Fleet Deployment

**Date**: 2026-02-11
**Context**: NixOS homelab fleet (wsl, framework, epimetheus, doc1, igpu, dev)
**Goal**: Replace/augment static CLAUDE.md memory with persistent cross-session memory

---

## Option 1: Episodic Memory (Jesse Vincent / obra)

**Repo**: [github.com/obra/episodic-memory](https://github.com/obra/episodic-memory)
**License**: MIT | **Version**: 1.0.15 (no GitHub releases, dist/ committed to git)
**Language**: TypeScript/Node.js

### What It Does

Archives Claude Code conversation logs before their 30-day expiry, indexes them with local vector embeddings, and exposes semantic search via MCP. A Haiku subagent summarizes retrieved conversations to compress context (claimed 50-100x reduction).

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Node.js 18+ (no Bun, no Python) |
| **Database** | SQLite via `better-sqlite3` (C++ N-API addon) |
| **Vector search** | `sqlite-vec` v0.1.7-alpha.2 (native C extension) |
| **Embeddings** | Local via `@xenova/transformers` (all-MiniLM-L6-v2, 384-dim, ~22 MB ONNX model) |
| **MCP transport** | stdio (launched as subprocess by Claude Code) |
| **Hook** | SessionStart only: `node episodic-memory.js sync --background` |
| **Storage paths** | `~/.config/superpowers/conversation-archive/` + `conversation-index/db.sqlite` |

### MCP Tools Exposed

- `episodic_memory_search` -- vector/text/hybrid search with date filters
- `episodic_memory_show` -- read specific conversation files with pagination

### Pros

- **Lightest weight**: Single Node.js process, no daemon, no external services
- **100% local embeddings**: No API calls for core search (Anthropic API optional for summaries)
- **Zero workflow change**: Automatic -- hooks capture everything, no manual journaling
- **Cross-project search**: Not siloed per-repo, finds patterns across all codebases
- **XDG-compliant paths** with full env var overrides
- **MIT license**
- **Lowest infrastructure**: No ChromaDB, no Bun, no background daemon

### Cons

- **Alpha-quality vector dependency**: `sqlite-vec` is v0.1.7-alpha.2
- **Native modules**: `better-sqlite3` + `sqlite-vec` need compilation toolchain or prebuilds (problematic on NixOS)
- **HuggingFace phone-home**: Transformers.js validates model on every run, blocks behind proxies (issue #52)
- **Orphaned processes**: MCP servers accumulate when sessions end abnormally (issue #53)
- **MCP stdout corruption**: `console.log` in embeddings.ts breaks JSON-RPC protocol (issue #47)
- **Recursive summarization**: Can cause runaway DB growth (issue #59)
- **No releases**: Must pin to git commit, dist/ in repo
- **Not published to npm**: Despite README claiming otherwise (issue #43)
- **Agent must consciously search**: Not autonomous recall -- Claude has to decide to invoke the tool
- **No structure**: Raw conversations only, no dependency graphs or task state

### NixOS Packaging Difficulty: MODERATE

- Need to handle `better-sqlite3` and `sqlite-vec` native compilation
- Pre-cache HuggingFace model in Nix store or activation script
- Systemd user timer needed for orphaned process cleanup
- Plugin path (`~/.claude/plugins/cache/`) is imperative state

### Risk Assessment

| Factor | Level |
|--------|-------|
| MCP protocol bug (#47) | **HIGH** -- can prevent server from starting |
| Process leaks (#53) | **MEDIUM** -- needs external cleanup |
| Alpha dependencies | **MEDIUM** -- sqlite-vec is pre-release |
| Overall stability | **MEDIUM** -- 17 open issues, no formal releases |

---

## Option 2: Claude-Mem (thedotmack)

**Repo**: [github.com/thedotmack/claude-mem](https://github.com/thedotmack/claude-mem)
**License**: AGPL-3.0 | **Version**: 10.0.0 (1,273 commits, 47 contributors)
**Language**: TypeScript

### What It Does

Automatically captures every tool use Claude makes, compresses observations via AI (Agent SDK), stores typed learnings in SQLite with full-text and vector search, and injects relevant context at session start. CLAUDE.md becomes a dynamic projection regenerated per session.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Node.js 18+ AND Bun 1.1.14+ AND Python (via uv) |
| **Database** | SQLite via `bun:sqlite` (bundled) with FTS5 |
| **Vector search** | ChromaDB (Python, separate process) -- optional, FTS5 fallback |
| **AI processing** | Claude Agent SDK / Gemini / OpenRouter (pluggable) |
| **Worker service** | Express.js on Bun, port 37777, PID-managed daemon |
| **Hooks** | 5 lifecycle hooks (SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd) |
| **MCP transport** | stdio wrapper translating to HTTP calls against worker |
| **Storage** | `~/.claude-mem/claude-mem.db` + `~/.claude-mem/chroma/` |

### MCP Tools Exposed

- `search` -- compact index (50-100 tokens/result)
- `timeline` -- chronological context around anchor
- `get_observations` -- full details for filtered IDs (500-1k tokens)
- `save_memory` -- manual storage
- `__IMPORTANT` -- workflow documentation

### Pros

- **Most "intelligent" memory**: AI-compressed typed observations (decision, bugfix, refactor, etc.)
- **3-layer progressive retrieval**: ~10x token savings over naive RAG
- **Automatic capture of everything**: Every tool use generates an observation
- **Dynamic CLAUDE.md generation**: Context tailored per session, never stale
- **Web viewer UI** at localhost:37777
- **Multi-provider AI processing**: Claude, Gemini (free tier), OpenRouter

### Cons

- **CRITICAL: Orphaned process leak** (issue #1010, 10 duplicates): Spawns ~1 Claude subprocess/minute, each 300-350 MB RAM. Users report 233+ leaked processes with load average 151. **Unsuitable for unattended hosts.**
- **Infinite session loop** (issue #987): Sessions fail to terminate
- **Heavy infrastructure**: Requires Bun + Node.js + Python/uv + ChromaDB
- **AGPL license**: Modifications must be shared (fine for internal use)
- **curl-pipe-bash installer**: `smart-install.js` runs `curl | bash` -- incompatible with Nix purity
- **Hardcoded plugin paths** (issue #1030): Breaks on XDG-based configs (NixOS)
- **45 open issues** including critical stability bugs
- **ChromaDB on NixOS**: Known build failures in nixpkgs
- **API cost**: Every PostToolUse triggers AI compression (Claude API call)

### NixOS Packaging Difficulty: HIGH

- Need Bun, Node.js, Python/uv, and optionally ChromaDB
- Patch `smart-install.js` to skip curl-pipe-bash
- Wrap worker daemon in systemd user service
- Fix hardcoded paths (PR #1031 pending)
- ChromaDB has known nixpkgs build failures

### Risk Assessment

| Factor | Level |
|--------|-------|
| Process leak (#1010) | **CRITICAL** -- memory exhaustion on unattended hosts |
| Infinite loop (#987) | **HIGH** -- sessions never terminate |
| DB init failure (#979) | **HIGH** -- can't start on fresh install |
| Path hardcoding (#1030) | **MEDIUM** -- workaround via env vars |
| Overall stability | **HIGH RISK** -- 45 open issues, critical bugs unfixed |

---

## Option 3: Beads (Steve Yegge)

**Repo**: [github.com/steveyegge/beads](https://github.com/steveyegge/beads)
**License**: MIT | **Version**: v0.49.6 (pre-built binaries for Linux amd64/arm64)
**Language**: Go

### What It Does

Git-native issue tracker designed as structured memory for AI coding agents. Replaces markdown plans with a dependency-aware task graph that branches with your code. Issues stored as JSONL in `.beads/`, cached in SQLite for fast queries.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Single Go binary (pre-built or `go install`) |
| **Database** | SQLite via Wazero (WebAssembly, pure Go -- no CGO for SQLite) |
| **Storage** | `.beads/issues.jsonl` (git-tracked) + `.beads/beads.db` (gitignored cache) |
| **Daemon** | Unix socket at `.beads/bd.sock`, file-watching, auto-import/export |
| **MCP server** | Separate Python package (`beads-mcp`) via `uv tool install` |
| **Hooks** | SessionStart: `bd prime` (~1-2k tokens); PreCompact: `bd sync` |
| **Memory decay** | `bd compact` uses Anthropic API to summarize closed issues |

### CLI Workflow

```bash
bd init                    # Initialize .beads/ in project
bd setup claude            # Install hooks + MCP config
bd ready --json            # Get prioritized unblocked work
bd create "title" -t task  # Create issue
bd show bd-a3f8            # View issue details
bd update bd-a3f8 --status in_progress
bd close bd-a3f8
bd sync                    # Export to JSONL + git commit
bd compact                 # Summarize old closed issues
bd doctor --fix            # Self-repair
```

### Pros

- **Git-native**: Memory branches when you branch, merges when you merge
- **Structured task graph**: Dependency relationships (blocks, parent-child, related, discovered-from)
- **Hash-based IDs**: Conflict-free multi-agent task creation across branches
- **Memory decay**: LLM-summarized closed tasks preserve decisions while freeing context
- **Single static binary**: Trivial to package for NixOS (fetchurl from GitHub Releases)
- **MIT license**
- **Graceful degradation**: Falls back to direct SQLite if daemon unavailable
- **Rich community ecosystem**: TUIs, web UIs, VS Code/Emacs/Neovim plugins, kanban boards
- **Active development**: Multiple releases per week

### Cons

- **Different problem domain**: Task/issue tracker, NOT episodic memory of past sessions
- **Agents don't proactively use it**: Requires explicit CLAUDE.md instructions and `bd ready` prompting
- **Context fade in long sessions**: Agent forgets to file/sync work
- **Data loss bugs**: Issue #1623 (daemon export overwritten by auto-import), #1669 (migrate creates wrong DB)
- **196 open issues**: Pre-stable software
- **Daemon instability**: Multiple startup/stopping/locking issues (#1658, #1657, #1656)
- **Git worktree conflicts**: Issues with worktree setups (#1645, #1634)
- **MCP server is separate Python package**: Adds a second dependency
- **Anthropic API key required** for `bd compact` (memory decay feature)
- **Heavy binary**: Go + Wazero + Dolt libraries likely 50-100 MB

### NixOS Packaging Difficulty: LOW

- Pre-built static Linux binaries on GitHub Releases -- trivial `fetchurl` derivation
- Or `buildGoModule` with vendored deps (needs `libicu-dev`, `libzstd-dev`)
- Per-project `.beads/` directory -- no global state to manage
- No background daemon service needed (auto-starts from CLI)
- MCP server (`beads-mcp`) needs separate Python derivation

### Risk Assessment

| Factor | Level |
|--------|-------|
| Data loss (#1623, #1669) | **HIGH** -- daemon can overwrite data |
| Daemon stability | **MEDIUM** -- multiple open issues |
| Git worktree edge cases | **MEDIUM** -- conflicts in worktree setups |
| Overall stability | **MEDIUM** -- 196 issues but fast iteration |

---

## Head-to-Head Comparison

| Factor | Episodic Memory | Claude-Mem | Beads |
|--------|----------------|------------|-------|
| **Memory type** | Episodic (past conversations) | Semantic (compressed learnings) | Procedural (task graphs) |
| **Automation** | Automatic (hook-driven) | Automatic (hook-driven) | Semi-manual (agent must use `bd` CLI) |
| **Infrastructure** | Node.js only | Bun + Node + Python + ChromaDB | Go binary + optional Python MCP |
| **NixOS packaging** | Moderate (native modules) | Hard (multi-runtime, curl-pipe-bash) | Easy (static binary) |
| **Maturity** | Alpha (no releases) | Active but critical bugs | Pre-stable (v0.49.x) |
| **Showstopper bugs** | MCP protocol corruption (#47) | Process leak (#1010) | Data loss (#1623) |
| **API costs** | None for core (optional for summaries) | Per-tool-use AI compression | None for core (optional for compact) |
| **License** | MIT | AGPL-3.0 | MIT |
| **Cross-project** | Yes (global search) | Yes (per-user DB) | No (per-repo `.beads/`) |
| **Fleet suitability** | Medium -- lightweight but buggy | Low -- critical resource leaks | Medium -- easy to deploy but different paradigm |

---

## Recommendation

**None of these three are fleet-ready today.** All have showstopper bugs in their current releases. However, all three memory types (episodic, semantic, procedural) will be implemented — right tool for the right job.

### Revised Assessment (all three layers planned)

Given the commitment to implement all three memory types, the evaluation shifts from "which one" to "what order":

1. **Beads (procedural)** — Start here. Single static Go binary, trivial NixOS packaging via `fetchurl`. Provides immediate value for structured task tracking and session handoffs. Data-loss bugs are in edge cases (daemon race conditions, migration tool) avoidable in normal use. Per-repo `.beads/` means no global state to manage.

2. **Episodic Memory (episodic)** — Second. Native Node.js modules (`better-sqlite3`, `sqlite-vec`) are a NixOS packaging pain point. MCP protocol bug (#47) blocks basic functionality until patched. Conversation archive needs time to accumulate before search is useful anyway — no downside to deploying second.

3. **Claude-Mem (semantic)** — Third, once #1010 (process leak) is fixed. Or evaluate alternatives — this space is evolving fast. Architecturally the most ambitious but too dangerous unattended today.

### Rollout Plan

- **Phase 1**: Deploy Beads on WSL (single host trial), package as Home Manager module
- **Phase 2**: Roll out Beads fleet-wide once stable
- **Phase 3**: Package and deploy episodic-memory (upstream bugs #47, #53 may be fixed by then)
- **Phase 4**: Revisit claude-mem or alternatives for semantic layer once #1010 is resolved

---

## Decision: BEADS FIRST

**Date**: 2026-02-11
**Rationale**: Easiest NixOS packaging (static Go binary), highest immediate value (structured task handoffs), lowest risk bugs. Episodic and semantic layers to follow in sequence.
