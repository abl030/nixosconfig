# Immich asset_edit_audit silent upload outage (2026-05-08 → 2026-05-20)

**Status:** RESOLVED. Ownership fix applied on 2026-05-20. Schema-ownership invariant in `mk-pg-container.nix` now catches this class of drift on next container restart.

**Issues:** [#250](https://github.com/abl030/nixosconfig/issues/250) (this incident, fix), [#251](https://github.com/abl030/nixosconfig/issues/251) (DDL audit logging), [#252](https://github.com/abl030/nixosconfig/issues/252) (deep probes), [#253](https://github.com/abl030/nixosconfig/issues/253) (per-service errorPatterns), [#254](https://github.com/abl030/nixosconfig/issues/254) (backup health).

## TL;DR

iOS uploads to Immich were 100% broken for at least 11 days (last successful upload ~2026-05-08; user noticed 2026-05-20). Cause: the `asset_edit_audit` table in the immich Postgres DB was owned by the `postgres` superuser instead of the `immich` service role, so the immich app got `PostgresError: permission denied for table asset_edit_audit` on every sync request — which the mobile upload flow performs. Kuma stayed green throughout because `/api/server/ping` doesn't probe the DB write path.

## Detection

The user noticed uploads weren't working. There was no alert. The smoking gun was buried in `immich-server.service` logs in Loki:

```
error: PostgresError: permission denied for table asset_edit_audit
sql: 'select "asset_edit_audit"."id", "editId" from "asset_edit_audit"
      inner join "asset" on "asset"."id" = "asset_edit_audit"."assetId"
      where "asset_edit_audit"."id" < $1 and "asset"."ownerId" = $2'
```

Plus the nightly `AuditTableCleanup` job and kopia `pg_dump` backups were also failing on the same permission error — and we weren't alerting on those either.

## Diagnostic — confirming ownership drift

```sh
ssh doc2 'pid=$(sudo machinectl show immich-db -p Leader --value); \
  sudo nsenter -t $pid -m -p -u -i -n su -s /bin/sh postgres -c psql' <<'SQL'
\c immich
SELECT tablename, tableowner FROM pg_tables
 WHERE schemaname='public' AND tablename LIKE '%audit%'
 ORDER BY tableowner, tablename;
SQL
```

Result:

```
       tablename       | tableowner
-----------------------+------------
 album_audit           | immich
 album_user_audit      | immich
 ... (every other audit table)
 asset_edit_audit      | postgres   ← drift
```

All `asset_edit_audit` indexes (`asset_edit_audit_pkey`, `asset_edit_audit_assetId_idx`, `asset_edit_audit_deletedAt_idx`) and the trigger function `asset_edit_audit()` were also postgres-owned. The sibling `asset_edit` (parent table created in the same Immich migration) was immich-owned. So the drift was: `DROP TABLE asset_edit_audit CASCADE; CREATE TABLE ...` had run at some point as the postgres superuser. Unknown when, unknown why — no DDL audit logging.

## What we ruled out

Initial hypothesis was that an Immich migration introduced the table in a way that auto-owned it under postgres (e.g. event trigger creating audit tables under the connecting superuser). Refuted by reading [immich-app/immich PR #26446 (server: SyncAssetEditV1)](https://github.com/immich-app/immich/pull/26446) — the migration is a plain `CREATE TABLE`, no SECURITY DEFINER, no helper. The table was created cleanly on 2026-03-25 (per `kysely_migrations.timestamp`), would have been immich-owned then, and was rewritten later by some other path.

Also ruled out: Immich version change as a trigger. Immich has been pinned at v2.7.5 since 2026-04-13 — same version we ran during working uploads and broken uploads.

## Immediate fix (data plane)

```sql
ALTER TABLE  public.asset_edit_audit               OWNER TO immich;
ALTER INDEX  public.asset_edit_audit_pkey          OWNER TO immich;
ALTER INDEX  public."asset_edit_audit_assetId_idx"   OWNER TO immich;
ALTER INDEX  public."asset_edit_audit_deletedAt_idx" OWNER TO immich;
ALTER FUNCTION public.asset_edit_audit()           OWNER TO immich;
```

Run as `postgres` inside the immich-db nspawn via `machinectl shell` or `nsenter`. Permission errors stopped in Loki within ~30 seconds of running the ALTERs.

## Structural fix (control plane)

Two-part fix landed in `mk-pg-container.nix` (commit `6cbcac90`):

1. New `ownershipAllowList` function parameter. Lists object names that are legitimately not-immich-owned (in immich's case: the geocoder data tables, vchord internals, supporting indexes).
2. A `DO $$ ... RAISE EXCEPTION ... $$` block appended to `postgresql-setup.service`'s ExecStartPost that scans `pg_class` for any `relkind IN ('r','v','m','S','f','i')` object in `public` whose owner isn't the service role and isn't allow-listed. Exit 3 → `postgresql-setup` fails → inner `multi-user.target` fails (because `requiredBy = ["multi-user.target"]` per commit `f006ba27`).

Scope is intentional: only "user data" object kinds (tables, views, mviews, sequences, foreign tables, indexes). Extension internals (functions, types, operators, opclasses) routinely live under `postgres` — they aren't in scope and don't need to be listed. Note: Immich's audit *trigger functions* (`asset_audit`, `user_audit` etc., stored in `pg_proc` not `pg_class`) are also postgres-owned in our DB. They're out of scope of this invariant. They appear functional but the ownership question is worth a separate upstream investigation.

Today's deploy verified the invariant against eight other `mk-pg-container` consumers (atuin, paperless, mealie, cratedigger, discogs, jellystat, youtarr, musicbrainz). All passed with empty allow-lists — only Immich had drift.

### Why "assert-and-fail" not "self-heal"

Discussed in conversation. Self-healing would silently `ALTER OWNER` anything that drifted, including legitimate cases where an upstream change *meant* to put something under postgres. Assert-and-fail makes drift loud — the operator decides whether it's a bug or a new legitimate exception to add to the allow-list.

### Why the outer `container@immich-db.service` doesn't go red (yet)

When the invariant fails, the inner `postgresql-setup.service` is `failed` and `multi-user.target` is dead. But `systemd-nspawn --notify-ready=yes` considers the container "up" as long as its PID 1 is alive — regardless of inner target state. So the outer service stays `active (running)` and Kuma doesn't see red.

We tried two mechanisms to fix this:

1. `OnFailure=poweroff.target` — inner systemd shuts cleanly with exit 0, outer goes `inactive (dead) success`, still not `failed`.
2. `FailureAction=exit-force` with `FailureActionExitStatus=1` — outer briefly goes `failed (exit-code)`, BUT the inner `[systemd-shutdow]` process gets stuck in a kernel `zap_pid_ns_processes` wedge → container can't restart without a host reboot.

Both reverted in commit `630b2788`. Outer-service visibility deferred to [issue #253](https://github.com/abl030/nixosconfig/issues/253) — per-service Loki errorPatterns alert on the inner journal line. See [nspawn-failureaction-pidns-wedge.md](../infrastructure/nspawn-failureaction-pidns-wedge.md) for the kernel-bug write-up.

## Deep probe (#252) — surgical check for next-time

Landed 2026-05-20: `modules/nixos/services/probes/check-immich-sync.nix`. Runs `SELECT 1 FROM asset_edit_audit LIMIT 1` as the `immich` role over the nspawn veth every 5 min via a systemd timer. Exit 0 → Kuma push monitor "Immich sync write-path" gets a heartbeat (UP). Permission denied → no push → Kuma flips DOWN after maxretries (default 2 = ~15 min from first failure).

This is the surgical version of the alert that would have caught the original incident. It bypasses the HTTP API entirely — we tried `POST /api/sync/stream` first but Immich rejects API-key auth on sync endpoints. The SQL-level probe doesn't need an API key, doesn't break when Immich renames endpoints, and tests the exact permission state we care about.

Verified working both ways on 2026-05-20:
- `REVOKE SELECT ON TABLE asset_edit_audit FROM immich` → probe logs `ERROR: permission denied for table asset_edit_audit` (exact original signature), exits 1, monitor goes DOWN.
- `GRANT SELECT ...` → exit 0, monitor UP within one interval.

## Class of failure this exposed

Three observability gaps fired in this incident, all tracked:

1. **HTTP healthcheck doesn't probe write path.** `/api/server/ping` returns 200 from a process that knows nothing about DB write capability. → [#252](https://github.com/abl030/nixosconfig/issues/252) ships `homelab.monitoring.deepProbe` (authenticated GET on `/api/sync/asset-edits-v1`).
2. **No alert on error-log content.** Logs screamed for 11 days; nothing watched. → [#253](https://github.com/abl030/nixosconfig/issues/253) ships per-service `errorPatterns` Loki alerts.
3. **No DDL audit trail.** We couldn't reconstruct who/when did the rogue DROP/CREATE. → [#251](https://github.com/abl030/nixosconfig/issues/251) ships fleet-wide `log_statement = 'ddl'` + connection logging + Grafana alert on non-service-role DDL.

Plus [#254](https://github.com/abl030/nixosconfig/issues/254) for kopia subjob failure surfacing — `pg_dump` had been failing on `asset_edit_audit` permission error for the entire 11 days, and we didn't notice that either.

## What worked

- The schema-ownership invariant code is in place and verified to fire correctly (psql exits 3, inner journal logs `schema-ownership invariant violated; objects in public not owned by service role`). Once #253 ships, this becomes a Gotify page.
- Immich's allow-list is documented in `modules/nixos/services/immich.nix` and is the canonical reference for "what's legitimately postgres-owned in immich-db."
- Eight other `mk-pg-container` consumers verified clean against the invariant on the same deploy.

## What to revisit

- Outer-container-state propagation (the nspawn issue above) once we have either a kernel-side fix for `zap_pid_ns_processes`, a systemd-nspawn flag that drains inner processes cleanly on inner-init exit, or we move off nspawn entirely.
- Immich audit *trigger functions* ownership. Currently postgres-owned but functioning (postgres can write to immich-owned tables via SECURITY INVOKER triggers). Worth an upstream-Immich question whether they're meant to be immich-owned.
- The `naturalearth_countries_tmp_id_seq1` sequence in immich's allow-list — name implies it's leftover from a geocoder data import. Could probably be DROPped safely; we kept it to avoid a tangential change.

## Operator runbook (if this fires again)

If you get a Gotify alert about `schema-ownership invariant violated` for a `mk-pg-container` service:

1. SSH to the host running it (almost certainly doc2).
2. Read the journal entry — it lists every drifted object with `relkind:relname (owner=<who>)`.
3. Decide for each object: drift or legitimate.
   - **Drift:** run `ALTER ... OWNER TO <svc>` from inside the container as postgres superuser. `machinectl shell <svc>-db` → `sudo -u postgres psql -d <db>`.
   - **Legitimate:** add the object name to `ownershipAllowList` in the service's `.nix` file, commit, deploy.
4. Restart the container: `sudo systemctl restart container@<svc>-db.service`.
5. Verify `systemctl is-active` returns active and journal shows `psql[NNN]: DO` (the anonymous block returned cleanly).

Out-of-band probe (no alert yet, just want to check current state):

```sh
ssh <host> 'pid=$(sudo machinectl show <svc>-db -p Leader --value); \
  sudo nsenter -t $pid -m -p -u -i -n su -s /bin/sh postgres -c \
  "psql -d <db> -c \"SELECT relkind, relname, relowner::regrole FROM pg_class c \
  JOIN pg_namespace n ON c.relnamespace=n.oid WHERE n.nspname='\''public'\'' AND \
  c.relowner::regrole::text <> '\''<svc>'\'';\""'
```
