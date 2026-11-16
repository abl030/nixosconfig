# Local Nix binary cache (nixcache.ablz.au): harmonia

**Date:** 2026-11-17
**Status:** harmonia replaced nix-serve on doc1 (proxmox-vm) on 2026-11-17.
**Module:** `modules/nixos/nix_caches/nix_cache.nix` (`homelab.cache.localHost`)
**Related:** [nix-mirror-failover.md](nix-mirror-failover.md) (the separate
`nix-mirror.ablz.au` pull-through mirror of cache.nixos.org, in the same module).

## What it is

doc1 serves its own `/nix/store` as a signed binary cache at
`https://nixcache.ablz.au`. nginx terminates TLS and proxies to a loopback
backend on `127.0.0.1:5000`. Clients trust `ablz.au-1:EYnQ/...` and set the
priority per URL in `client_profile.nix`. The `server` profile skips it; the
`internal` and `external` profiles use it for paths upstream lacks, such as
unfree packages and local builds.

## Incident 2026-11-17: nix-serve silently dead for about 5 hours

- doc1 rebooted onto nixpkgs `5d2b81a` (Nix 2.35) at 01:56 AWST.
- nixpkgs' `nix-serve` takes its Perl bindings as
  `nix.libs.nix-perl-bindings or null`, and Nix 2.35 no longer provides them.
  The `or null` hid the loss at build time.
- Every starman worker then died on `Can't locate Nix/Config.pm`. The master
  stayed `active (running)`, so systemd saw nothing wrong. nginx requests hung
  until timeout, there was no 5xx, and no alert fired. The crash loop burned about
  3.6 cores and pushed about 2.3M error lines an hour into Loki.
- The morning triage found it by noticing doc1's Loki volume.

## Fix

- The backend is now `services.harmonia.cache`, upstream's NixOS module. It
  uses the Nix C API, so it has no Perl-binding dependency, and runs
  socket-activated as a sandboxed `DynamicUser`. The root-only signing key
  (`/var/lib/nixcache/secret.key`) reaches it through `LoadCredential`, so the
  key's owner and mode are unchanged. It uses the same bind, key and vhost, so no
  client changes.
- An Uptime Kuma monitor, `Nix binary cache`, probes
  `https://nixcache.ablz.au/nix-cache-info`. A dead backend shows up there as a
  timeout.

## Revisit

- If harmonia ever misbehaves, the fallback is `nix-serve-ng` (Haskell, libnix).
  Don't go back to `nix-serve` unless nixpkgs restores the Perl bindings.
