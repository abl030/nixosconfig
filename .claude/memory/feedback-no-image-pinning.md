---
name: feedback-no-image-pinning
description: Never pin container image tags — auto-updates on everything is a hard line
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a634fa58-2bc4-4ebd-a441-bb59a7d3bc4b
---

NEVER pin container images (no `@sha256:` digests, no frozen version tags). The
user wants `:latest` + auto-pull/auto-update on **every** container, fleet-wide.
This is an explicit, non-negotiable line — do not propose digest-pinning, a
`:latest`/`:master` CI gate, or "review on bumps" workflows again.

**Why:** the user values staying current automatically over the supply-chain
risk that image-pinning would mitigate. They accept that risk knowingly.

**How to apply:** issue #232 TIER-4 ("digest-pin images") and the cross-cutting
"CI check that flags `:latest`/`:master`" item are effectively **WONTFIX** —
record that on the issue, don't reopen the debate. The correct mitigation for
running `:latest` with auto-pull is **runtime hardening** (cap-drop=all +
no-new-privileges + minimal cap-add per container, via
[[`homelab.podman.hardenOptions`]]), NOT pinning. Harden the blast radius of a
compromised auto-pulled image instead of trying to prevent the pull.

**State as of 2026-06-19 (all registry pins lifted):** youtarr, hermes, and
musicbrainz valkey were the only digest-pinned registry images — all unpinned to
`:latest` + auto-pull this session. hermes specifically: the "arbitrary-code
executor must not self-update" pin was dropped as inconsistent (the nightly
agent tooling has the same profile and auto-updates); it's now registered in
`homelab.podman.containers` (`isolate=false`). **No registry tag-pins remain.**

**Same call for FLAKE INPUTS (2026-06-20):** ~27 of ~30 flake inputs track a
moving branch (`home-manager/master`, `nixos-hardware/master`, `NixOS-WSL/main`,
+ ~24 with no `ref` = default branch). "Pin flake inputs off master" (#232 CI
block) is **WONTFIX** for the same reason — rolling-flake-update bumps them
nightly by design; that IS the policy. (`home-manager/master` is also *correct*
for `nixpkgs-unstable` — a release branch would mismatch.) The whole #232 **CI
block is WONTFIX/resolved**: GC retention stays `--delete-older-than 3d`
(`autoupdate/update.nix`; user kept it 2026-06-20); `GH_TOKEN`-in-env is already
moot (deprecated at the Forgejo cutover — token *values* are never in unit env,
only `*_FILE` paths). Same compensating control as images: runtime hardening +
signed fleet deploys, not pinning. Don't reopen.

**CARVE-OUT (2026-08-12, forgejo #142) — UniFi's MongoDB is digest-pinned.** The
operator authorised this ON the issue ("pinned by immutable digest" is an
acceptance criterion), so it is a decision, not a relapse. The argument is
**data durability, not supply chain**, which is a different policy question from
the one settled above: MongoDB's major version is coupled to the installed UniFi
release, and MongoDB **refuses to start on a dbpath written by a newer major
version, with no downgrade path**. An auto-pulled `:latest` would roll the DB to
MongoDB 8 one night and leave an un-downgradable dbpath — i.e. **data loss that
runtime hardening cannot contain**, so the usual compensating control doesn't
apply. Pin lives in `modules/nixos/services/unifi-controller.nix` with an
`IMAGE-PIN-OK:` marker; rationale in
`docs/wiki/nixos-service-modules.md` "Image trust".

**Do NOT generalise this.** Everything above still stands — no other registry
pin, no `:latest` CI gate, don't reopen. The bar for a future exception is
exactly "auto-updating this image can destroy persistent state in a way
hardening cannot contain", which in practice means a database engine with a
one-way on-disk format. `hermes`, `youtarr`, `musicbrainz valkey` etc. stay
unpinned.

**The ONE distinction that is NOT a violation:** images **built locally via
`dockerTools`/`podman build` from a `flake = false` input** are NOT registry
pins — e.g. musicbrainz's `mb-solr` (search), `musicbrainz`, `indexer`, `mq`,
`lrclib`. They ride the flake input and are updated by bumping that input
(reviewed). mb-solr is also **schema-coupled** to the MB server, so it MUST stay
input-tracked, not chased to a mutable tag. Don't "fix" these — they're correct.
