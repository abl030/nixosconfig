# crates.io 403 — nix's `curl/` User-Agent is blocked

**Date researched:** 2026-05-29
**Status:** RESOLVED 2026-06-07 — nixpkgs-unstable now carries the `static.crates.io` fix (fetchCrate #525067); netwatch unpinned and verified building. Doc kept for history.
**Issue:** [#259](https://github.com/abl030/nixosconfig/issues/259)

## Symptom

`rolling-flake-update.service` on doc1 (proxmox-vm) had been **green nightly through
2026-05-27**. It failed for the **first time on 2026-05-28**, when the nightly bumped
the `netwatch` input to a new upstream version that pulls a new crate set (`landlock`,
`aya`, …):

```
error: cannot download crate-landlock-0.4.5.tar.gz from any mirror
> trying https://crates.io/api/v1/crates/landlock/0.4.5/download
curl: (22) The requested URL returned error: 403
```

NOTE (correcting an earlier draft of this doc): the fleet's **top-level nixpkgs was
never frozen** — it tracks `nixpkgs-unstable` and was current (May 26), advancing
nightly. The `4bd9165a` (2026-04-14) node in the lock is **only** `cratedigger-src`'s
own bundled nixpkgs (it doesn't `follows` root); the other 16 follower inputs correctly
track current nixpkgs. There was no multi-week deadlock — just a single new-crate-set
fetch that hit crates.io's UA block on May 28.

## Root cause

crates.io enforces an [API data-access policy](https://crates.io/data-access) that
**403s any request whose User-Agent contains `curl/`**. Empirically:

| User-Agent | crates.io api result |
|---|---|
| `curl/8.16.0` | 403 |
| `libcurl/8.16.0` | 403 |
| `Nix/2.34.7` | 200 |
| `Nix/2.34.7 curl/8.16.0` | 403 |
| `reqwest/0.12` | 200 |

Nix's downloader hardcodes `curl/<libcurlver> Nix/<nixver> <suffix>` and only lets you
*append* via `user-agent-suffix` — so there is **no nix.conf knob** to strip the `curl/`
token. `nix-prefetch-url` against the api endpoint 403s too.

`https://static.crates.io/crates/<name>/<name>-<ver>.crate` (crates.io's CDN) returns
**200 for any UA** and serves byte-identical tarballs.

### What's affected

Nix-native crate fetchers that curl the api endpoint directly:

- `pkgs/build-support/rust/fetchcrate.nix` (`fetchCrate`) → **netwatch**
- `pkgs/build-support/rust/import-cargo-lock.nix` (`cargoLock.lockFile`) → **musicbrainz (lrclib), discogs**

**Not** affected: `cargoHash` / `fetchCargoVendor` builds (cargo's own client fetches via
the sparse index / static CDN with cargo's UA).

Crate tarballs are **fixed-output derivations** keyed only on (name, version, sha256),
so they are **nixpkgs-independent**: a recompile against new nixpkgs reuses cached crate
FODs and never re-hits crates.io. crates.io is only contacted when the **crate set
changes** (i.e. a package's `Cargo.lock` changes via an input bump).

## Upstream fix (canonical)

nixpkgs switched crate downloads to `static.crates.io`:

- `fetchCargoVendor`: PR #512735, merged 2026-04-26 (master)
- `importCargoLock`: PR #524985 / commit `f830e6112b`, merged 2026-05-27 (master);
  backported to `release-25.11` (#524988) and `release-26.05` (#524989). Tracking issue #524979.
- `fetchCrate`: PR #525067 / commit `e37f43a408`, merged 2026-05-28 (master); 26.05 backport #525163 pending.

crates.io tracking issue: rust-lang/crates.io#13482.

As of 2026-05-29 the `nixpkgs-unstable` **channel** (rev ~2026-05-27) does **not yet**
carry either fix — channels lag master by the Hydra cycle.

## What we did

Pinned the netwatch input to `fcbe0526` (v0.22.0, already cache-warm) in `flake.nix`.
This freezes its Cargo.lock so its crate FODs stay cached, so the nightly stops trying
to build a newer netwatch whose new crates 403. netwatch builds in its own flake eval
(it `follows` our current nixpkgs, whose `fetchCrate` still uses the blocked api URL
until the channel carries the fix), so an overlay in *our* flake would not reach it —
pinning is the clean lever.

musicbrainz/discogs were left alone: their src inputs are stable (lrclib 2026-02-25,
discogs 2026-05-18) and their crate FODs are cached, so a nixpkgs recompile won't 403.
If `discogs-src`/`lrclib-src` bumps with a changed Cargo.lock before the channel fix
lands, pin that input too (or add the overlay below).

## When to revisit / unpin

Once `nixpkgs-unstable` carries fetchCrate#525067 (check:
`curl -s https://raw.githubusercontent.com/NixOS/nixpkgs/nixpkgs-unstable/pkgs/build-support/rust/fetchcrate.nix | grep registryDl`
shows `static.crates.io`), **unpin netwatch** (`url = "github:matthart1983/netwatch";`)
and let it auto-track again.

## Fallback overlay (if we need to fix in-repo builds before the channel catches up)

Faithful copy of the upstream change; output is byte-identical so caches stay valid:

```nix
final: prev: {
  fetchCrate = args: prev.fetchCrate ({ registryDl = "https://static.crates.io/crates"; } // args);
  rustPlatform = prev.rustPlatform // {
    importCargoLock = args: prev.rustPlatform.importCargoLock (args // {
      extraRegistries = (args.extraRegistries or {}) // {
        "https://github.com/rust-lang/crates.io-index" = "https://static.crates.io/crates";
      };
    });
  };
}
```

Note: this reaches our in-repo builds only, **not** netwatch (separate flake eval).
