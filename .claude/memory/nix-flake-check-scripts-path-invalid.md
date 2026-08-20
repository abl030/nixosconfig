---
name: nix-flake-check-scripts-path-invalid
description: "nix flake check fails with `path '<hash>-scripts' is not valid` after editing anything under scripts/; run a nix eval first to realise the source path"
metadata: 
  node_type: memory
  type: project
  originSessionId: aa18b4a8-e42f-4508-b27e-76833f5e8618
  modified: 2026-08-16T01:52:47.314Z
---

Editing **any** file under `scripts/` makes the next `nix flake check` fail with:

```
error: path 'f42c9j21y8fsxsjaj4hlp1pmc6925m4z-scripts' is not valid
```

`modules/home-manager/shell/scripts.nix` wraps the whole directory in
`builtins.path { path = "${flake-root}/scripts"; name = "scripts"; }`, so its
store hash is content-addressed over every script. `nix flake check` evaluates
against a read-only store and cannot add the new source path, so it asserts
validity on a path that was never copied in. It is deterministic, not the
transient store corruption described in `CLAUDE.md` — `nix-store --verify
--repair` and clearing `~/.cache/nix/` are the wrong remedies here.

Fix: realise the path with any store-writing evaluation first, then re-check.

```bash
nix eval --raw .#nixosConfigurations.proxmox-vm.config.system.build.toplevel.drvPath
nix flake check --no-build   # now passes
```

Observed 2026-08-16 on doc1 while validating Forgejo PR #157 (`scripts/komga-sync.py`).

Two related traps seen the same session:

- `nix flake check ... | tail` reports `tail`'s exit status. Redirect to a file
  and read `$?` directly, or a failed check reads as a pass.
- `[fleet-update] FLEET-FRESHNESS FAIL heartbeat status is 'partial_failure'` is
  **advisory** — `freshness_fail()` logs and returns 0. It has appeared on every
  doc2 deploy since 2026-08-15 and does not block the switch. Do not treat it as
  a deploy failure; see [[hermes-full-operator-posture]].
