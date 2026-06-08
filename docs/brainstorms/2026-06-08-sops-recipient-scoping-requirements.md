---
date: 2026-06-08
topic: sops-recipient-scoping
title: Least-privilege sops recipient scoping (#234)
---

# Least-privilege sops recipient scoping (#234)

## Summary

Shrink `secrets/.sops.yaml` from a single catch-all that encrypts every secret to
every host key down to per-host scoping: each secret is decryptable only by its
consuming host(s) plus two named universal keys — a cold off-box **break-glass**
key and a warm doc1-only **editor** key. Mint a real break-glass key first (there
isn't one today), then scope the fleet key, the infra-control tokens, and the
service secrets in three sequenced PRs.

## Problem Frame

The doc1 SSH bastion ([#270](https://github.com/abl030/nixosconfig/issues/270),
shipped 2026-06-08) made siblings keyless so a popped sibling can't move laterally
over SSH. The secret layer still leaks straight through it. `secrets/.sops.yaml`
has one `path_regex: .*` rule encrypting all ~26 root secrets to 12 age recipients,
so a popped sibling's root can `sops -d` **any** secret in the repo — including
`ssh_key_abl030`, which *is* the fleet key. The bastion is undermined at the secret
layer until this lands.

Two audit assumptions turned out to be wrong, and both raise the stakes:

- **There is no break-glass key today.** "Master Fleet Identity" (`age1d30…`) is
  not an independent key — it is `ssh-to-age(ssh_key_abl030)`, i.e. the fleet SSH
  key in age form (proven: converting the `master-fleet-identity` pubkey yields
  `age1d30…` exactly). Its private half lived on every host until #270, now doc1
  only. Nothing decrypts *with* it (hosts use their own host keys; sops-nix and the
  MCP activation script both read `/etc/ssh/ssh_host_ed25519_key`), so its only
  real role is the (circular) break-glass label. The true cold-recovery root is
  doc1's host SSH key — single copy, no off-box backup. Shrinking recipient lists
  removes the redundancy currently papering over that gap, so a real break-glass
  key must come first.

- **The MCP control creds are not disabled — they're deployed fleet-wide.**
  `modules/nixos/profiles/base.nix` sets `homelab.mcp.enable = mkDefault true` with
  all seven sub-services on, and no host overrides it. All nine live NixOS hosts run
  an activation script that `sops -d`'s seven MCP env files — including the pfSense,
  UniFi, and Home Assistant infra-control tokens — to a user-readable
  `/run/secrets/mcp/*` at boot. The `removing secrets: mcp/*` deploy-log line is
  sops-nix pruning a stale manifest from the old implementation, not evidence of
  disablement. This is a Tier-1 finding in its own right (feed back to
  [#232](https://github.com/abl030/nixosconfig/issues/232)).

## Key Decisions

- **Two named universal keys, nothing else broad.** Every secret is encrypted to
  its consuming host key(s) **+ editor + break-glass**. No secret is encrypted to a
  host that doesn't consume it (except the deliberately fleet-wide group).
- **break-glass:** a freshly minted age keypair, *not* derived from any SSH key,
  private half stored in a Bitwarden secure note. Cold — never lands on a host.
  Recovery only. Added and verified on every file *before* any recipient is removed.
- **editor:** a freshly minted age keypair living only on doc1
  (`~/.config/sops/age/keys.txt`), a recipient on every secret so doc1 (the bastion
  / where Claude runs) can edit any secret. Warm. Not separately backed up —
  break-glass reconstructs it if doc1 is lost. doc1's *system* activation is
  unaffected (it decrypts via its host key, not the editor key).
- **Retire three confusing/dead identities:** the fleet-key-as-master recipient
  (`age1d30…`, no decryption duty once break-glass exists), the shared "Proxmox VM
  and IGPU User Age Key" (`age1wnxn…`), and the dead `age1nurxq4…` on igpu (a
  recipient nowhere). Post-refactor model is exactly: *one host key each + two named
  universal keys.*
- **Rule structure = A1: location = scope.** Per-host-dir glob rules
  (`^hosts/<H>/.*` → `H + editor + break-glass`); single-host secrets currently
  loose in `secrets/` root get `git mv`'d into their host dir; genuinely-shared
  secrets get explicit multi-recipient rules; the trailing `.*` fallback tightens to
  **editor + break-glass only** so a new unscoped secret deploys nowhere until given
  a rule (fail-closed). A `nix flake check` assertion enforces the invariant.
- **MCP creds → doc1 only.** Flip `homelab.mcp.enable` to `mkDefault false` and
  opt-in on doc1 (the same bastion pattern as `deployIdentity`). doc1 is the sole
  host the control agents run from.
- **Split the pfSense token.** Mint a read-only pfSense user + API key for the doc2
  metrics exporter; keep the full-control key doc1-only. A popped doc2 then yields
  read-only pfSense metrics, never control.
- **Migrate, don't defer.** All work executed in this effort across three sequenced
  PRs (risk + deploy-ordering boundaries, not scope-splitting). Each scoping change
  lands its `.sops.yaml` re-key and its `.nix` consumer change in **one commit** so
  a host pulling from GitHub never straddles a broken state.

## Requirements

### Recipient model

- R1. Every secret is encrypted to exactly `{ consuming host key(s) } + editor +
  break-glass`, except the fleet-wide group (R12) and the multi-host group (R13).
- R2. break-glass is a fresh age key, not SSH-derived, private half in a Bitwarden
  secure note, present on no host.
- R3. editor is a fresh age key present only on doc1's
  `~/.config/sops/age/keys.txt`, a recipient on every secret.
- R4. `age1d30…` (fleet-key-as-master), `age1wnxn…` (shared editor), `age1nurxq4…`
  (dead igpu user key), and the dev + two sandbox host keys are removed from all
  recipient lists.

### Rule structure (A1)

- R5. `.sops.yaml` uses per-host-dir glob rules `^hosts/<H>/.*`; no blanket
  to-everyone rule remains.
- R6. Single-host secrets currently in `secrets/` root are `git mv`'d into their
  consuming host's dir; `resolve()` keeps consumers working unchanged.
- R7. The trailing `.*` fallback is scoped to editor + break-glass only (fail-closed).
- R8. A `nix flake check` assertion fails the build if any `hosts/<H>/` secret's
  recipient set is not a subset of `{ H host key, editor, break-glass }`.

### Tier scoping (blast radius)

- R9. **Tier 0 — fleet key.** `ssh_key_abl030` → doc1 only. Claude's autonomous
  sibling-deploy must still work; siblings must fail to decrypt it.
- R10. **Tier 1 — infra control.** `pfsense-mcp.env` (control half), `unifi-mcp.env`,
  `homeassistant-mcp.env` → doc1 only. `homelab.mcp.enable` defaults to false,
  opt-in on doc1.
- R11. **Tier 2 — app/service secrets.** Each scoped to its single consuming host
  (mostly doc2; meelo + agent creds on doc1; igpu jellyfin authkey; epi komga/wayvnc;
  per-host syncthing certs already placed).
- R12. **Tier 3 — fleet-wide.** `nix-netrc`, `atuin-session`, `atuin-key`,
  `gotify.env` → all live host keys (doc1, doc2, igpu, epi, framework, wsl, cache) +
  editor + break-glass.
- R13. **Multi-host.** `acme-cloudflare.env` → {doc1, doc2, igpu, wsl}.

### pfSense token split

- R14. A dedicated read-only pfSense user + API key backs the doc2 exporter, stored
  at `secrets/hosts/doc2/pfsense-exporter.env`, scoped doc2. `loki.nix` resolves the
  new name.
- R15. The full-control pfSense key moves to `secrets/hosts/proxmox-vm/pfsense-mcp.env`,
  scoped doc1.

### Cleanup

- R16. Delete the stale dead root duplicates `secrets/mealie.env`,
  `secrets/paperless.env`, `secrets/webdav.env` (doc2 reads the `hosts/doc2/`
  copies; root copies differ and are read by nobody).
- R17. `tailscale-oauth.yaml` → doc2 (work-in-progress; no consumer in the repo yet).
- R18. Clean up igpu's vestigial `sops.age.keyFile` and the dead user `keys.txt`;
  igpu decrypts via its host key (`age17pe`) through `sshKeyPaths`.

## Recipient scope map

Every scope below is implicitly `+ editor + break-glass`.

| Scope | Secrets | Action |
|---|---|---|
| **doc1** | `ssh_key_abl030`, `pfsense-mcp.env` (control), `unifi-mcp.env`, `homeassistant-mcp.env`, `slskd-mcp.env`, `paperless-mcp.env`, `audiobookshelf-mcp.env`, `vinsight-mcp.env`, `meelo.env`, `meelo-pgpass.env` | `git mv` loose ones → `hosts/proxmox-vm/` |
| **doc2** | `immich.env`, `kopia.env`, `loki.env`, `musicbrainz.env`, `slskd.env`, `soularr.env`, `uptime-kuma.env`, `uptime-kuma-api.env`, `tailscale-oauth.yaml`, `pfsense-exporter.env` (new RO), + the ~20 files already in `hosts/doc2/` | `git mv` loose → `hosts/doc2/`; re-key in-place ones |
| **igpu** | `jellyfin-tailscale-authkey.env` | already placed |
| **epi** | `komga-sync.env` (epi copy), `wayvnc.yaml` | scope / move |
| **per-host** | `syncthing-cert.pem` + `syncthing-key.pem` ×7 | already placed (A1 model case) |
| **fleet-wide** (doc1, doc2, igpu, epi, framework, wsl, cache) | `nix-netrc`, `atuin-session`, `atuin-key`, `gotify.env` | broad rule, dev/sandbox dropped |
| **{doc1, doc2, igpu, wsl}** | `acme-cloudflare.env` | multi-host rule (wsl = cullen-dashboard) |
| **delete** | root `mealie.env`, `paperless.env`, `webdav.env` | stale dead duplicates |

## Migration plan

Driven from doc1 using its current editor key (`age1wnxn…`, still a catch-all
recipient) until the editor swap in PR1. Tracked under #234.

- **PR1 — Safety foundation (additive, ~zero deploy risk).**
  1. `age-keygen` break-glass → Bitwarden note (record the `age1…` public);
     `age-keygen` fresh editor.
  2. Add both recipients to every group; `sops updatekeys` across `secrets/**`.
  3. Verify break-glass decrypts from the Bitwarden copy
     (`SOPS_AGE_KEY_FILE=<tmp> sops -d <file>`, on 2–3 files) and the fresh editor
     decrypts; then `shred` the temp.
  4. Swap doc1's `~/.config/sops/age/keys.txt` to the fresh editor.
  5. Drop retired recipients (R4); re-key. Verify every live host still rebuilds;
     verify igpu rebuilds via its host key and clean up its `keyFile`/dead `keys.txt`.

- **PR2 — Critical creds (one commit).**
  1. Scope `ssh_key_abl030` → doc1 (R9). Verify: doc1 rebuild deploys it; `doc1 →
     sibling` SSH still works (Claude autonomous deploy); from a sibling,
     `SOPS_AGE_KEY=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key)
     sops -d secrets/hosts/proxmox-vm/ssh_key_abl030` **fails**.
  2. Flip `homelab.mcp.enable` default → false + opt-in doc1; move the agent envs to
     `hosts/proxmox-vm/`; split the pfSense token (subagent mints the RO user, new
     `hosts/doc2/pfsense-exporter.env`, update `loki.nix`); re-key — all in one commit.
  3. Verify: doc1 has `/run/secrets/mcp/*`; doc2 exporter scrapes with the RO key;
     siblings have no `/run/secrets/mcp`; sibling decrypt of `pfsense-mcp.env` fails.

- **PR3 — Bulk sweep + guard + docs (one commit).**
  1. `git mv` the loose root single-host secrets into host dirs; write per-host-dir
     glob rules; assign the fleet-wide (R12) and multi-host (R13) groups; scope
     `wayvnc.yaml`/`tailscale-oauth.yaml`; tighten the `.*` fallback (R7); delete the
     three stale dups (R16).
  2. Add the `nix flake check` assertion (R8). Final `git grep` / decrypt audit.
  3. Document break-glass recovery in `docs/wiki/infrastructure/`.

## Scope Boundaries

- Not rotating the secret *values* — this is recipient scoping only (except the new
  pfSense RO key and the two new age keys).
- Not the step-ca / CA-signed-cert architecture
  ([#241](https://github.com/abl030/nixosconfig/issues/241)) — this is the
  no-infra hardening underneath it.
- Not the tailnet ACL work ([#239](https://github.com/abl030/nixosconfig/issues/239)) —
  independent; dev/sandbox being already dead is the only overlap consumed here.

## Dependencies / Assumptions

- dev and sandbox are already offline (both time out on SSH); their keys drop with
  zero risk.
- doc1's existing editor key (`age1wnxn…`) is a current catch-all recipient and can
  `sops updatekeys` every file to drive PR1.
- The pfSense REST API honours per-user privileges, so a metrics-read-only user is
  feasible; the `pfsense` subagent mints it.
- doc1 is the only host the pfsense/unifi/HA control agents run from.

## Outstanding Questions

Resolve during migration (not blocking):

- igpu's `/var/lib/sops-nix/key.txt` identity is unread (no passwordless sudo on
  igpu). Not a blocker — igpu decrypts via `sshKeyPaths` host key regardless — but
  confirm igpu rebuilds cleanly after `age1wnxn…` is dropped, then remove the
  vestigial `keyFile`.

Deferred to planning:

- The exact pfSense privilege set for the read-only exporter user (which API
  endpoints the exporter scrapes).
- The implementation shape of the R8 flake-check assertion (mirror
  `bastionInvariantCheck` in `flake.nix`).

## Sources / Research

- Proof "master" = fleet key: `ssh-to-age` of the `master-fleet-identity` pubkey
  (`hosts.nix` let-block) yields `age1d30…` verbatim. Each `.sops.yaml` host
  recipient = `ssh-to-age` of that host's `publicKey`.
- MCP fleet-wide deploy verified live: `/run/secrets/mcp/{pfsense,unifi,homeassistant,
  slskd,vinsight,audiobookshelf,paperless}.env` present on doc1, env vars exported;
  `base.nix` `homelab.mcp.enable = mkDefault true`, no overrides.
- pfSense dual-use: `modules/nixos/services/loki.nix` (exporter, `auth_method: key`,
  read-only) and `.claude/agents/pfsense.md` (full control) share one
  `PFSENSE_API_KEY`.
- Consumer map: `meelo` on doc1 (`hosts/proxmox-vm/configuration.nix:57`,
  `immich.enable = false` there); `acme-cloudflare` on wsl via
  `services.cullen-dashboard` → `homelab.localProxy` → `homelab.nginx`.
- `resolve()` precedence (`modules/nixos/common/secrets.nix`): `hosts/<host>/` >
  `users/<user>/` > root — scopes deployment, not decryptability.
