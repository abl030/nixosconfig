# Policy: every flake input follows the fleet nixpkgs

**Researched / written:** 2026-06-26
**Status:** ENFORCED (flake check `nixpkgsFollowsCheck`, in the pre-push audit set + nightly `nix flake check`)
**Motivating incident:** the "why does our nixpkgs look like it's from April" investigation (see below)

## The rule

Every top-level flake input that has a `nixpkgs` input MUST follow the fleet
nixpkgs:

```nix
some-input = {
  url = "github:owner/repo";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

An input is **not** allowed to carry its own nixpkgs unless flake.nix gives an
explicit, reasoned exception (see below). This is enforced by a deny-by-default
audit, so a regression cannot reach master or the nightly rolling-flake-update.

## Why

The nightly `rolling-flake-update` only advances the **root** nixpkgs pin
(`flake.nix`'s `nixpkgs` input). When some other input carries its *own* nixpkgs,
that becomes a **second, independent node** in `flake.lock` that nothing keeps
fresh. It drifts off on its own schedule and goes stale silently. Concretely it:

- **Goes stale & misleads.** The orphan node sits in `flake.lock` at whatever
  rev it was last locked at. Tooling and agents that read `flake.lock` — or just
  `grep nixpkgs flake.lock` — see the orphan's date and conclude the *fleet*
  nixpkgs is that old. This is exactly what happened: a node literally named
  `nixpkgs` was pinned at `nixos-unstable` 2026-04-14 (carried only by
  `cratedigger-src`), while the real fleet nixpkgs (`nixpkgs_2`/`nixpkgs_3`,
  whatever Nix labelled it) was current. Every agent that looked reported "your
  nixpkgs is from April." The fleet was fine; the lock was just confusing.
  Removing `cratedigger-src`'s copy only moved the bare `nixpkgs` label onto the
  *next* orphan (`nixos-hardware`, a Jan-08 channel tarball) — so the fix had to
  be the general rule, not a one-off.
- **Bloats closures.** Any derivation built against the orphan pulls a whole
  extra nixpkgs evaluation/source, separate from the fleet's.
- **Diverges security posture.** A second nixpkgs means a second, unmanaged set
  of package versions and patches.

In practice the orphan is almost never *used* for anything we deploy: upstream
NixOS modules take the **importing system's** `pkgs` (e.g. cratedigger's
`module.nix` builds via `pkgs.callPackage`; nixos-hardware modules likewise). So
following root is a **build no-op** for the deployed systems (verified by
`nix-diff`: the only delta was `configurationRevision`) — it just deletes the
misleading, drift-prone node.

## How it's detected

`nix/checks/nixpkgs-follows-audit.py` parses `flake.lock`. The signal is purely
**list-vs-string** on each top-level input's `nixpkgs` edge:

- a `follows` is recorded as a **list** — `"nixpkgs": ["nixpkgs"]` — ✅ allowed
- carrying its own is a **string** node-ref — `"nixpkgs": "nixpkgs"` — ❌ flagged
  (when it points to a node other than the root nixpkgs node)

No node-type heuristics are needed: an own nixpkgs can be a `github:` ref *or* a
`releases.nixos.org` channel tarball (nixos-hardware used the latter), and the
list-vs-string test catches both.

The check derivation `nixpkgsFollowsCheck` lives in `flake.nix` under
`checks.x86_64-linux`, so it is picked up **automatically** by:

- the **pre-push** git hook (builds the whole cheap audit set — see
  `modules/home-manager/services/git-hooks.nix`), and
- the nightly **rolling-flake-update** via `nix flake check`.

A violation **fails the build** with a message naming the input and the fix.

## Adding a justified exception

If an input *genuinely* cannot follow root (e.g. it needs a specific nixpkgs that
the fleet pin breaks, and we accept owning that), add a marker line in
`flake.nix`:

```nix
# NIXPKGS-OWN-OK: <input-name> — <why it genuinely cannot follow root>
```

The audit greps `flake.nix` for `NIXPKGS-OWN-OK: <input-name> — <reason>` and
allows that input **only** when a non-empty reason is present (it prints the
reason at audit time). No silent allowlist: the justification lives next to the
inputs, in the diff, reviewable. There are currently **no** exceptions — every
input follows root.

## Related

- Detection script: `nix/checks/nixpkgs-follows-audit.py`
- Check wiring + audit hooks: `flake.nix` (`nixpkgsFollowsCheck`),
  `modules/home-manager/services/git-hooks.nix`
- Rolling update: `modules/nixos/ci/rolling-flake-update.nix`
- Same deny-by-default + marker-comment idiom as `BIND-ALL-INTERFACES-OK`
  (`hostBindAuditCheck`) and the other `checks.*` audits in `flake.nix`.
