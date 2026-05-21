---
name: service-module
description: Use this skill when creating, modifying, or reviewing a NixOS service module under `modules/nixos/services/`, or when adding container/database/proxy/monitoring wiring for a homelab service. Covers the service hierarchy (upstream module > custom module > OCI container), `mk-pg-container` / `mk-mariadb-container` patterns, sops secret layout, DNS-first networking, deep probes, errorPatterns, sandbox patterns, and the pre-commit checklist. Trigger phrases include "new service module", "add service X", "wire up X in nixos", "review this module", "service module checklist", "least-privilege audit on this module".
version: 1.0.0
---

# Service Module Skill

The authoritative rules, patterns, anti-patterns, and pre-commit checklist for service modules live at:

**`docs/wiki/nixos-service-modules.md`**

Read it before doing the work. It is long; you do not need to memorise it — grep / Read the section you need:

- Service hierarchy (upstream > custom > OCI) — when in doubt about which form a new service should take.
- `Module Structure` — the `homelab.services.<name>` skeleton.
- `Database Container Pattern (mk-pg-container)` and `(mk-mariadb-container)` — including the `restartTriggers` rule (host-side unit, NOT inner toplevel), `passwordFile` requirement, schema-ownership invariant, and audit-logging behaviour.
- `Infrastructure Wiring` — `localProxy`, `monitoring.monitors`, `deepProbes`, `errorPatterns`, `nfsWatchdog`, sops.
- `External Sharing (tailscaleShare)` — when LAN proxy isn't enough.
- `Anti-Patterns` — concrete failure modes we have already hit; check before introducing something that looks like one.
- `Sandbox patterns — ReadWritePaths vs BindPaths` and `TemporaryFileSystem=/mnt` — for NFS-backed or space-bearing paths.
- `Checklist` — run through this before you call the work done.

## Workflow

1. Read the relevant sections of `docs/wiki/nixos-service-modules.md` before writing code.
2. Implement the module under `modules/nixos/services/<name>.nix` and register it in `modules/nixos/services/default.nix`.
3. Walk the checklist at the bottom of the wiki doc and verify each applicable line.
4. `nix flake check` (or build the host's toplevel) before committing.

## Least-privilege reminder

Per CLAUDE.md: every service-module change gets a privilege and blast-radius audit. Threat models to keep in mind are external probe (LAN/internet/tailnet) and post-compromise lateral movement. If a change touches auth, secrets, image trust, network exposure, file ownership, or shared resources, flag it explicitly in the PR / commit body rather than papering over it.
