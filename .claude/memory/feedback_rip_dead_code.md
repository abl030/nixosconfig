---
name: feedback-rip-dead-code
description: When the user calls something old/experimental/unused, default to ripping it out completely rather than archiving or guarding it behind a flag.
metadata:
  type: feedback
---

When the user describes code/config/tooling as "old", "unused", "out of sync with reality", "an experiment", or similar — default to **deleting it entirely** (files, references, docs, plans, skills, secrets, host config consumers) rather than archiving, gating, or leaving stubs.

**Why:** the user is past the hand-holding phase of homelab management. They trust the agent to do destructive work end-to-end and prefer a clean repo over historical baggage. Tofu/Terranix VM automation got the chop on 2026-05-21 — multi-directory, multi-skill, multi-doc rip done in one session. "One day we'll build a proxmox sub-agent" was floated but explicitly deferred.

**How to apply:**
- When ripping, follow imports/consumers all the way through. `nix flake check` will find the dead refs you missed (missing options, deleted files, etc.).
- Don't leave migration scaffolding behind ("operator must later…" paths). Per CLAUDE.md "DO THE MIGRATION".
- Delete the related skills/agents/docs in the same session — don't bookmark them for later.
- Format and lint after; reference [[reference-tower-unraid]] when adjusting Fleet Overview-style docs since the homelab isn't purely Proxmox.

Counter-case: if it's data the user might want to grep later (incident postmortems, beads archive, plans/brainstorms), leave it. Code/tooling/automation is the rip target; historical narrative documents are not.
