---
date: 2026-05-14
topic: musicbrainz-cratedigger-maintenance-boundary
status: superseded
superseded_by: docs/brainstorms/2026-05-14-cratedigger-local-metadata-api-boundary-requirements.md
---

# MusicBrainz Database Isolation and Cratedigger Maintenance Boundary

> Superseded on 2026-05-14 by `docs/brainstorms/2026-05-14-cratedigger-local-metadata-api-boundary-requirements.md`.
> The newer scope removes Lidarr/LMD as active requirements and gates cratedigger only on the local MusicBrainz API and local Discogs API.

## Summary

MusicBrainz should move off the upstream compose-owned PostgreSQL lifecycle and onto a fleet-managed database boundary. During MusicBrainz database maintenance, cratedigger should be paused as part of the same operational event so it cannot keep generating heavy MusicBrainz API traffic while the mirror is being rebuilt, upgraded, restored, or verified.

---

## Problem Frame

Issue #228 exists because the MusicBrainz mirror's PostgreSQL state currently depends on the upstream `musicbrainz-docker` compose stack. On 2026-05-09 upstream moved the database image from PostgreSQL 16 toward PostgreSQL 18; the next local update attempted to run a changed database runtime against existing on-disk state and failed because the new image no longer supplied `pg_amqp.so`.

The current pin recovered service, but it also freezes unrelated upstream improvements behind a database-runtime problem. PostgreSQL is the part that needs explicit lifecycle ownership because its data directory, major version, and extension set must move only during intentional database maintenance.

Cratedigger is a heavy local MusicBrainz consumer. Its periodic pipeline, web metadata paths, and import/validation workflows can produce enough local API traffic that leaving cratedigger up during MusicBrainz database work turns planned maintenance into a noisy pressure event. For this work, MusicBrainz and cratedigger are one operational boundary: when the MusicBrainz database is in maintenance, cratedigger is in maintenance too.

---

## Actors

- A1. Operator or deployment agent: performs MusicBrainz database maintenance, verifies service health, and resumes dependent workflows.
- A2. MusicBrainz mirror stack: provides the local MusicBrainz API, replication, search/index support, LMD metadata service, and related mirror data.
- A3. Cratedigger workflow: consumes MusicBrainz metadata through scheduled pipeline runs, web metadata lookups, and import/validation paths.

---

## Key Flows

- F1. MusicBrainz database migration or upgrade
  - **Trigger:** The operator or deployment agent starts intentional MusicBrainz database maintenance.
  - **Actors:** A1, A2, A3
  - **Steps:** Cratedigger is paused first; MusicBrainz database work proceeds; MusicBrainz health and metadata paths are verified; cratedigger resumes only after verification succeeds.
  - **Outcome:** The MusicBrainz database changes without cratedigger hammering a degraded or unavailable mirror.
  - **Covered by:** R1, R4, R5, R6, R7, R8, R10

- F2. Routine upstream MusicBrainz update
  - **Trigger:** A normal flake or upstream compose update brings in non-database MusicBrainz changes.
  - **Actors:** A1, A2, A3
  - **Steps:** The update applies without silently changing the PostgreSQL major version or required extension set; MusicBrainz restarts normally; cratedigger remains available unless a database maintenance boundary is active.
  - **Outcome:** Routine upstream movement no longer creates accidental database-major maintenance.
  - **Covered by:** R1, R2, R3, R11

- F3. Failed verification or rollback
  - **Trigger:** MusicBrainz database migration, restore, replication, search, or LMD verification fails.
  - **Actors:** A1, A2, A3
  - **Steps:** Cratedigger remains paused; the operator follows the recovery path; verification is retried; cratedigger resumes only after the mirror is healthy enough for normal consumers.
  - **Outcome:** A failed database change does not cascade into a cratedigger traffic storm or partial-import confusion.
  - **Covered by:** R5, R6, R7, R9, R10

---

## Requirements

**Database lifecycle**
- R1. MusicBrainz must run against a PostgreSQL instance whose major version is controlled by this fleet's database management pattern, not by the upstream compose database image.
- R2. Routine upstream MusicBrainz updates must not be able to change the PostgreSQL major version that owns MusicBrainz persistent database state.
- R3. Required PostgreSQL extensions and runtime settings for the MusicBrainz cluster must be owned and verified by the fleet-managed database lifecycle.
- R4. Migration must preserve existing MusicBrainz state where practical, or explicitly classify any rebuilt mirror state as re-downloadable and safe to regenerate.

**Cratedigger maintenance boundary**
- R5. MusicBrainz database maintenance must pause cratedigger components that can generate MusicBrainz API load.
- R6. The pause must cover both scheduled automation and long-running cratedigger workers or UI paths when they can pressure the MusicBrainz mirror.
- R7. Cratedigger must not resume automatically just because the database process starts; resume requires MusicBrainz verification that is good enough for normal cratedigger consumption.
- R8. The maintenance flow must make it obvious to an operator or future agent that MusicBrainz and cratedigger are coupled for database maintenance.

**Migration and recovery**
- R9. The migration must have a defined rollback or recovery path until the fleet-managed database has been verified.
- R10. Verification must cover the MusicBrainz API, replication readiness, search/index behavior, LMD metadata behavior, and cratedigger's ability to consume the mirror after resume.
- R11. The upstream MusicBrainz input should return to normal tracking after the database lifecycle risk is removed.

**Operational discipline**
- R12. The change must follow the fleet's least-privilege PostgreSQL pattern, including authenticated TCP access rather than broad trust from container networks.
- R13. The change must avoid introducing a broad manual-maintenance burden for non-database MusicBrainz services unless planning finds a separate concrete failure mode.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R11.** Given MusicBrainz has been migrated, when a routine upstream MusicBrainz update changes compose metadata or non-database images, the PostgreSQL major version serving MusicBrainz remains unchanged and the upstream input can keep moving.
- AE2. **Covers R5, R6, R8.** Given MusicBrainz database maintenance starts, when an operator or deployment agent follows the maintenance flow, cratedigger's API-producing automation and workers are paused before database work begins.
- AE3. **Covers R7, R10.** Given the new MusicBrainz database process is running, when API, replication, search/index, or LMD verification has not passed, cratedigger remains paused.
- AE4. **Covers R9.** Given migration verification fails, when the operator chooses rollback or recovery, the old database state or a documented rebuild path is still available and cratedigger has not resumed against a broken mirror.
- AE5. **Covers R10.** Given verification succeeds and cratedigger resumes, when a representative cratedigger metadata or validation path is exercised, it can consume the local MusicBrainz mirror without falling back to uncontrolled upstream pressure.
- AE6. **Covers R12.** Given the new database is active, when another container on the host network tries to reach PostgreSQL outside the intended service credential path, it does not receive broad trusted database access.

---

## Success Criteria

- MusicBrainz PostgreSQL major-version changes happen only through intentional database maintenance.
- The `pg_amqp.so` class of failure cannot be reintroduced by an ordinary upstream compose update.
- Cratedigger is quiet during MusicBrainz database maintenance and resumes only after MusicBrainz is healthy enough to serve it.
- The issue, requirements doc, and later plan give future agents a single operational story instead of treating MusicBrainz and cratedigger as unrelated services.
- The upstream MusicBrainz input can be unpinned without giving upstream database images authority over local persistent state.

---

## Scope Boundaries

- Do not build a cratedigger-side throttle, partial maintenance mode, or degraded-read mode for this issue.
- Do not migrate unrelated MusicBrainz compose services unless database extraction requires a narrow adjustment.
- Do not replace the whole MusicBrainz compose stack with native NixOS services as part of this work.
- Do not create a general fleet-wide maintenance orchestration framework from this issue.
- Do not broaden this into cratedigger API-behavior optimization beyond pausing it during MusicBrainz database maintenance.
- Do not add ongoing digest pinning or manual image-refresh work for non-database MusicBrainz services without a separate concrete failure mode.

---

## Key Decisions

- Database-only ownership boundary: PostgreSQL is the component whose persistent state is unsafe to leave under upstream image churn.
- Unified maintenance boundary: MusicBrainz and cratedigger are operationally coupled for database maintenance, even if they remain separate runtime units.
- Pause rather than throttle: during database maintenance, cratedigger should be down or quiet, not allowed to limp along against an unstable mirror.
- Keep upstream cadence elsewhere: non-database MusicBrainz services should continue following upstream unless planning proves a separate lifecycle risk.

---

## Dependencies / Assumptions

- The fleet-managed PostgreSQL container pattern can support MusicBrainz's required PostgreSQL major version, extensions, settings, users, and databases.
- Existing MusicBrainz mirror state can either be migrated safely or rebuilt from documented re-downloadable sources without unacceptable data loss.
- Cratedigger's MusicBrainz-producing components can be paused and resumed without corrupting its own pipeline database or import state.
- Planning must verify exactly which MusicBrainz services require database connectivity and which cratedigger components can generate MusicBrainz traffic.
- Planning must preserve the fleet's least-privilege database posture while allowing the MusicBrainz compose services to reach the extracted database.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R3][Technical] Which PostgreSQL major version and extension set should the first fleet-managed MusicBrainz database use?
- [Affects R4, R9][Technical] Is dump/restore, in-place upgrade, or mirror rebuild the safest migration path for the current MusicBrainz data size and downtime tolerance?
- [Affects R5, R6, R7][Technical] Which concrete cratedigger units or entry points must be stopped to make the MusicBrainz maintenance boundary real?
- [Affects R10][Technical] What representative verification checks best prove MusicBrainz API, replication, search/index, LMD, and cratedigger consumption are healthy?
- [Affects R12][Technical] What database network and credential shape gives MusicBrainz compose services access without reopening broad trusted PostgreSQL access?
