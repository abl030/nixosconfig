---
date: 2026-05-14
topic: cratedigger-local-metadata-api-boundary
issue: 228
supersedes:
  - docs/brainstorms/2026-05-14-musicbrainz-cratedigger-maintenance-boundary-requirements.md
  - docs/plans/2026-05-14-004-fix-musicbrainz-cratedigger-maintenance-plan.md
---

# Cratedigger Local Metadata API Boundary and Lidarr Cleanup

## Summary

Cratedigger should run only when the two local metadata APIs it depends on are healthy: the local MusicBrainz API and the local Discogs API. Lidarr and LMD are retired scope; active configuration, monitoring, and requirements should stop preserving Lidarr-facing behavior.

---

## Problem Frame

Issue #228 started as a MusicBrainz PostgreSQL lifecycle problem, but the local stack has drifted into a confusing shape. The repo still carries Lidarr service configuration and MusicBrainz LMD/Lidarr Metadata wiring, while the current music workflow is centered on cratedigger and Beets.

The current Beets configuration uses the local MusicBrainz mirror for MusicBrainz lookups, patches the Discogs plugin to use the local Discogs mirror, and patches the lyrics plugin to use local LRCLIB. Cratedigger also treats MusicBrainz and Discogs as first-class metadata sources. The operationally important dependency boundary for cratedigger is therefore the local MusicBrainz API plus the local Discogs API.

Optional Beets enrichment sources such as iTunes, Amazon, albumart.org, and Last.fm are not part of this maintenance gate. Their outages should not decide whether cratedigger runs.

---

## Actors

- A1. Operator or deployment agent: performs metadata API maintenance, verifies health, and resumes dependent services.
- A2. Cratedigger workflow: scheduled pipeline, web UI, importer, preview worker, and validation paths that can consume local metadata APIs.
- A3. Local MusicBrainz API: the local `/ws/2` mirror used by cratedigger and Beets.
- A4. Local Discogs API: the local `discogs.ablz.au` mirror used by cratedigger and the patched Beets Discogs plugin.
- A5. Beets: the local music tagger and library manager whose current configuration defines which metadata services matter to imports.

---

## Key Flows

- F1. MusicBrainz API outage or maintenance
  - **Trigger:** The local MusicBrainz API is down, degraded, or intentionally in maintenance.
  - **Actors:** A1, A2, A3
  - **Steps:** Cratedigger API-producing units are held; MusicBrainz work proceeds; the local MusicBrainz API is verified; a representative cratedigger MusicBrainz metadata path is probed; cratedigger resumes only after the gate is clear.
  - **Outcome:** Cratedigger does not hammer or partially consume a degraded MusicBrainz mirror.
  - **Covered by:** R1, R3, R4, R5, R8, R9, R10

- F2. Discogs API outage, import, or maintenance
  - **Trigger:** The local Discogs API is down, degraded, importing, empty, or reporting a non-healthy mirror state.
  - **Actors:** A1, A2, A4
  - **Steps:** Cratedigger API-producing units are held; Discogs import or recovery completes; the local Discogs API health and a representative cratedigger Discogs metadata path are verified; cratedigger resumes only after the gate is clear.
  - **Outcome:** Discogs-sourced cratedigger workflows do not run against an unavailable or empty Discogs mirror.
  - **Covered by:** R2, R3, R4, R5, R6

- F3. Retired Lidarr/LMD cleanup
  - **Trigger:** The stack is updated for issue #228.
  - **Actors:** A1, A2, A5
  - **Steps:** Active Lidarr service, proxy, monitor, and secret surfaces are removed or disabled; LMD/Lidarr Metadata requirements are removed unless a current non-Lidarr consumer is found; docs and comments that guide future agents are tightened around cratedigger, Beets, MusicBrainz API, Discogs API, and LRCLIB.
  - **Outcome:** Future planning does not preserve stale Lidarr-facing behavior.
  - **Covered by:** R11, R12, R13, R14, R15, R16

- F4. Routine Beets and cratedigger operation
  - **Trigger:** A normal cratedigger run or Beets import/validation path starts.
  - **Actors:** A2, A3, A4, A5
  - **Steps:** Beets and cratedigger use local MusicBrainz and local Discogs metadata; Beets may also use local LRCLIB for lyrics; optional public enrichment providers remain outside the cratedigger gate.
  - **Outcome:** The metadata boundary is narrow enough to operate, and broad optional enrichment outages do not create false maintenance events.
  - **Covered by:** R4, R5, R15, R16, R17

---

## Requirements

**Cratedigger metadata API gate**
- R1. Cratedigger API-producing components must be held when the local MusicBrainz API is unhealthy or intentionally in maintenance.
- R2. Cratedigger API-producing components must be held when the local Discogs API is unhealthy, intentionally in maintenance, or not serving a populated mirror.
- R3. The hold must cover scheduled automation, long-running workers, importer paths, preview paths, and web UI paths when they can generate MusicBrainz or Discogs API traffic.
- R4. Cratedigger must not resume just because one metadata API recovered; both local MusicBrainz API and local Discogs API gates must be clear.
- R5. Resume must require representative cratedigger metadata probes for both MusicBrainz-sourced and Discogs-sourced paths.
- R6. Discogs monthly import or recovery states that make the API report a non-healthy mirror state must hold cratedigger until the API is healthy again.

**MusicBrainz database lifecycle**
- R7. MusicBrainz must still move off the upstream compose-owned PostgreSQL lifecycle and onto a fleet-managed database boundary.
- R8. Routine upstream MusicBrainz updates must not be able to change the PostgreSQL major version that owns local MusicBrainz persistent database state.
- R9. Required PostgreSQL extensions and runtime settings for the local MusicBrainz API must be owned and verified by the fleet-managed database lifecycle.
- R10. MusicBrainz cutover verification must focus on the local MusicBrainz API, replication readiness, and search/index behavior needed by that API. LMD verification is not required.

**Lidarr and LMD retirement**
- R11. Active Lidarr runtime surfaces must be removed or disabled, including service enablement, local proxy exposure, health monitoring, and MCP-secret plumbing where they are no longer used.
- R12. LMD/Lidarr Metadata and the LMD proxy shim must be removed from the active MusicBrainz stack unless planning proves a current non-Lidarr consumer still depends on them.
- R13. Requirements, active plans, monitoring labels, option descriptions, and high-signal comments must stop describing Lidarr as an active consumer.
- R14. Historical docs may remain as archive material, but current brainstorm and plan artifacts for issue #228 must be marked superseded or rewritten around the new boundary.

**Beets dependency shape**
- R15. The Beets configuration is the source of truth for Beets-facing metadata needs: local MusicBrainz API, patched local Discogs API, and local LRCLIB for lyrics.
- R16. LRCLIB may remain for Beets lyrics behavior, but it is not a cratedigger maintenance gate.
- R17. Optional public Beets enrichment sources, including iTunes, Amazon, albumart.org, and Last.fm, are explicitly outside the cratedigger maintenance gate.

**Operational discipline**
- R18. The solution must preserve the fleet's least-privilege database posture, including authenticated access and no broad trusted PostgreSQL access from container networks.
- R19. The maintenance boundary must be obvious to a future operator or agent: cratedigger is coupled to MusicBrainz API health and Discogs API health, not to Lidarr/LMD or optional public enrichment providers.

---

## Acceptance Examples

- AE1. **Covers R1, R3, R4, R5.** Given the local MusicBrainz API is down and the local Discogs API is healthy, when a cratedigger timer or web metadata path would run, cratedigger remains held until MusicBrainz API health and a representative MusicBrainz-sourced cratedigger probe pass.
- AE2. **Covers R2, R4, R5, R6.** Given the Discogs API is reachable but reports a non-healthy or empty mirror state during import, when cratedigger would run a Discogs-sourced path, cratedigger remains held until Discogs health and a representative Discogs-sourced cratedigger probe pass.
- AE3. **Covers R4, R5, R19.** Given both metadata APIs are healthy, when cratedigger resumes, both MusicBrainz-sourced and Discogs-sourced metadata paths have been checked and the operator can see why the gate cleared.
- AE4. **Covers R10, R12, R14.** Given MusicBrainz database cutover verification is running, when LMD is absent, the cutover can still succeed because LMD is no longer a required behavior.
- AE5. **Covers R16, R17.** Given iTunes, Amazon, albumart.org, Last.fm, or LRCLIB is unavailable, when MusicBrainz API and Discogs API are healthy, cratedigger is not held solely for those optional or non-gating providers.
- AE6. **Covers R11, R13.** Given Lidarr is retired, when a future agent reads active service config and current issue #228 docs, they do not find Lidarr described as a live dependency that must be preserved.

---

## Success Criteria

- Future planning no longer needs to infer which metadata services gate cratedigger: only local MusicBrainz API and local Discogs API do.
- Lidarr and LMD assumptions are removed from the active issue #228 path.
- Beets-facing needs are documented narrowly: local MusicBrainz, local Discogs, and local LRCLIB, with only MusicBrainz and Discogs affecting cratedigger availability.
- MusicBrainz database isolation can still proceed, but its verification target is the current API consumer shape rather than retired Lidarr/LMD behavior.

---

## Scope Boundaries

- Do not gate cratedigger on iTunes, Amazon, albumart.org, Last.fm, or other optional public Beets enrichment sources.
- Do not gate cratedigger on LRCLIB.
- Do not preserve LMD/Lidarr Metadata behavior for its own sake.
- Do not rebuild cratedigger's search model, download strategy, or product workflow as part of this requirements reset.
- Do not replace the full MusicBrainz compose stack with native NixOS services unless planning proves that database extraction or LMD removal requires a narrow supporting change.
- Do not delete archived historical docs solely because they mention Lidarr; clean active config, current requirements/plans, monitoring, and agent-facing guidance first.
- Do not create a general fleet-wide maintenance orchestration framework from this issue.

---

## Key Decisions

- Metadata gate is API-level, not source-everything: only local MusicBrainz API and local Discogs API decide whether cratedigger runs.
- Discogs is first-class: cratedigger must be held when the local Discogs API is unhealthy, the same way it is held for MusicBrainz API maintenance.
- Lidarr/LMD is retired: current work should remove stale Lidarr-facing requirements instead of preserving compatibility.
- LRCLIB is Beets-facing but non-gating: it can remain for lyrics without joining the cratedigger maintenance boundary.
- The old issue #228 requirements and plan are superseded by this narrower dependency boundary.

---

## Dependencies / Assumptions

- `modules/home-manager/services/beets.nix` currently configures Beets to use the local MusicBrainz mirror, patches Discogs to the local Discogs mirror, and patches lyrics to local LRCLIB.
- Cratedigger currently has MusicBrainz and Discogs metadata paths in its upstream source and local wrapper.
- `modules/nixos/services/discogs.nix` already exposes a health-aware local Discogs API whose healthy state distinguishes a populated mirror from an empty or awaiting-import mirror.
- `hosts/doc2/configuration.nix` still enables Lidarr at the time of this brainstorm, even though Lidarr is retired by product decision.
- `modules/nixos/services/musicbrainz.nix` still includes LMD/Lidarr Metadata behavior at the time of this brainstorm.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R2, R3][Technical] Which exact systemd units and helper commands should be held for cratedigger's MusicBrainz and Discogs API boundary?
- [Affects R5][Technical] What are the smallest representative MusicBrainz-sourced and Discogs-sourced cratedigger probes that prove the gate can clear without creating heavy API load?
- [Affects R11, R12, R13][Technical] What is the exact active cleanup list for Lidarr and LMD across service modules, host config, monitoring, local proxy, MCP secret plumbing, and high-signal comments?
- [Affects R7, R8, R9][Technical] What is the safest MusicBrainz database migration path once LMD is removed from the required behavior set?
