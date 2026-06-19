# Fleet deploy trigger + sibling sudo lockdown

**Status:** live (2026-06-19). **EVERY host except doc1 is locked** — doc2,
igpu, hermes, wsl (and cache by default) all run with no passwordless sudo and
accept the `fleet-deploy` trigger; epi/framework are locked workstations. The
trigger is proven end-to-end on doc2, igpu, and hermes.
**Researched/written:** 2026-06-19, during the forgejo#2 Phase 2–4 work +
the "default-secure" role refactor (commits `d8c182b3`, `f3116d05`).
**Tracking:** [forgejo#2](https://git.ablz.au/abl030/nixosconfig/issues/2)
(least-privilege sudo lockdown of always-on siblings), parent
[GitHub #232](https://github.com/abl030/nixosconfig/issues/232).

> **ONE KNOB (refactor 2026-06-19):** posture is now a single option
> `homelab.fleetDeploy.role`, enum `"locked" | "bastion"`, **default `"locked"`**.
> *Every host is locked; doc1 is the one bastion.* A new host is secure by
> default — you must explicitly write `role = "bastion"` to unlock. This replaced
> four scattered knobs (`sudoPasswordless` + `fleetDeploy.acceptTrigger` +
> `fleetDeploy.siblingLockdown` + `fleetDeploy.bastion`), all now derived from
> `role`. The `fleetBastionRoleCheck` flake check asserts exactly one
> `role = "bastion"` in the tree (mirrors `bastionInvariantCheck`). Where the
> sections below say "`acceptTrigger`"/"`siblingLockdown`"/"`sudoPasswordless =
> false`", read "`role = \"locked\"`"; "`fleetDeploy.bastion`" → "`role =
> \"bastion\"`".

> **Scope:** this doc covers **local privilege** on the always-on siblings —
> what `abl030` can do as root once you have a shell there, and how doc1 still
> deploys them without that root. It is the third layer on top of:
> - **host access** (who can SSH where) — [ssh-bastion-model.md](./ssh-bastion-model.md)
> - **deploy trust** (what a host will *build*) — [signed-fleet-deploys.md](./signed-fleet-deploys.md)
> - **secret access** (who can `sops -d` what) — [sops-break-glass-recovery.md](./sops-break-glass-recovery.md)
>
> Service-module least-privilege patterns live in
> [nixos-service-modules.md](../nixos-service-modules.md).

## 1. The goal

Pre-lockdown, every always-on server VM (doc1/doc2/igpu) ran with
`sudoPasswordless = true`: `abl030` had standing, password-free root. That was
fine when the threat model was only "external probe", but it makes the
**post-compromise lateral-movement** model trivial — pop any service running as
`abl030` (or read its session), `sudo -n sh`, and you own root on that VM. With
three such VMs that's three full-root blast radii.

The new posture concentrates high-value root on **one** host and strips it from
the rest:

- **doc1 (proxmox-vm) is the single high-value bastion** (`role = "bastion"`) —
  it keeps passwordless root (it holds the fleet SSH key, the deploy-trigger key,
  the bot signing key, every MCP control cred; it is *already* the crown jewel,
  so locking its sudo buys nothing while breaking the autonomous deploy path).
- **Every other host is locked** (`role = "locked"`, the default) so a popped
  service-or-`abl030` cannot pivot to root. They keep only a narrow read-only +
  deploy-hygiene NOPASSWD allowlist. This now includes the always-on siblings
  (doc2, igpu, hermes, cache) **and** wsl and the epi/framework workstations.

The hard part is keeping doc1 able to *deploy* a locked sibling — a rebuild is a
root action — without giving the sibling back standing root. That is what the
`fleet-deploy` trigger solves.

## 2. The deploy trigger (`homelab.fleetDeploy`)

Module: `modules/nixos/services/fleet-deploy.nix`. It mirrors the
forced-command pattern already used for keyless-host→sibling automation
(`marker-convert` / `gwm-archiver`, #270 — see the bastion doc's "Lateral
service hops" note).

A locked sibling already runs `nixos-upgrade.service`: a root oneshot that runs
the **verified** `fleet-update` path (fetch Forgejo → verify every commit is
signed by a `hosts.nix` key → build at the verified SHA → `switch`). That is the
*same* path the nightly timer uses. The trigger just lets doc1 kick that one
unit, on demand, without sudo on the sibling:

| Side | `role` | What it adds |
|---|---|---|
| sibling | `"locked"` (default) | (a) a **polkit rule** letting `triggerUser` (= the host user) start *only* `nixos-upgrade.service` with no password; (b) a **forced-command authorized key** on that user, locked to exactly `systemctl start --no-block nixos-upgrade.service`, `restrict`ed (no pty/forwarding/etc.) and `from=`-pinned to the tailnet + home LAN (`100.64.0.0/10,192.168.1.0/24`) — plus the narrow NOPASSWD allowlist of §3. |
| doc1 | `"bastion"` | holds the **private** half (sops, `secrets/hosts/proxmox-vm/deploy-trigger-key`, `0400 abl030`) and installs the `fleet-deploy <host>` wrapper that SSHes to the sibling with that key. The wrapper resolves each target's login user + ssh address from `hosts.nix` (so wsl's `nixos@laptop-btibh4ie` works, not just `abl030@<host>`). |

The connection **is** the trigger — there is no command to inject. A successful
SSH with the deploy key does exactly one thing: start the verified rebuild. So a
**leaked deploy key can only kick a rebuild of the already-signed config** — it
cannot run an arbitrary command, read a secret, or deploy unsigned history (the
signed-deploys layer still gates *what* gets built). The polkit grant is
similarly scoped to the single unit + `start` verb + that user; it is what
survives once passwordless sudo is removed.

The trust chain stacks cleanly: **leaked key → can only start a unit →
that unit only builds signed history.** Two independent gates, neither of which
is sudo.

## 3. The sibling lockdown (`role = "locked"`)

`role = "locked"` (the default — nothing to set per host) does both halves at once:

1. `base.nix` (§7) derives `security.sudo.wheelNeedsPassword = true` from
   `role != "bastion"` — `abl030` no longer has standing passwordless root, and
   the base diag-tools NOPASSWD block (see §4) goes empty.
2. The module restores a **narrow** passwordless allowlist so you keep
   observability and bounded recovery without standing root.

The allowlist (`modules/nixos/services/fleet-deploy.nix`, the `role == "locked"`
branch) is exactly:

- **Read-only podman**: `ps`, `inspect`, `logs`, `top`, `port`, `stats`,
  `images`, `network ls/inspect`. (Rootful podman, so even *reading* needs root.
  These have no pager/shell escape. `inspect` can reveal a container's env — a
  minor accepted residual; the win is no root pivot.)
- `systemctl stop nixos-rebuild-switch-to-configuration.service` — deploy
  hygiene: clear a stale deploy-switch so the next `fleet-deploy` isn't blocked.
- `systemctl restart podman-*` — bounded container recovery (container units
  only; cannot touch sshd or other system units).

What is **deliberately not** in the allowlist, and why:

- **No general sudo, no `cat`/`rm`, no exec** — those reintroduce arbitrary root.
- **No `journalctl`** — its pager (`less`) honours `!sh`, which is a root shell
  escape. Read logs via **Loki** (`https://logs.ablz.au`) instead, never
  `sudo journalctl` on a locked host.

The recovery net if the allowlist is ever wrong: `fleet-deploy <host>` rides
**polkit, not sudo**, so a corrected config can always be pushed from doc1 even
when `abl030` has zero usable sudo on the sibling.

## 4. The GTFOBin gate (important)

`base.nix` (§7, `security.sudo.extraRules`) grants a passwordless diag-tools set:
`tailscale`, `tcpdump`, `iotop`, `smartctl`, `dmidecode`, `nmap`, `dmesg`,
`strace`. Several of these are **GTFOBins** — they trivially spawn root:

- `sudo strace -o /dev/null sh` → root shell
- `sudo nmap --interactive` → `!sh` → root shell (and `--script`)
- `sudo tcpdump -z <script> -w …` → runs `<script>` as root

If those stayed NOPASSWD on a *locked* sibling they would be a one-line bypass of
the entire lockdown. So the whole `extraRules` block is now **gated on
`role == "bastion"`**:

```nix
extraRules = lib.optionals (config.homelab.fleetDeploy.role == "bastion") [ … ];
```

- On the bastion (doc1) where `abl030` already has passwordless root the GTFOBins
  change nothing — root is root.
- On any **locked** host the block is empty, so `sudo strace …` etc. **prompt
  for a password** → not a bypass. Diagnose via the read-only allowlist (§3) +
  Loki, or escalate to the host console (§5).

This is the load-bearing subtlety: the lockdown isn't just "drop passwordless
sudo", it's "drop passwordless sudo **and** make sure no remaining NOPASSWD rule
hands root back".

## 5. doc2 specifically (no password = no escape hatch)

doc2 is the strictest case: `abl030` has **no password at all** there (the shadow
field is `!`). So:

- `abl030` literally cannot `sudo` anything outside the §3 allowlist — there is
  no password to satisfy `wheelNeedsPassword`. Interactive sudo is not an escape
  hatch, it's simply unavailable.
- **Break-glass for true root = the Proxmox console on prom** (console login is
  unaffected by sshd's `secure = true`).
- **Recovery if the allowlist itself is ever wrong = `fleet-deploy doc2`** —
  polkit, not sudo, so doc1 can always push a corrected config without any sudo
  on doc2.

igpu is slightly softer: `abl030` **has** a password there, so **interactive
`sudo`** is igpu's break-glass (Proxmox console otherwise). Same allowlist, same
deploy path; only the local fallback differs.

## 6. Per-host posture table

| Host | `role` | Posture | Local break-glass |
|---|---|---|---|
| **doc1** (proxmox-vm) | `"bastion"` | **Bastion** — passwordless root (already the crown jewel; holds fleet/deploy/bot/MCP creds). The ONLY `"bastion"`. | n/a (it *is* root) |
| **doc2** | `"locked"` | **Locked.** No password (`!`). | Proxmox console only |
| **igpu** | `"locked"` | **Locked.** | Interactive sudo (has a password) → Proxmox console |
| **hermes** | `"locked"` | **Locked.** Keyless agent VM, reached via Telegram. Deploy via `fleet-deploy hermes`; agent container unaffected (containers don't use `abl030` sudo). See [hermes-agent](../services/hermes-agent.md). | prom console |
| **wsl** | `"locked"` | **Locked** via `lib.mkForce true` (beats NixOS-WSL's `mkDefault false`). `nixos` removed from the `docker` group (docker-group = root-equivalent, else the lock is theatre). `fleet-deploy wsl` target via a widened `triggerFrom` (Windows portproxy — see §7). | `wsl -u root` from Windows |
| **epimetheus** | `"locked"` | Workstation. Passwordless `nixos-rebuild` grant removed. Owner deploys interactively / nightly. | interactive sudo (has a password) |
| **framework** | `"locked"` | Workstation. Passwordless `nixos-rebuild` grant removed. Owner deploys interactively / nightly. | interactive sudo (has a password) |
| **cache** | `"locked"` | Default-locked; converges when online. | interactive sudo (`initialHashedPassword`) |

## 7. How to deploy now

From **doc1** (the only host with the trigger key):

```sh
fleet-deploy doc2     # kick doc2's verified rebuild
fleet-deploy igpu     #   "  igpu
fleet-deploy hermes   #   "  hermes
fleet-deploy wsl      #   "  wsl (resolves nixos@laptop-btibh4ie; see below)
fleet-deploy cache    #   "  cache (when online)
```

No `sudo` runs on the target; the SSH connection *is* the success. The wrapper
uses the doc1-scoped sops deploy key with `IdentitiesOnly` / `BatchMode`, and
maps `<host>` → login user + ssh address from `hosts.nix`.

**wsl is reached through a Windows netsh portproxy**, so wsl's sshd sees every
connection from the WSL vEthernet gateway (`172.26.224.1`, in `172.16.0.0/12`),
**not** doc1's tailnet IP. The default trigger `from=` pin would reject the key
(publickey denial), so wsl sets `homelab.fleetDeploy.triggerFrom` to add
`172.16.0.0/12` (the WSL bridge is wsl's only ingress, so this is equivalent to
LAN-pinning a normal host; the key stays doc1-only + forced-command). wsl can
also deploy via the nightly timer or `wsl -u root fleet-update`.

**It is async.** The forced command is `systemctl start --no-block …`, so
`fleet-deploy` returns as soon as the unit is *started*, not when the build
finishes — you do **not** get a live build stream. Confirm completion via
read-only checks instead:

- `cat /var/lib/fleet-update/last-verified-freshness` (the marker the verified
  path writes; see [signed-fleet-deploys.md](./signed-fleet-deploys.md#freshness-markers)),
- the read-only podman/Loki checks from §3,
- or `systemctl status nixos-upgrade.service` via the Proxmox console if you need
  the unit's own exit state.

### doc2 switch-hang wrinkle + the stop-switch hygiene grant

On doc2 the `nixos-rebuild switch` step can **hang** when a long-running oneshot
is mid-flight (the activation waits on it), leaving
`nixos-rebuild-switch-to-configuration.service` stuck. That is exactly why the
§3 allowlist includes:

```sh
sudo systemctl stop nixos-rebuild-switch-to-configuration.service
```

Clearing that stale switch unit lets the **next** `fleet-deploy` proceed instead
of erroring on an in-progress deploy. It is deploy hygiene, scoped to that one
unit — not general `systemctl` access.

## When to revisit

- **Phase 5** (forgejo#2, comment #2): strip doc1 to SSH-only — relocate every
  listening service off the bastion. Not started; sequenced after this lockdown.
- When [#241](https://github.com/abl030/nixosconfig/issues/241) (step-ca /
  short-lived certs) lands — the deploy trigger may move under a CA-signed
  ephemeral-cert model rather than a static forced-command key.
- If a future locked sibling needs a diag tool that isn't a GTFOBin and isn't in
  the §3 allowlist, add it to the `role == "locked"` allowlist in
  `fleet-deploy.nix` (read-only, no-shell-escape only) — never re-enable the §4
  GTFOBin block on a locked host.
