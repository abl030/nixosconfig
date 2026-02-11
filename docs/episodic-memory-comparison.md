# Episodic Memory for Claude Code: Candidate Comparison

**Date**: 2026-02-11
**Context**: NixOS homelab fleet — selecting Phase 2 of the three-layer agentic memory system
**Goal**: Automatic conversation archival + semantic search of past sessions

---

## What "Episodic Memory" Means

True episodic memory archives **complete conversation transcripts** with temporal metadata, enabling queries like:
- "What did we discuss about the DHCP module last Tuesday?"
- "Show me all sessions where we debugged Tailscale."
- "How did we solve the nginx reverse proxy issue?"

The key distinction: episodic = "what happened" (full recall), not semantic = "what I learned" (compressed knowledge).

---

## Candidate 1: obra/episodic-memory

**Repo**: [github.com/obra/episodic-memory](https://github.com/obra/episodic-memory)
**License**: MIT | **Stars**: 242 | **Language**: TypeScript
**Last commit**: 2025-12-22 (7+ weeks inactive)

### What It Does

The only TRUE episodic memory system. Automatically archives ALL Claude Code conversations from `~/.claude/projects/` into a permanent searchable archive. Zero manual intervention — a SessionStart hook runs `episodic-memory sync` which copies and indexes conversations with vector embeddings.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Node.js 18+ |
| **Database** | SQLite + sqlite-vec (v0.1.7-alpha.2) |
| **Embeddings** | Local via transformers.js (all-MiniLM-L6-v2, 384-dim, ~22MB ONNX) |
| **MCP tools** | `episodic_memory_search` (vector/text/hybrid), `episodic_memory_show` (full transcript) |
| **Hooks** | SessionStart: `node episodic-memory.js sync --background` |
| **Storage** | `~/.config/superpowers/conversation-archive/` + SQLite index |

### Strengths

- **Full transcript archival** — the only candidate that stores and retrieves complete conversations
- **100% local** — no API calls for embeddings, fully offline after initial model download
- **Zero workflow change** — automatic hook-driven capture
- **Cross-project search** — not siloed per-repo
- **MIT license**
- **Lightest infrastructure** — single Node.js process, no daemon, no external services

### Weaknesses

- **Development stalled** — no commits since Dec 22, 2025. 6 unmerged PRs with working fixes.
- **MCP stdout corruption** (#47) — `console.log` in embeddings.ts breaks JSON-RPC protocol. **PR #48 fixes it but is unmerged.**
- **Orphaned processes** (#53) — MCP servers accumulate when sessions end abnormally. **PR #54 fixes it but is unmerged.**
- **Recursive summarization** (#59) — indexer processes its own output, causing exponential growth
- **HuggingFace phone-home** (#52) — transformers.js validates model on every run, blocks behind proxies
- **Similarity score bug** (#55) — L2 distance treated as cosine distance (rankings correct, scores wrong)
- **Alpha vector dep** — sqlite-vec is v0.1.7-alpha.2
- **Not on npm** — must install from GitHub

### Bug Workarounds (All Patchable)

| Bug | Workaround |
|-----|-----------|
| #47 (stdout) | `sed -i 's/console\.log/console.error/g' dist/embeddings.js` + disable progress callbacks |
| #53 (orphans) | Systemd cleanup timer: `pkill -f 'episodic-memory/.*mcp-server'` hourly |
| #55 (scores) | Patch search.ts: `1 - (row.distance * row.distance / 2)` |
| #59 (recursive) | Add `DO NOT INDEX` marker to summarizer prompt |
| #52 (phone-home) | Set `env.allowRemoteModels = false` in embeddings.ts, pre-cache model |

### NixOS Packaging: MODERATE

- `buildNpmPackage` from GitHub source (not on npm)
- Native modules: `better-sqlite3` (standard node-gyp), `sqlite-vec` (may need custom derivation)
- Must pre-cache HuggingFace model and patch offline mode
- No Docker, no external services

### Episodic Fit: 10/10

The only candidate that does true episodic memory — full conversation archival with semantic search.

---

## Candidate 2: doobidoo/mcp-memory-service

**Repo**: [github.com/doobidoo/mcp-memory-service](https://github.com/doobidoo/mcp-memory-service)
**License**: Apache 2.0 | **Stars**: 1,297 | **Language**: Python
**Last commit**: 2026-02-10 (yesterday) | **Latest release**: v10.10.6

### What It Does

Hybrid semantic/episodic memory. Captures knowledge fragments via hooks (SessionStart, SessionEnd, PostToolUse), stores AI-extracted observations in SQLite with vector search, and injects relevant context at session start. Does NOT store full transcripts — stores pattern-matched excerpts (300-4000 chars) and session summaries.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Python 3.10-3.14 + Node.js (for hooks) |
| **Database** | SQLite + sqlite-vec (local), optional Cloudflare D1 (cloud sync) |
| **Embeddings** | Local ONNX (MiniLM-L6-v2, 384-dim) — no API calls |
| **MCP tools** | 12+ unified tools (store, retrieve, search, graph, quality) |
| **Hooks** | SessionStart (inject), SessionEnd (capture summary), PostToolUse (extract knowledge) |
| **Dashboard** | Web UI at localhost:8000 (8 tabs, D3.js knowledge graph) |

### Strengths

- **Most mature** — 80+ releases, daily commits, zero open bugs
- **Richest feature set** — knowledge graph, quality scoring (DeBERTa ONNX), dream-inspired consolidation
- **Local-first** — ONNX embeddings, no API calls for core functionality
- **Multi-backend** — SQLite (local), Cloudflare (cloud sync), or hybrid
- **Lite distribution** — 805MB footprint (down from 7.7GB)
- **Active development** — daily commits, responsive maintainer
- **Apache 2.0 license**

### Weaknesses

- **Not true episodic** — stores extracted concepts, not full conversation transcripts
- **Cannot replay conversations** — "what did we discuss on Feb 5th?" is not answerable
- **Pattern-matched extraction** — subtle discussions may not be captured
- **Requires HTTP server** — FastAPI on port 8000 must be running alongside Claude Code
- **Young project** — created Dec 2024, only 2 months old despite rapid iteration
- **History of breaking releases** — v9.0.0 had mass-deletion bug, v10.0.0 shipped broken tools (both hotfixed same day)

### NixOS Packaging: MODERATE

- `buildPythonPackage` with pre-cached ONNX models
- sqlite-vec C extension needs compilation
- Node.js required for hooks
- Systemd user service for FastAPI server
- No Docker required for local backend

### Episodic Fit: 6/10

Excellent semantic memory with automatic capture, but NOT episodic. Cannot retrieve or replay past conversations — only extracted knowledge fragments.

---

## Candidate 3: thedotmack/claude-mem

**Repo**: [github.com/thedotmack/claude-mem](https://github.com/thedotmack/claude-mem)
**License**: Custom | **Stars**: 26,933 | **Language**: TypeScript
**Last commit**: 2026-02-11 (today) | **Latest release**: v10.0.1

### What It Does

The most popular Claude Code memory tool. Captures every tool use via 5 lifecycle hooks, compresses observations using Claude Haiku, stores typed learnings in SQLite with FTS5 and optional ChromaDB vector search. Generates end-of-session summaries automatically. Includes web viewer UI.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Node.js 18+ AND Bun 1.1.14+ |
| **Database** | SQLite via bun:sqlite with FTS5, optional ChromaDB |
| **Embeddings** | Via ChromaDB (optional) or FTS5 keyword matching |
| **AI processing** | Claude Haiku via agent-sdk (per-tool-use compression) |
| **Worker** | Bun HTTP daemon on port 37777 |
| **MCP tools** | `search`, `timeline`, `get_observations`, `save_memory` |
| **Hooks** | All 5: SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd |

### Strengths

- **Most comprehensive capture** — hooks on every lifecycle event
- **AI-compressed observations** — ~10x token savings via Haiku compression
- **Progressive disclosure** — index (50-100 tokens) -> timeline -> full details
- **Web viewer UI** at localhost:37777
- **Massive community** — 27K stars, 1.8K forks

### Weaknesses

- **CRITICAL: Process leak** (#1010) — spawns ~1 orphaned Claude subprocess/minute, each 300-350MB RAM. Users report 233+ leaked processes, load average 151. **10 closed duplicates. Unfixed.**
- **CRITICAL: Infinite loop** (#987) — sessions fail to terminate
- **Heavy infrastructure** — requires both Bun AND Node.js
- **API cost** — every PostToolUse triggers a Claude Haiku API call
- **Hardcoded paths** (#1030) — breaks on NixOS XDG configs
- **Not true episodic** — stores AI-compressed observations, not full transcripts
- **Custom license** — not standard OSS

### NixOS Packaging: HARD

- Dual runtime (Bun + Node.js)
- Optional ChromaDB (not in nixpkgs)
- Systemd service for worker daemon
- Path patches needed for XDG compliance
- Process leak makes it unsuitable for unattended hosts

### Episodic Fit: 7/10

Strong automatic capture with AI compression, but NOT full episodic — stores compressed observations, not transcripts. **Currently unusable due to critical process leak.**

---

## Candidate 4: yuvalsuede/memory-mcp

**Repo**: [github.com/yuvalsuede/memory-mcp](https://github.com/yuvalsuede/memory-mcp)
**License**: MIT | **Stars**: 79 | **Language**: JavaScript
**Last commit**: 2026-01-29 | **Created**: 2026-01-27

### What It Does

Lightweight CLAUDE.md-centric memory. Automatically extracts memories after each Claude response using Haiku, stores in two tiers (compressed CLAUDE.md summary + full `.memory/state.json`), and takes git snapshots of the entire project on every extraction.

### Architecture

| Component | Detail |
|-----------|--------|
| **Runtime** | Node.js |
| **Database** | JSON files (`.memory/state.json`) + CLAUDE.md |
| **Embeddings** | None — keyword matching + LLM synthesis |
| **AI processing** | Claude Haiku (required for extraction) |
| **Hooks** | Stop, PreCompact, SessionEnd |
| **Git snapshots** | Auto-commits to `__memory-snapshots` branch |

### Strengths

- **Simplest architecture** — Node.js only, no native deps, no Docker
- **CLAUDE.md projection** — memory auto-updates the file Claude reads on startup
- **Git snapshots** — project state history for free
- **Cheap** — ~$0.001/extraction, ~$0.05-0.10/day
- **MIT license**

### Weaknesses

- **Brand new** — 2 weeks old, single developer, 79 stars
- **Requires API** — not local-first, needs Anthropic key for all operations
- **No vector search** — keyword matching only
- **No full transcript storage** — stores extracted concepts
- **Open "Files lost" issue** (#3) — concerning for a memory system
- **JSON storage** — won't scale to thousands of memories

### NixOS Packaging: EASY

- Node.js only, zero native deps
- No Docker, no external services
- Just needs Anthropic API key

### Episodic Fit: 5/10

Automatic extraction but no conversation archival, no vector search, no transcript replay. More of a "smart CLAUDE.md updater" than episodic memory.

---

## Head-to-Head Comparison

| Factor | episodic-memory | mcp-memory-service | claude-mem | memory-mcp |
|--------|----------------|-------------------|------------|------------|
| **Full transcript archival** | Yes | No | No | No |
| **Automatic capture** | Yes (hook) | Yes (4 hooks) | Yes (5 hooks) | Yes (3 hooks) |
| **Semantic search** | Vector + text | Vector + BM25 | FTS5 + ChromaDB | Keyword only |
| **Local-first (no API)** | Yes | Yes | No (Haiku) | No (Haiku) |
| **Infrastructure** | Node.js | Python + Node.js + HTTP server | Bun + Node.js + daemon | Node.js |
| **NixOS difficulty** | Moderate | Moderate | Hard | Easy |
| **Maturity** | 4 months, stalled | 2 months, very active | 5 months, active | 2 weeks |
| **Critical bugs** | Patchable (#47, #53) | None | SHOWSTOPPER (#1010) | Unknown (#3) |
| **License** | MIT | Apache 2.0 | Custom | MIT |
| **Stars** | 242 | 1,297 | 26,933 | 79 |
| **API cost** | None (optional summaries) | None | Per-tool-use Haiku | Per-extraction Haiku |
| **Cross-project** | Yes | Yes | Yes | No (per-repo) |

---

## Evaluation

### Eliminated

- **claude-mem**: Process leak (#1010) is a showstopper. Spawns 300MB subprocesses at ~1/minute with no cleanup. Cannot be deployed on unattended hosts. Revisit if/when fixed.
- **memory-mcp**: Too young (2 weeks), no vector search, requires API for everything, unresolved "files lost" issue. Not ready.

### Viable Candidates

**obra/episodic-memory** is the only tool that does what we actually need: full conversation archival with semantic search. Every other candidate stores extracted/compressed knowledge, which is **semantic memory** (Phase 3), not episodic memory (Phase 2).

**mcp-memory-service** is excellent but solves a different problem. It would be a strong Phase 3 (semantic memory) candidate, replacing the blocked claude-mem evaluation.

### The Fork Question

obra/episodic-memory's biggest risk is the stalled upstream (7+ weeks, 6 unmerged PRs). The options:

1. **Use as-is with local patches** — Apply fixes for #47, #53, #55, #59 manually. Monitor upstream.
2. **Fork and maintain** — Take ownership of bug fixes. More work but full control.
3. **Wait for upstream** — Could be weeks or months. Development may not resume.

All critical bugs have working fixes (PRs or documented patches). The core architecture is sound — 73/73 tests passing, comprehensive test coverage. The risk is maintenance, not functionality.

---

## Recommendation

**Deploy obra/episodic-memory with local patches.**

Rationale:
- It's the only true episodic memory tool — full conversation archival + semantic search
- All critical bugs have documented workarounds or unmerged PRs with fixes
- Lightest infrastructure (Node.js only, no daemon, no external services)
- Local-first (no API calls for core functionality)
- MIT license allows forking if upstream stays dormant
- NixOS packaging is moderate but achievable

### Implementation Plan

1. Package episodic-memory for NixOS (Home Manager module)
2. Apply patches for #47 (stdout), #53 (orphans), #59 (recursive summarization)
3. Pre-cache HuggingFace model, patch offline mode
4. Deploy on WSL first, then fleet-wide
5. If upstream stays dormant 30+ days, evaluate forking

### Future: Phase 3 Candidate Update

Replace claude-mem with **mcp-memory-service** as the Phase 3 (semantic memory) candidate. It's more mature, has zero critical bugs, and solves the semantic layer well. Update beads tracking accordingly.

---

## Also Evaluated (Not Episodic)

- **AutoMem** (verygoodplugins/automem) — Graph+vector knowledge store. Manual `store`/`recall` only. Requires Docker (FalkorDB + Qdrant). Not episodic. Good for relational knowledge but wrong problem domain.
- **Tempera/MemRL** (anvanster/tempera) — RL-based session memory. Manual capture. 2 weeks old, 4 stars. Novel approach but too immature and not automatic.
