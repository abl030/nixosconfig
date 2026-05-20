# Shipping nspawn container logs to Loki

**Status:** SOLVED (with caveat). Workaround is in `mk-pg-container.nix`. Future containers needing inner-unit logs in Loki should follow the same pattern.

**Date researched:** 2026-05-20. Hit while building the DB DDL audit alert in [#251](https://github.com/abl030/nixosconfig/issues/251).

## TL;DR

systemd-nspawn containers (which NixOS uses for our isolated PostgreSQL/MariaDB instances via `mk-pg-container.nix` / `mk-mariadb-container.nix`) **do not merge their inner journals into the host's journal namespace by default**. Setting `path = "/var/log/journal/"` on alloy's `loki.source.journal` does not help — `sd_journal_open()` still opens only the host's own namespace.

To get inner-unit logs into Loki, **bind-mount the host's syslog socket into the container** and configure the service to log via syslog. Inner libc `openlog()` then writes directly to the host's journald, which alloy ships as normal under `unit=container@<name>.service`, `transport=syslog`.

## The problem

`nixos-containers.nix` hardcodes `--link-journal=try-guest` (no `extraFlags` exposed for this). `try-guest` means: first try `host` (bind-mount `/var/log/journal/<container-machine-id>/` from host into container's `/var/log/journal/<container-machine-id>/`), if that fails fall back to no linking. In our setup it falls back — verified by `journalctl --merge` on the host not seeing inner postgres `LOG:` lines that `journalctl --machine=<name>` *can* see.

Even when the link succeeds, alloy's `loki.source.journal` uses `sd_journal_open()` which by default opens only the local namespace's journal files, not all subdirectories. Setting `path = "/var/log/journal/"` doesn't change this — the host's machine-id namespace is what gets read regardless.

Result: inner-container unit logs are isolated from Loki even when they appear inside the container's own journalctl.

## What works

The proven pattern (see `mk-pg-container.nix`):

1. **Bind-mount the host's syslog socket into the container.** Crucially this is `/run/systemd/journal/dev-log`, NOT `/run/systemd/journal/socket` — `dev-log` is the libc `openlog()` syslog-compat socket; `socket` is the binary protocol used by `libsystemd-journal`.
   ```nix
   bindMounts."/run/systemd/journal/dev-log" = {
     hostPath = "/run/systemd/journal/dev-log";
     isReadOnly = false;
   };
   ```
2. **Tell the service to log via syslog.** For PostgreSQL:
   ```nix
   services.postgresql.settings = {
     log_destination = lib.mkForce "syslog";  # mkForce because nixpkgs defaults to "stderr"
     syslog_ident = "postgres-<name>";
   };
   ```
   The `mkForce` is required — nixpkgs' postgres module sets `log_destination = "stderr"` without `mkDefault`, so any override conflicts at evaluation time.
3. **Let alloy do nothing special.** The entries land in the host journal under `unit=container@<name>.service` with `transport=syslog` and the syslog ident as `SYSLOG_IDENTIFIER` (e.g. `postgres-immich`). Existing alloy relabel rules pick them up automatically.

Verified working in Loki under the query:
```
{host="doc2", unit=~"container@.+-db\\.service"}
  |~ "postgres@[^ ]+ from .+ LOG: +statement: ..."
```

## Things that don't work (we tried)

| Attempt | Result |
|---|---|
| `loki.source.journal { path = "/var/log/journal/" }` only | `sd_journal_open` still scoped to host namespace. Inner entries invisible. |
| Relying on `--link-journal=try-guest` | Falls back to no linking in practice. Even when it doesn't, the linked dir's machine-id isn't read by alloy. |
| Binding `/run/systemd/journal/socket` (binary protocol socket) | postgres uses libc syslog() → `/dev/log`, not the binary socket. No effect. |
| `journalctl --merge` on host | Does NOT show inner entries even with the link. `journalctl --machine=<name>` does (different code path). |

## When to use this pattern

For any nspawn container service whose journal lines you need in Loki for alerting, dashboards, or forensics. Today that's just the DB audit logging from #251, but the same pattern applies to anything else under `mk-pg-container.nix` / `mk-mariadb-container.nix`.

Out of scope: full container journal shipping. We only forward the *application* logs (postgres / mariadb / etc.) that are deliberately routed through syslog. Inner-systemd messages ("Reached target multi-user.target") and other inner-unit chatter remain invisible from outside.

## Future cleanup

If/when [systemd issue tracking journal forwarding](https://github.com/systemd/systemd) lands a fix for nspawn → host journal merging via `sd_journal_open_directory`, we can drop the syslog hop and let postgres log to stderr normally. Until then, the syslog bind is the supported path.

## Related

- [`docs/wiki/services/immich-asset-edit-audit-incident.md`](../services/immich-asset-edit-audit-incident.md) — the incident that motivated the audit alert this discovery unblocked
- [`docs/wiki/infrastructure/nspawn-failureaction-pidns-wedge.md`](nspawn-failureaction-pidns-wedge.md) — sibling nspawn integration gotcha
- [`docs/wiki/services/lgtm-stack.md`](../services/lgtm-stack.md) — overall LGTM/alerting architecture
- [issue #251](https://github.com/abl030/nixosconfig/issues/251) — fleet DB DDL audit logging
- `modules/nixos/lib/mk-pg-container.nix` — canonical use of this pattern
- `modules/nixos/lib/mk-mariadb-container.nix` — same with server_audit + syslog
- `modules/nixos/services/loki.nix` — alloy `loki.source.journal` config (note: the `path` arg there is now mostly cosmetic given this workaround)
