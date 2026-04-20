# Retired Container Stacks

**Date retired:** 2026-04-16
**Status:** Removed — recover from git history if ever needed

## What happened

The homelab started on podman-compose container stacks under `stacks/*/`. Over
early-to-mid 2026 almost every service was rewritten as a native NixOS module
under `modules/nixos/services/` (the "service hierarchy" in
`.claude/rules/nixos-service-modules.md` — prefer upstream module > custom
module > OCI container > compose stack). The stack definitions were left in
place as a rollback escape hatch, with the entries commented out in
`hosts.nix#containerStacks`. Several more stacks (graylog, nicotine, nzbget,
ollama, syncthing, test-force-recreate) were never registered at all and had
rotted since at least January 2026.

On 2026-04-16 the whole graveyard was torn out in one pass. We also retired
openobserve in the same session — see the preceding commit for that one.

## What remains in `stacks/`

**Nothing.** The whole `stacks/` tree was deleted. The rootless-compose
infrastructure went with it:

- `modules/nixos/homelab/containers/` (rootless podman setup + stack registry) — removed
- `stacks/lib/podman-compose.nix` (the `mkService` compose helper) — removed
- `stacks/README.md` — removed
- `containerStacks` field on `hosts.nix` entries — removed from all hosts

The nspawn PostgreSQL helper (`modules/nixos/lib/mk-pg-container.nix`) is
unaffected — it was always in `modules/nixos/lib/`, not `stacks/lib/`, and is
actively used by the native services that replaced the compose stacks.

Rootful OCI containers continue to work via `homelab.podman` +
`virtualisation.oci-containers` (tdarr-node, youtarr, netboot, jdownloader2,
the tailscale-share sidecars). That's the path for anything that still needs a
container going forward.

## What was removed

### Orphans (never registered, pure bitrot)

- `graylog/` — had only a raw `docker-compose.yml`
- `nicotine/`
- `nzbget/` — wasn't even a compose stack, just a `TouchModTime/` script dir
- `ollama/`
- `syncthing/` — superseded long ago by the native `services.syncthing` module
- `test-force-recreate/` — test artifact

### Superseded by native NixOS services (never referenced from any host)

- `atuin/` → `modules/nixos/services/atuin.nix`
- `audiobookshelf/` → `modules/nixos/services/audiobookshelf.nix`
- `immich/` → `modules/nixos/services/immich.nix`
- `loki/` → `modules/nixos/services/loki-server.nix` (part of the LGTM stack, see
  `docs/wiki/services/lgtm-stack.md`)
- `tautulli/` → `modules/nixos/services/tautulli.nix`

### Migrated to native NixOS modules on doc2 (the doc1 → doc2 migration, tracked
in the former GitHub issue #208)

- `invoices/` — decommissioned outright, no replacement
- `jdownloader2/` → OCI container via `services/jdownloader2.nix`
- `kopia/` → `services/kopia.nix`
- `mealie/` → `services/mealie.nix`
- `music/` → `services/{lidarr,slskd,cratedigger,discogs}.nix` (the stack split into
  per-app modules)
- `musicbrainz/` → `services/musicbrainz.nix` (NixOS-native mirror, replaced
  the compose-based mb-docker mirror — see `docs/wiki/services/` for the
  current setup)
- `netboot/` → OCI container via `services/netboot.nix`
- `paperless/` → `services/paperless.nix`
- `smokeping/` → `services/smokeping.nix`
- `StirlingPDF/` → `services/stirlingpdf.nix`
- `uptime-kuma/` → `services/uptime-kuma.nix`
- `WebDav/` → `services/webdav.nix`
- `youtarr/` → OCI container via `services/youtarr.nix`

### Orphan SOPS env files removed alongside

`secrets/{atuin,domain-monitor,invoices,jdownloader2,music,netboot,smokeping,tautulli,youtarr}.env`
— these were only referenced by the stacks above. The native replacements either
use a different secret (`atuin-key` / `atuin-session` for atuin) or no secret
at all.

### Plan docs pruned

- `docs/observability-plan.md` — pre-LGTM plan that still referenced the old
  immich stack path; superseded by the LGTM build-out
  (`docs/wiki/services/lgtm-stack.md`).
- `docs/musicbrainz-mirror-plan.md` — implementation plan for the compose-based
  MusicBrainz mirror on doc1, obsolete after the native NixOS rewrite on doc2.

### Final three stacks removed in the same pass

- `tailscale-caddy` (doc1) — was providing a tailnet-accessible caddy proxy.
  Replaced by the per-service `homelab.tailscaleShare` pattern in
  `modules/nixos/services/tailscale-share.nix`.
- `restart-probe`, `restart-probe-b` (wsl) — probe/test stacks from an earlier
  investigation into systemd restart semantics. No longer needed.

Their secret (`secrets/caddy-tailscale.env`) was removed too.

## Recovering a retired stack

If you ever need to bring one back:

```bash
git log --all --full-history -- stacks/<name>
git show <commit>^:stacks/<name>/docker-compose.yml
git show <commit>^:stacks/<name>/docker-compose.nix
```

The removal commit is the one immediately after `2408349f` (openobserve retirement).

Before resurrecting, re-read `.claude/rules/nixos-service-modules.md` — the
service hierarchy prefers a native NixOS module over an OCI container over
(now) nothing. Compose stacks are no longer a supported deployment shape in
this repo; if you truly need compose, you'd need to bring the
`stacks/lib/podman-compose.nix` helper + `modules/nixos/homelab/containers/`
tree back from git history first.
