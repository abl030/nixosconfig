---
date: 2026-05-14
topic: youtarr-mariadb-lifecycle
---

# Youtarr MariaDB Lifecycle

## Summary

Youtarr should stop depending on upstream's bundled MariaDB 10.3 container and move to a fleet-owned, isolated MariaDB database pattern. This work should preserve existing Youtarr state, reduce database blast radius, and avoid turning the rest of the Youtarr app stack into a native-service rewrite.

---

## Problem Frame

`modules/nixos/services/youtarr.nix` currently runs Youtarr with a colocated `mariadb:10.3` OCI container and mutable image pulls. MariaDB 10.3 reached end of life on May 25, 2023, so the database runtime that owns Youtarr's persistent state is no longer receiving security fixes.

The failure shape is worse than an ordinary app image going stale. Application containers can often be updated, rolled back, or replaced without changing the meaning of persistent state. A database runtime owns an on-disk cluster with version-specific recovery, upgrade, and compatibility behavior. Letting that lifecycle be inherited from an upstream example compose file creates unbounded operational risk during routine updates and after unclean shutdowns.

Upstream Youtarr already provides an external database mode. That means the fleet does not need to keep accepting the bundled database container just to run Youtarr.

---

## Actors

- A1. Operator or implementation agent: migrates the service, verifies state, and performs rollback if needed.
- A2. Youtarr application container: reads and writes the application database using external database settings.
- A3. Isolated MariaDB service: owns Youtarr's database state under fleet-controlled runtime and credential policy.

---

## Key Flows

- F1. Database ownership migration
  - **Trigger:** Implementation starts work on issue #231.
  - **Actors:** A1, A2, A3
  - **Steps:** capture the existing Youtarr database state; bring up a fleet-owned isolated MariaDB service; restore the captured state; point Youtarr at the new database; verify the UI and stored library state; retain a rollback path until verification is complete.
  - **Outcome:** Youtarr runs normally while its database state is owned by the isolated fleet-managed MariaDB service.
  - **Covered by:** R1, R2, R3, R5, R6, R7

- F2. Post-migration cleanup
  - **Trigger:** The migrated Youtarr service has passed verification.
  - **Actors:** A1, A2, A3
  - **Steps:** remove the active bundled MariaDB container from the runtime path; ensure routine rebuilds no longer start it; keep or retire old database artifacts according to the rollback window chosen during planning.
  - **Outcome:** There is a single active database owner for Youtarr, and the EOL MariaDB container is no longer part of normal service operation.
  - **Covered by:** R4, R6, R8

---

## Requirements

**Database ownership**
- R1. Youtarr must run against a MariaDB database whose runtime version is controlled by this fleet, not by upstream's bundled `mariadb:10.3` container.
- R2. The new database owner must use an isolated per-service pattern rather than a shared host-level MariaDB instance.
- R3. The database pattern must be reusable for a future MariaDB or MySQL-backed service without requiring Youtarr-specific assumptions in the abstraction.
- R4. The bundled Youtarr MariaDB OCI container must stop being part of the active runtime after migration succeeds.

**Migration and continuity**
- R5. The migration must preserve existing Youtarr database state, including application configuration, jobs, and any library metadata stored in the database.
- R6. The migration must provide a known rollback or recovery path until the external-database Youtarr instance has been verified.
- R7. Youtarr's public service must return to normal operation after the database move.
- R8. Post-migration cleanup must avoid leaving two live database owners for the same Youtarr state.

**Security and lifecycle control**
- R9. New database credentials must not remain as hardcoded plaintext defaults in the service module.
- R10. The new database access path must satisfy the repo's least-privilege and blast-radius rules for service modules.
- R11. Routine upstream Youtarr app updates must not be able to change the MariaDB runtime that owns persistent database state.
- R12. Mutable image behavior for Youtarr should be narrowed while touching this service, without creating a fleet-wide OCI image policy in this issue.

**Scope discipline**
- R13. This work must not rewrite the Youtarr application container into a native NixOS service.
- R14. This work must not require ongoing manual digest maintenance for unrelated Youtarr dependencies beyond the narrow hardening needed for this service.

---

## Acceptance Examples

- AE1. **Covers R1, R4, R11.** Given migration has completed, when a routine Youtarr app image update occurs, the MariaDB runtime serving Youtarr remains fleet-controlled and the old `mariadb:10.3` container is not started.
- AE2. **Covers R5, R6, R7.** Given the database move is attempted, when verification fails, there is still a documented path to recover the pre-migration Youtarr state.
- AE3. **Covers R2, R9, R10.** Given the new database is running, when another local service or container is compromised, Youtarr's database access remains bounded to the smallest practical credential and network surface for this service.
- AE4. **Covers R3.** Given another MariaDB-backed service is added later, when planning its database ownership, the Youtarr work provides a reusable isolated pattern instead of requiring a fresh design from scratch.
- AE5. **Covers R12, R14.** Given this issue lands, when a future agent reviews the change, it can see that Youtarr-specific image hardening was handled without establishing a broad digest-pinning program for the whole fleet.

---

## Success Criteria

- Youtarr no longer depends on MariaDB 10.3 or any EOL bundled database image for active persistent state.
- Existing Youtarr data survives the migration and the public Youtarr service works normally afterward.
- The new MariaDB ownership shape matches the repo's least-privilege direction and gives future MariaDB/MySQL services a proven starting point.
- A downstream planner can focus on migration mechanics, verification, rollback, and the exact helper shape without relitigating shared-vs-isolated database ownership.

---

## Scope Boundaries

- Do not keep a newer MariaDB OCI container as the final database ownership model.
- Do not use one shared host-level MariaDB instance for multiple services.
- Do not replace the Youtarr application container with a nixpkgs package or custom native service.
- Do not turn this issue into a general policy for every `:latest` image in the fleet.
- Do not require broad manual digest maintenance for all Youtarr-adjacent images as part of this database lifecycle fix.
- Do not treat an upstream Youtarr PR as required for local completion.

---

## Key Decisions

- Isolated MariaDB helper over native shared MariaDB: the database should follow the fleet's least-privilege direction, even though Youtarr is the first MariaDB consumer.
- External database mode over bundled compose defaults: upstream already supports the operational boundary needed here, so the local config should use that boundary instead of carrying an EOL database container.
- Youtarr app container remains OCI for now: the risk being addressed is database lifecycle ownership, not the application packaging model.
- Narrow image hardening stays in scope: mutable pulls are part of the current service risk, but this issue should not become a fleet-wide image governance project.

---

## Dependencies / Assumptions

- Upstream Youtarr's external database settings remain compatible with the current application image.
- The existing Youtarr database can be exported from MariaDB 10.3 and restored into the chosen fleet-owned MariaDB version.
- Planning must choose the concrete MariaDB version, migration command sequence, credential wiring, rollback retention period, and verification checks.
- Planning must verify whether Youtarr requires any MariaDB 10.3-specific SQL mode, charset, collation, or startup behavior before the cutover.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R5][Needs research] Which MariaDB version should be the fleet default for the isolated helper, and does Youtarr work cleanly on it?
- [Affects R3, R10][Technical] What is the smallest reusable helper surface that supports Youtarr while staying useful for the next MariaDB/MySQL service?
- [Affects R5, R6][Technical] What exact dump, restore, smoke-test, and rollback sequence should be used for the live migration?
- [Affects R9, R10][Technical] What secret shape should feed both MariaDB initialization and the Youtarr app container without duplicating plaintext credentials?
- [Affects R12, R14][Technical] What specific Youtarr image-pull or pinning change gives useful hardening without creating routine manual image maintenance?
