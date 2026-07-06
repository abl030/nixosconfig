# Immich crash-loop on function-ownership drift (2026-07-06 → 2026-07-07)

**Status:** RESOLVED. Live DB repair applied 2026-07-07; `mk-pg-container.nix` now
auto-heals function-ownership drift on every container start (fleet-wide).

**Related:** [immich-asset-edit-audit-incident.md](immich-asset-edit-audit-incident.md)
(#250 — the *relation*-ownership sibling of this bug and the invariant it added).

## TL;DR

The nightly auto-update pulled Immich **3.0.1**, which ships migration
`1776848612954-MigrateAlbumOwnerIdToAlbumUser`. That migration runs
`CREATE OR REPLACE FUNCTION album_user_after_insert()`. `CREATE OR REPLACE
FUNCTION` requires the connecting role to **own** the function — but that
function (and 20 other Immich audit/helper functions) was owned by the
`postgres` superuser, not the `immich` app role. So every startup failed the
migration with `PostgresError: must be owner of function album_user_after_insert`
→ microservices worker `exited with code 1` → systemd restart → **crash loop**.

Immich was down from ~04:37 AWST until the manual repair at ~07:10 AWST. Kuma
paged once at 05:40 (`Immich DOWN`) then went quiet (4 h `resendInterval`), so
it read as "recovered" when it hadn't.

## Root cause

Immich performs some DB bootstrap as the `postgres` superuser (documented for
the geocoder tables in `modules/nixos/services/immich.nix` — "loaded via COPY as
superuser"). Its audit/trigger functions were created the same way and left
`postgres`-owned. Incremental migrations, however, run as the `immich` app role.
The first migration to `CREATE OR REPLACE` one of those superuser-owned
functions could not, because it didn't own it.

## Why the existing invariant missed it

`mk-pg-container.nix`'s schema-ownership invariant (from #250) only scanned
`pg_class` **relations** (`relkind IN ('r','v','m','S','f','i')`). It never
checked `pg_proc`, so function drift was structurally invisible. And the remedy
it uses for allow-listed relations — `GRANT SELECT` — is useless for a function
a migration will `CREATE OR REPLACE`: that needs **ownership**, not a grant.

## The fix

**Live repair (2026-07-07):** reassigned the 24 non-extension `postgres`-owned
objects in the immich DB (21 functions + `geodata_places` /
`naturalearth_countries` / its sequence) to `immich`, excluding the 291
VectorChord/`vector` **extension** functions (correctly superuser-owned — a
blanket `REASSIGN OWNED` would have broken vector search). Migration then
succeeded; Immich serves v3.0.1.

**Permanent (fleet-wide), in `mk-pg-container.nix`:** a function auto-heal step
runs on every container start (as the `postgres` superuser, before the
assertions). It reassigns every `public` function that is **not** owned by the
service role, **not** SECURITY DEFINER, **not** in the new
`functionOwnershipAllowList`, and **not** an extension member
(`pg_depend deptype='e'`) back to the service role. Verb is chosen by `prokind`
(`ALTER FUNCTION`/`PROCEDURE`/`AGGREGATE`). A post-condition invariant then fails
the container start loudly if any such object survives. SECURITY DEFINER
functions are deliberately **not** auto-healed (reassigning owner changes their
execution privileges) — they trip the invariant instead, forcing an explicit
allow-list decision.

Relations keep the older allow-list + `GRANT SELECT` treatment: Immich
re-creates the geocoder tables as `postgres` on every geodata import, so
reassigning them would just revert — but they're read-only, so a grant suffices.
Functions a migration mutates must be owned; hence auto-heal for functions only.

## Fleet scan (2026-07-07)

Non-extension `postgres`-owned functions per DB at diagnosis time: **immich 21**
(fixed), **atuin 1** (`user_history_count`, latent — never tripped, healed the
same day). cratedigger/mealie had only legitimate *extension* functions; discogs,
jellystat, musicbrainz, paperless clean; youtarr is MariaDB (N/A). **Zero**
SECURITY DEFINER non-extension `postgres`-owned functions fleet-wide.

## When to revisit

- If a service ever legitimately needs a superuser-owned (e.g. SECURITY DEFINER)
  function in `public`, add it to that service's `functionOwnershipAllowList` —
  otherwise the container will fail to start with the function-ownership
  invariant violation. That failure is *by design*: it forces a human to decide.
- Kuma's `Immich` monitor only probes `/api/server/ping` (nginx up), which stays
  200 while the backend crash-loops. The DB-write deep probes (#252) are the real
  signal; this incident is another argument for a migration/bootstrap-health probe.
