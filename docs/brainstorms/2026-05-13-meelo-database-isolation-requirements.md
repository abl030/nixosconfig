---
date: 2026-05-13
topic: meelo-database-isolation
---

# Meelo Database Isolation

## Summary

Meelo should keep riding upstream app and support images by default, but its PostgreSQL data must no longer depend on a mutable upstream database container tag. This requirements doc narrows issue #230 to database extraction only and supersedes the earlier all-image-pinning scope.

---

## Problem Frame

Meelo currently bundles PostgreSQL as part of its OCI stack. That makes persistent database state depend on an upstream image reference that can change independently of any intentional database maintenance window.

The failure mode is the same class as the MusicBrainz incident in #228: a normal upstream update can bring in a new PostgreSQL major or incompatible database runtime, then fail against an existing on-disk cluster during an otherwise routine system update. App containers, frontend containers, queues, and search services can usually follow upstream with acceptable operational risk; PostgreSQL is different because its data directory has strict version and extension compatibility rules.

The goal is to remove that database-specific fragility without creating new ongoing image-upgrade work for the rest of the Meelo stack.

---

## Requirements

**Database ownership**
- R1. Meelo must run against a PostgreSQL instance whose version is controlled by this fleet's database management pattern, not by Meelo's upstream OCI database image.
- R2. A routine upstream Meelo image update must not be able to change the PostgreSQL major version that owns Meelo's persistent database state.
- R3. The old bundled PostgreSQL container must stop being part of the active Meelo runtime after migration succeeds.

**Migration and continuity**
- R4. The migration must preserve the existing Meelo library state, including metadata and service configuration stored in the database.
- R5. The migration must provide a clear rollback or recovery path until the new database-backed Meelo instance has been verified.
- R6. Meelo's user-facing service must return to normal operation after the database move.

**Operational boundary**
- R7. Non-database Meelo containers may continue following upstream image cadence unless a separate, concrete failure mode is found.
- R8. The work must not introduce a routine digest-refresh or manual image-upgrade process for Meelo's non-database containers.
- R9. Any new database credential or access path must follow the current least-privilege PostgreSQL pattern for the fleet.

---

## Acceptance Examples

- AE1. **Covers R1, R2.** Given Meelo is migrated, when an upstream Meelo app image changes during a routine update, the PostgreSQL major version serving Meelo remains unchanged.
- AE2. **Covers R3, R6.** Given migration is complete and verified, when the Meelo service starts, it uses the fleet-managed PostgreSQL instance and no active Meelo database OCI container is required.
- AE3. **Covers R4, R5.** Given the migration has been attempted, when verification fails, there is still a known path to recover the pre-migration database state.
- AE4. **Covers R7, R8.** Given a non-database Meelo image releases a new upstream build, when routine updates run, no new manual digest refresh is required solely because of this database-isolation work.

---

## Success Criteria

- Meelo's PostgreSQL major version changes only through an intentional database maintenance action.
- Existing Meelo library state survives the move and the public Meelo service works normally afterward.
- Future planning can focus on database extraction and verification instead of relitigating image pinning for the entire stack.
- The GitHub issue and resulting plan make clear that non-database image ownership is out of scope.

---

## Scope Boundaries

- Do not pin all Meelo OCI images by digest as part of this work.
- Do not move RabbitMQ, Meilisearch, frontend, scanner, matcher, transcoder, or nginx to nixpkgs services.
- Do not create a reusable fleet-wide OCI image pinning policy from this issue.
- Do not replace upstream Meelo containers with native Nix packages.
- Do not take ownership of routine non-database image upgrades.
- Do not treat RabbitMQ or Meilisearch persistence risk as part of this issue unless a separate concrete failure is found.

---

## Key Decisions

- Database-only scope: PostgreSQL is the risky component because its persistent state is coupled to runtime major version compatibility.
- Keep upstream cadence elsewhere: non-database Meelo images can continue moving with upstream because avoiding routine image nursing is an explicit goal.
- Supersede all-image pinning in #230: the original issue's broader image-pinning acceptance criteria should be narrowed before implementation planning proceeds.

---

## Dependencies / Assumptions

- The existing fleet PostgreSQL isolation pattern is suitable for Meelo and supports least-privilege credentials.
- Current Meelo data can be exported from the bundled PostgreSQL container and restored into the fleet-managed PostgreSQL instance.
- Planning must verify the current Meelo database version, required database names/users, and environment variables before implementation.
- Planning must decide the exact backup, restore, verification, and rollback sequence.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R4, R5][Technical] What exact database dump/restore method best preserves the existing Meelo state?
- [Affects R6, R9][Technical] What runtime database connection shape does Meelo expect once PostgreSQL is no longer on the internal container network?
- [Affects R5][Technical] How long should the old database volume or backup be retained after a successful migration?
