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
- The wrapper does the **minimum in-session**: validate the path is `/nix/store/*` →
  stage it to a root-only file (`/run/push-deploy/staged`, dir `0700 root`) → `systemctl
  start --no-block push-activate.service` → exit. The **heavy work runs under PID 1**,
  not in the login session: `push-activate.service` (oneshot) reads the staged path,
  `nix-store --realise`s it (substitute from cache), `nix-env --set`s the system profile,
  and `switch-to-configuration switch`es. Exactly what `nixos-rebuild switch` does.

**Why the trigger-and-detach split** (mirrors fleet-deploy's `systemctl start --no-block
nixos-upgrade`): running `switch` *inside* the root SSH session leaves root's `systemd
--user` manager holding `/run/user/0`, and on an LXC the runtime-dir teardown then loses
the race on logout — `user-runtime-dir@0.service` fails with "Directory not empty" and the
whole host goes **degraded** (observed on igpu, first cut). Firing `--no-block` and exiting
keeps the root session trivial, so `/run/user/0` is empty at teardown and cleans up fine;
the switch runs later under PID 1 where no login session exists.

**Result:** target sudo posture is irrelevant ("we don't care about sudo status on the
VMs"), and no interactive/login-user session gains anything. The staged path is root-only
(the login user can't write it), and `push-activate.service` re-validates + signature-checks
on read, so staging adds no surface.

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
→ toplevel), SSHes `root@<host>` with the path to trigger, then — because activation is
`--no-block` — **polls** the host (read-only, login-user session, no privilege) until
`push-activate.service` settles: success when the system generation == the target closure
and the unit isn't failed; failure on a failed unit or a ~5-min timeout. Failures fold into
the night's Gotify summary. The deploy key is `/run/secrets/deploy-trigger/key`
(RFU_DEPLOY_KEY).

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
- **Runtime-dir race on LXC (handled two ways)**: root now logs in (forced-command) to
  fire the trigger — it never did before — and on the igpu LXC that login's `/run/user/0`
  loses its teardown race on logout: `user-runtime-dir@0.service`'s ExecStop rmdir fails
  "Directory not empty" (exit 1) → host `degraded`. It is cosmetic (the tmpfs is
  unmounted; the next login re-mounts fine). Two fixes together: (1) the trigger-and-detach
  split (`--no-block`, switch under PID 1) keeps the *switch* out of the session — do **not**
  move it back in to "get a synchronous exit code", poll instead; and (2) a drop-in on
  `user-runtime-dir@0.service` sets `SuccessExitStatus=1` so that benign exit-1 doesn't mark
  the host degraded. (1) alone fixed servarr (a VM); igpu reproduced the race even with an
  empty trigger, so (2) is what actually keeps the LXC clean. Verified 2026-07-01: after a
  full `push_deploy.sh` run both hosts stay `running`, no failed units.
- **Profile-lock contention**: `nix-env --set` briefly locks the system profile. Firing
  push-deploy on the heels of another switch/GC can hit `Could not acquire lock` (seen
  once during testing, right after a bootstrap switch was still settling). In production
  the nightly build finishes well before the activation and hosts are activated
  sequentially; a transient collision just fails that host for the night (logged, retried
  next run). Not currently retried in-service.
- **Same-toplevel activation is a fast no-op**; the poll matches the generation
  immediately. Because the switch now runs under PID 1, an sshd restart during a *real*
  change no longer drops the trigger connection (the trigger already returned).
- **igpu host key**: igpu-as-LXC has a fresh SSH host key; doc1 pins it from hosts.nix.
  If that pin is stale, root@igpu (like any ssh to igpu) fails host-key verification —
  fix the hosts.nix `publicKey` first. See `igpu-lxc-migration.md`.

## Related

- `docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md` — the forced-command
  trigger pattern this reuses.
- `docs/wiki/infrastructure/signed-fleet-deploys.md` — the signature trust root.
- forgejo#10 — the tracking issue.
