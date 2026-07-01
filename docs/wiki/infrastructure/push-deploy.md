# Push-deploy — activate doc1-built closures on hosts that can't rebuild locally

**Researched / built:** 2026-07-01
**Status:** LIVE on `servarr` + `igpu` (forgejo#10)
**Code:** `modules/nixos/autoupdate/push-deploy.nix` (target side),
`scripts/push_deploy.sh` + `modules/nixos/ci/rolling-flake-update.nix` (doc1 side)

## Why

Some fleet hosts can't run their own `nixos-rebuild`:

- **servarr** — 4 GiB RAM; a local eval + closure-copy page-cache blows past 4 GiB
  and the OOM killer shoots the qbt microVM (2026-06-23 incident). `update.enable`
  is off there.
- **igpu** — unprivileged Proxmox LXC; its nightly auto-upgrade *timer* is force-disabled
  (`system.autoUpgrade.enable = mkForce false`), so it stopped getting nightly updates
  even though it has RAM to spare.

doc1 already builds **every** host's `system.build.toplevel` nightly
(`scripts/populate_cache.sh`, invoked from the rolling-flake-update run) and serves
the results from its binary cache (`nixcache.ablz.au`). Push-deploy reuses that: doc1
hands the pre-built store path to the host and the host just **activates** it — no
local eval, no local build, no OOM.

## Trigger model — a restricted forced-command key on `root` (NOT polkit / sudo)

This is the deliberately-tight design (the first cut used a polkit grant to the login
user, which on a locked host is a new passwordless-root path for any session of that
user — rejected). Instead:

- The target authorizes **one** key on `root`: doc1's fleet-deploy trigger key
  (reused — it already lives only on doc1, sops-scoped), pinned with
  `command="<activate-wrapper>",restrict,from="100.64.0.0/10,192.168.1.0/24"`. The key
  can do exactly one thing — run the wrapper as root — and nothing else (no shell, pty,
  or forwarding).
- `PermitRootLogin` is forced to **`forced-commands-only`**: root may log in *only* via
  a forced-command key. Interactive and password root login stay off. This is strictly
  narrower than the `prohibit-password` that `ssh.secure = false` gives (igpu), and it
  opens — for this one key only — the `no` that `ssh.secure = true` sets (servarr).
- doc1 connects `ssh -i <key> root@host "<store-path>"`; sshd ignores the requested
  command, runs the wrapper, and exposes the path as `$SSH_ORIGINAL_COMMAND`.
- The wrapper (as root): validate the path is `/nix/store/*` → `nix-store --realise`
  (substitute from cache) → `nix-env -p /nix/var/nix/profiles/system --set` → `exec
  switch-to-configuration switch`. Exactly what `nixos-rebuild switch` does.

**Result:** target sudo posture is irrelevant ("we don't care about sudo status on the
VMs"), and no interactive/login-user session gains anything. Mirrors the
`fleet-deploy` / marker-convert forced-command pattern.

## Trust boundary

A **leaked deploy key** can still only activate closures **doc1 signed into the cache**:
`nix-store --realise` substitutes a not-yet-local path via the nix daemon, which accepts
it only if the narinfo is signed by a trusted key (doc1's cache key `ablz.au-1:…`,
already trusted at priority 10 on every internal host). Unsigned / unbuildable ⇒ fails
closed. That is the **same trust root as fleet-deploy** (doc1 is the bastion); push-deploy
adds no surface beyond trusting doc1's binary cache, which the host already does.

Verified 2026-07-01 (servarr + igpu): a valid closure activates (exit 0, as root, no
sudo); a non-store path is refused; an arbitrary requested command
(`id > /tmp/pwned`) is completely ignored — the forced command runs the wrapper instead,
exit 1, the file never appears.

## doc1 side

`homelab.ci.rollingFlakeUpdate.pushDeployHosts = ["servarr" "igpu"]` (on doc1). After
each nightly run (post Forgejo-push, and on no-op nights so a host that missed a night
catches up), `scripts/rolling_flake_update.sh` calls `scripts/push_deploy.sh`, which for
each host: resolves the populate_cache GC root (`~/.cache/nix-ci-results/<host>-system`
→ toplevel) and SSHes `root@<host>` with the path. Failures fold into the night's Gotify
summary. The deploy key is `/run/secrets/deploy-trigger/key` (RFU_DEPLOY_KEY).

## Enabling push-deploy on a new host

1. On the host config, set `homelab.update.pushDeploy.enable = true` (and turn the local
   auto-upgrade off — `update.enable = false`, or `system.autoUpgrade` off — so the two
   don't fight). Keep `update.enable = true` only if you still want its GC/fstrim.
2. Add the host to `homelab.ci.rollingFlakeUpdate.pushDeployHosts` on doc1.
3. **Bootstrap the first activation** (the host doesn't have the forced-command key yet):
   - Host that can build / has a root-capable trigger (e.g. igpu, 16 GiB, LXC can eval):
     `fleet-deploy <host>` — its nixos-upgrade builds+switches the new config, installing
     the key. (igpu bootstrapped this way 2026-07-01.)
   - Host that can't build at all (servarr): build its toplevel on doc1
     (`nix build .#nixosConfigurations.<host>.config.system.build.toplevel`), then activate
     once via whatever root path exists today — servarr has abl030 full passwordless sudo,
     so: `ssh <host> "nix-store --realise <top>; sudo nix-env -p /nix/var/nix/profiles/system
     --set <top>; sudo <top>/bin/switch-to-configuration switch"`. That first switch installs
     the key; every subsequent activation rides push-deploy.
4. After bootstrap, verify: `PermitRootLogin forced-commands-only`, root
   `authorized_keys.d/root` holds the `command="…-push-activate"` entry, and
   `ssh -i /run/secrets/deploy-trigger/key root@<host> "<top>"` exits 0.

## Gotchas

- **Bootstrap is chicken-and-egg**: the forced-command key arrives *with* the new
  config, so the very first activation must go through some pre-existing root path
  (sudo where it exists, `fleet-deploy` otherwise, Proxmox console as break-glass).
- **Profile-lock contention**: `nix-env --set` briefly locks the system profile. Firing
  push-deploy on the heels of another switch/GC can hit `Could not acquire lock` (seen
  once during testing, immediately after the bootstrap switch was still settling). A
  single retry clears it; in production the nightly build finishes well before the
  activation, and each host is activated sequentially. Not currently retried in-wrapper.
- **Same-toplevel activation is a fast no-op** (no unit restarts, no sshd bounce, clean
  return). A *real* change restarts sshd, so a `switch` invoked over SSH may drop the
  session's stdout even though the server-side switch completes — verify the resulting
  generation, don't trust the dropped connection.
- **igpu host key**: igpu-as-LXC has a fresh SSH host key; doc1 pins it from hosts.nix.
  If that pin is stale, root@igpu (like any ssh to igpu) fails host-key verification —
  fix the hosts.nix `publicKey` first. See `igpu-lxc-migration.md`.

## Related

- `docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md` — the forced-command
  trigger pattern this reuses.
- `docs/wiki/infrastructure/signed-fleet-deploys.md` — the signature trust root.
- forgejo#10 — the tracking issue.
