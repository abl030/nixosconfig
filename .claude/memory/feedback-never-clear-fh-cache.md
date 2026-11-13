---
name: feedback-never-clear-fh-cache
description: Never delete ~/.cache/fh on doc1 during disk cleanup — it is the family-history publishing cache
metadata:
  type: feedback
---

Never delete or suggest deleting `~/.cache/fh` on doc1 (or any host), even when the disk is full.

**Why:** It is an integral part of publishing the family-history site. fh prunes it itself. Wiping it frees nothing durable because the next build regenerates it at once (12+ minutes re-shrinking every photo). The user has had to correct agents about this more than once (2026-11-10, 2026-11-14). `hosts/proxmox-vm/agent-disk-cleanup.nix` keeps it since 1898e612.

**How to apply:** For doc1 disk pressure, look at Codex/Claude transcripts, idle `~/.claude/jobs`, `~/.local/share/family-history/*-scratch`, the uv cache, cargo `target/` dirs and old `/tmp`. Never touch fh.
