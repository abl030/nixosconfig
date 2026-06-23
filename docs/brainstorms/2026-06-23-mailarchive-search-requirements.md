---
date: 2026-06-23
topic: mailarchive-search
---

# Mail Archive Search — Requirements

## Summary

Build one hybrid search system over the live doc2 mail archive — keyword *and* semantic — exposed as two surfaces over a single shared index: an off-the-shelf terminal client for human keyword/tag search, and a read-only MCP tool that gives the agents Andy actively drives both exact-match and semantic ("virtual brain") retrieval. Everything runs locally on doc2; the corpus never leaves the fleet.

---

## Problem Frame

The mail archive (GitHub #227) is live on doc2 but **cold** — `mutt -f` browse-only, no search, by design. Two unmet needs converge:

- **Human:** Gmail and O365 web search are effectively unusable — Andy can't find mail he *knows* exists in his own mailboxes. The archive is the only durable, deletion-resistant copy (including the 4,148 recovered deleted-history messages merged into `work/INBOX`), and there is no way to query it.
- **Agent:** the fleet can't log into Gmail/O365 at all. A searchable archive is the only path for an agent to answer "what did Andy agree with the cooper about the barrel repair?" — turning the mail into context the agents can reason over.

The cost today: known information is unfindable, and the agents are blind to a rich record of Andy's life and work.

---

## Key Decisions

- **One project, not phased.** Keyword index, embeddings, TUI, and the MCP brain ship together as a single deliverable.
- **Hybrid: one spine, two faces.** A single keyword index (notmuch/Xapian over the Maildir) powers both the human TUI and the agent's exact-match leg; a vector store adds the semantic leg. The agent tool fuses both — embeddings alone miss exact strings (invoice numbers, surnames); keyword alone misses meaning.
- **Local, CPU-only, on doc2.** Embeddings compute on doc2's CPU — a one-time multi-hour bootstrap, then trivial incremental work. No GPU, no third-party embedding API; the corpus (personal + Cullen work mail) never leaves the box. GPU acceleration (the idle prom GTX 1080) was considered and rejected as unneeded engineering at this scale.
- **Human surface = off-the-shelf TUI + ask-an-agent; no owned web code.** Desktop keyword search via a packaged notmuch TUI over SSH; phone/semantic search by asking an agent (which already holds the MCP tool). No custom web app, no Roundcube.
- **Agent surface = read-only, doc1-only, metadata-first MCP.** A search tool returning ranked metadata + snippet, plus a gated full-body fetch. No write/compose/delete. Deploys only to doc1, per the `homelab.mcp` pattern (#234).
- **hermes and any always-on / Telegram agent are excluded.** The brain serves the agents Andy actively drives, where he is in the loop. A Telegram-reachable, prompt-injectable agent must never reach personal + work mail.
- **The index is as sensitive as the mail.** A Xapian index or vector store is the corpus in searchable form — same secrecy, ownership, and backup class as the Maildir. Search query strings stay out of Loki: the fleet can read Loki, and queries leak intent.
- **Body + filenames, not attachment contents.** Index message bodies, headers, and attachment filenames (filenames also folded into the embeddings). Extracting text inside PDFs/docx is a deliberate non-goal.

---

## Actors

- A1. **Andy (human)** — searches his own archive for known mail he can't find upstream; keyword/tag from a desktop TUI, semantic by asking an agent.
- A2. **Driven agents** — Claude Code sessions on doc1 that Andy is actively running; call the brain as a tool mid-task.
- A3. **The indexer** — an unprivileged doc2 service that reads the Maildir read-only and maintains the keyword index + vector store incrementally.
- A4. **Excluded actors** — hermes and any always-on / Telegram / lower-trust agent; they have no tool and no credential.

---

## Requirements

**Corpus & indexing**
- R1. Index the live `gmail/` and `work/` Maildirs on doc2. Exclude the legacy `Mailstore/` tree (being deleted with the MailStore VM).
- R2. Index message body, headers, and attachment filenames. Do not extract or index text inside attachments.
- R3. Keep the index current incrementally as new mail arrives, hooked off the existing mbsync sync cycle, with no manual rebuild. The corpus is append-only (server deletions never propagate), so indexing never deletes.
- R4. Read the Maildir read-only; the indexer never writes to or mutates the archive.

**Keyword surface (human)**
- R5. Provide keyword / tag / header / date search over the full archive via an off-the-shelf terminal client run on doc2 over the existing bastion SSH path. No custom-maintained UI code.
- R6. Searching an attachment filename surfaces the email that carried it.

**Semantic + agent surface**
- R7. Expose a read-only MCP tool to the agents Andy drives on doc1. It performs hybrid retrieval (semantic + keyword) and returns ranked results.
- R8. Default results are metadata + a short snippet (Message-ID, date, from, subject, snippet), not full bodies. A separate gated call returns one full message body (HTML stripped, attachment filenames listed) under a content-length cap.
- R9. The tool is read-only — no compose, send, tag, or delete — and supports filtering by folder, date, and sender.
- R10. Embeddings are computed by a local model on doc2 CPU; no message content is sent to any third-party service.

**Security & exposure**
- R11. The index and vector store are treated as sensitive as the Maildir: owned by an unprivileged service user, not world-readable, same backup and secrecy class.
- R12. The MCP tool and its credential deploy to doc1 only (per the `homelab.mcp` pattern); not to any other host, and explicitly not to hermes or any Telegram / always-on agent.
- R13. Network exposure is tailnet-only under the default-deny ACL; no LAN/WAN listener serves mail.
- R14. Search query strings are not shipped to Loki or any fleet-readable log.

**Operations**
- R15. The one-time bootstrap embed runs nice'd / off-peak so it does not starve doc2's other services (RAM-tight, shared VM).
- R16. Delivered as a NixOS-native module under `modules/nixos/services/`, sops for any secrets, signed deploy, no image pinning — repo conventions.

---

## Key Flows

- F1. **Human keyword search**
  - **Trigger:** Andy needs a known email he cannot find in Gmail/O365.
  - **Actors:** A1.
  - **Steps:** SSH to doc2 → open the notmuch TUI → keyword/tag/sender/date query → ranked results → read the message.
  - **Covered by:** R5, R6.
- F2. **Agent hybrid search (the brain)**
  - **Trigger:** an agent Andy is driving needs mail context for a task.
  - **Actors:** A2.
  - **Steps:** agent calls the search tool with a query + optional filters → receives ranked metadata + snippets → if it needs detail, calls the gated body fetch for a specific Message-ID → uses the body in its task.
  - **Covered by:** R7, R8, R9.
- F3. **Incremental index**
  - **Trigger:** mbsync pulls new mail on its timer.
  - **Actors:** A3.
  - **Steps:** indexer detects new messages → updates the keyword index → embeds the new (cleaned, deduped) bodies on CPU → upserts vectors, idempotent by Message-ID.
  - **Covered by:** R3, R10.

---

## Acceptance Examples

- AE1. **Covers R2, R6.** Given an email whose only mention of "barrel repair" is the body line "see attached quote" plus an attachment named `Barrel Repair Quote.pdf`, when Andy searches "barrel repair", the email is found (by body text and filename); the PDF's internal contents are not searched.
- AE2. **Covers R8.** Given an agent calls the search tool, when results return, each item carries Message-ID / date / from / subject / snippet and no full body; the full body returns only on a subsequent gated fetch.
- AE3. **Covers R7.** Given the query "invoice 4471", the exact string is found via the keyword leg even when semantically generic; given "that argument about the corked vintage", a semantically related email with different wording is found via the embedding leg.
- AE4. **Covers R12.** Given hermes (or any Telegram agent) attempts mail search, no tool or credential exists for it — the capability is absent, not merely denied at runtime.

---

## Scope Boundaries

**Deferred (maybe later, not now):**
- Searching inside attachment text (PDF/docx extraction) — the biggest cost/complexity multiplier and a parser attack surface.
- Ambient / standing-memory agent — a continuously maintained life model the agents draw on unprompted. A genuine unknown, revisited only after living with bounded retrieval.
- A standalone web search UI — revisit only if "ask an agent" proves insufficient for human mobile use.
- GPU-accelerated embedding (the idle prom 1080) — available if scale ever demands it.

**Outside this system's identity (positioning, not deferral):**
- Access for hermes or any always-on / Telegram / lower-trust agent.
- Any third-party or cloud embedding/search API — the corpus stays local.
- Re-indexing or preserving the legacy `Mailstore/` tree — it is being deleted.
- A webmail / read-write mail client (Roundcube etc.) — this is search, not mail management.

---

## Dependencies / Assumptions

- `homelab.services.mailarchive` is live on doc2, pulling `work` (O365) and `gmail` into Maildir at `/mnt/data/Life/Andy/Email/<account>/`, append-only (Remove None / Expunge None).
- The Maildir is a **`hard` NFSv4 mount from tower (Unraid)**, not virtiofs — it stalls if tower/prom is down, and the live Maildirs are mode `0700` owned by the `mailarchive` service uid. The indexer must run as / share that uid-group, and the index must live on doc2's virtiofs (`/mnt/virtio`), never on the NFS path.
- doc2: 12 vCPU, ~29 GB RAM (tight — shared with immich/paperless/etc.), **no GPU**. The bootstrap embed must be nice'd.
- notmuch and mu have **no NixOS service module** (package only) — the indexer is a hand-written module under `modules/nixos/services/`, not an upstream service.
- The `homelab.mcp` pattern (#234: creds to `/run/secrets/mcp` on doc1 only, siblings purged) is the deployment path for the MCP tool.
- Reusable patterns: `modules/nixos/services/tailscale-share.nix` (tailnet pinhole), `modules/nixos/lib/mk-pg-container.nix` (pgvector, if a single-file vector store is ever outgrown), and the mailarchive systemd-hardening template.

---

## Outstanding Questions

Nothing here blocks planning — every product and scope decision is settled. These are planning-time choices for `ce-plan` to resolve against the codebase and the least-privilege bar.

**Planning decisions carrying a security lens:**
- doc2↔doc1 query path for the MCP: forced-command `ssh doc2 'notmuch … --format=json'` from doc1's wrapper (reuses the audited bastion path, no new listener) vs a tailnet HTTP endpoint on doc2. A security + simplicity trade.
- Index / vector storage location and backup treatment: keep the keyword index outside the offsite backup set (rebuildable from the Maildir) while backing up the vector store (expensive to recompute), or treat both as rebuildable?
- Query-log redaction mechanism: how query strings are kept out of Loki (don't log them / log below the shipped level / a local `0600` file Alloy does not scrape).

**Mechanical planning decisions:**
- Which TUI (alot vs aerc) and its read-only notmuch configuration.
- Exact embedding model + dimension (e.g. nomic-embed-text-v1.5) and CPU runtime (llama.cpp vs ollama).
- Email preprocessing: quote/signature stripping (e.g. talon), near-duplicate dedup, chunking for long bodies.
- Vector store: sqlite-vec (single file, easy to secure and back up) vs pgvector via `mk-pg-container`.

---

## Sources / Research

Four research agents (2026-06-23), grounded in live probes + repo reads:

- **Current service:** `modules/nixos/services/mailarchive.nix`, `docs/wiki/services/mailarchive.md`. Corpus ≈ 47 GB, ~98k messages (gmail ~66k / work ~31k) on tower NFS.
- **DB pattern:** `modules/nixos/lib/mk-pg-container.nix` (pgvector proven in production by immich).
- **MCP pattern:** `modules/nixos/services/mcp.nix` (doc1-only, #234), `.claude/agents/*.md`, `scripts/mcp-*.sh`.
- **Exposure / backup:** `modules/nixos/services/tailscale-share.nix`; `/mnt/data/Life` is already in doc2's `kopia-mum` offsite backup (`hosts/doc2/configuration.nix`).
- **Engines:** notmuch (Xapian, JSON query, first-class read-only mode, no NixOS service module) chosen over mu (Guile-only bindings) and Dovecot + Roundcube (heavy, RCE-prone, keyword-only). External: notmuchmail.org; `igor47/notmuchproxy` (read-only notmuch MCP prior art); `mailgun/talon` (quote/signature stripping); `nomic-embed-text-v1.5` (8k context, Apache-2.0); `alexgarcia.xyz` sqlite-vec.
- **GPU reality:** igpu = `gfx1036` (2 CU, 2 GB shared VRAM, no ROCm); epi's Arc A380 is capable but the box roams / is usually off; the idle prom GTX 1080 is the only real GPU candidate — all set aside in favour of CPU-on-doc2 at this scale.
