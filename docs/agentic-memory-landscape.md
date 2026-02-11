# Agentic Memory Systems: Landscape Research (Feb 2026)

## The Problem Space

Every system is trying to solve the same core issue: **agents wake up with amnesia**. CLAUDE.md gives ~200 lines injected into the system prompt, which:
- Gets stale fast (you write it, then the codebase drifts)
- Isn't queryable (grep through markdown?)
- Can't represent dependencies or relationships
- Doesn't scale past one project/one agent
- Requires manual curation — you're maintaining the memory, not the agent

Context window limits mean agents start making poor decisions as sessions grow — skipping tests, commenting out assertions, forgetting scope.

---

## Tier 1: The Major Contenders

### 1. Beads (Steve Yegge) — Structured Task Graph

**Philosophy**: Memory is a *git-native issue tracker*, not a knowledge base.

**Architecture**:
- `.beads/issues.jsonl` — git-tracked source of truth (branches when you branch)
- Local SQLite cache (`.beads/beads.db`) — fast queries, gitignored
- Background daemon syncs between them with 5-second debounce
- Hash-based IDs (`bd-a1b2`) prevent merge conflicts across parallel agents
- Written in Go, 130k+ lines, 29 contributors

**Key innovations**:
- **Dependency graph**: `blocks`, `parent-child`, `related`, `discovered-from` relationships
- **Memory decay**: Closed tasks get LLM-summarized, preserving decisions while freeing context
- **Git-native**: `git checkout -b feature` automatically branches agent memory
- **Conflict-free**: Hash IDs enable multi-agent task creation without collisions

**Weaknesses**:
- Agents don't proactively check it — needs explicit prompting
- Context fade in long sessions
- Community ecosystem still maturing
- Optimized for "this week's work", not long-term knowledge

**Best for**: Multi-agent orchestration, teams running parallel agents on separate branches.

Sources:
- https://github.com/steveyegge/beads
- https://steve-yegge.medium.com/introducing-beads-a-coding-agent-memory-system-637d7d92514a
- https://ianbull.com/posts/beads/
- https://yuv.ai/blog/beads-git-backed-memory-for-ai-agents-that-actually-remembers

---

### 2. Claude-Mem (thedotmack) — Observation Database + Vector Search

**Philosophy**: Memory should be *automatic* — capture everything, compress it, make it searchable.

**Architecture**:
- SQLite at `~/.claude-mem/claude-mem.db` with FTS5 full-text search
- ChromaDB for vector/semantic search
- Bun worker service on port 37777
- 5 lifecycle hooks (SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd)

**Key innovations**:
- **Automatic capture**: Hooks record everything without manual intervention
- **AI compression**: Raw observations (1k-10k tokens) compressed to ~500-token "learnings"
- **3-layer retrieval**: Index → Timeline → Full details (~10x token savings over naive RAG)
- **Typed observations**: decision, bugfix, feature, refactor, discovery, change
- CLAUDE.md becomes a *dynamic projection* of database content per session

**Weaknesses**:
- Requires Bun runtime + ChromaDB running locally
- More infrastructure than alternatives
- Still depends on Claude recognizing when to search

**Best for**: Solo developers wanting "set it and forget it" memory. #1 GitHub trending (1,739 stars in 24 hours, Feb 2026).

Sources:
- https://github.com/thedotmack/claude-mem
- https://deepwiki.com/thedotmack/claude-mem
- https://docs.claude-mem.ai/architecture/overview

---

### 3. Episodic Memory (Jesse Vincent/obra) — Conversation Archive + Semantic Search

**Philosophy**: Past conversations *are* the memory — archive them, index them, search them.

**Architecture**:
- Startup hook copies conversation JSONL to archive before 30-day expiry
- SQLite with vector search for semantic retrieval
- MCP tool wrapper for programmatic access
- Haiku subagent summarizes retrieved conversations

**Key innovations**:
- **Zero manual effort**: Captures everything from conversation logs automatically
- **Cross-project**: Not firewalled by project, enabling cross-codebase pattern recognition
- **Semantic search**: Conceptual matching, not just keyword

**Weaknesses**:
- Agent must consciously invoke search — not autonomous recall
- Raw conversation logs are noisy
- No structure (no dependency graphs, no task state)

**Best for**: Lightest-weight option. Preserves reasoning across sessions without workflow changes.

Sources:
- https://blog.fsck.com/2025/10/23/episodic-memory/
- https://github.com/obra/episodic-memory

---

## Tier 2: Orchestration Platforms

### Claude-Flow (ruvnet) — Enterprise Swarm Orchestration

- SQLite at `.swarm/memory.db` with 12 specialized tables
- 87 MCP tools for orchestration
- Hierarchical or mesh swarm patterns
- Overkill for solo use; best for full orchestration stacks

Source: https://github.com/ruvnet/claude-flow

---

## Tier 3: Emerging Alternatives

| System | Approach | Key Differentiator |
|--------|----------|-------------------|
| **Knowns** | CLI task/doc manager with MCP | AI auto-extracts knowledge into project docs |
| **OneContext** | Persistent context layer | Cross-device, cross-collaborator shared memory |
| **OpenSpec / cc-sdd** | Spec-driven development | Requirements->design->tasks workflow |
| **memU (NevaMind)** | Local knowledge graph | Builds preference/habit graph, reduces token costs |

---

## Memory Type Taxonomy

| Memory Type | What It Stores | Systems |
|-------------|---------------|---------|
| **Working** | Current session context | CLAUDE.md, context window |
| **Episodic** | "What happened" — past sessions | Episodic Memory, Claude-Mem |
| **Semantic** | "What I know" — patterns, facts | Claude-Mem learnings, Knowns |
| **Procedural** | "How to do things" — task graphs | Beads, Claude-Flow |

No single system covers all four well. The emerging consensus is you need at least two layers.

---

## Status: DECIDED — Three-Layer Rollout

**Date**: 2026-02-11

All three memory types will be implemented (right tool for the right job):

1. **Phase 1 — Beads (procedural)**: Static Go binary, easiest NixOS packaging, immediate value for task tracking. IN PROGRESS.
2. **Phase 2 — Episodic Memory (episodic)**: Cross-session conversation recall. Waiting for upstream bug fixes (#47, #53).
3. **Phase 3 — Claude-Mem or equivalent (semantic)**: Compressed learnings and observations. Waiting for critical process leak (#1010) to be resolved.

See `docs/agentic-memory-options-comparison.md` for detailed evaluation of each option.
