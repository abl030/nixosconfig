# Fleet deploy trigger + sibling sudo lockdown

**Status:** live (2026-06-19). doc2 and igpu are both locked; the
`fleet-deploy` trigger is proven end-to-end on both.
**Researched/written:** 2026-06-19, during the forgejo#2 Phase 2–4 work.
**Tracking:** [forgejo#2](https://git.ablz.au/abl030/nixosconfig/issues/2)
(least-privilege sudo lockdown of always-on siblings), parent
[GitHub #232](https://github.com/abl030/nixosconfig/issues/232).

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

- **doc1 (proxmox-vm) is the single high-value bastion** — it keeps passwordless
  root (it holds the fleet SSH key, the deploy-trigger key, the bot signing key,
  every MCP control cred; it is *already* the crown jewel, so locking its sudo
  buys nothing while breaking the autonomous deploy path).
- **Every other always-on host (doc2, igpu) is locked** so a popped
  service-or-`abl030` cannot pivot to root. They keep only a narrow read-only +
  deploy-hygiene NOPASSWD allowlist.

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

| Side | Option | What it adds |
|---|---|---|
| sibling | `fleetDeploy.acceptTrigger = true` | (a) a **polkit rule** letting `triggerUser` (= `abl030`) start *only* `nixos-upgrade.service` with no password; (b) a **forced-command authorized key** on that user, locked to exactly `systemctl start --no-block nixos-upgrade.service`, `restrict`ed (no pty/forwarding/etc.) and `from=`-pinned to the tailnet + home LAN (`100.64.0.0/10,192.168.1.0/24`). |
| doc1 | `fleetDeploy.bastion = true` | holds the **private** half (sops, `secrets/hosts/proxmox-vm/deploy-trigger-key`, `0400 abl030`) and installs the `fleet-deploy <host>` wrapper that SSHes to the sibling with that key. |

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

## 3. The sibling lockdown (`sudoPasswordless = false` + `siblingLockdown`)

Two coordinated changes lock a sibling:

1. `hosts.nix`: `sudoPasswordless = false`. This flips
   `security.sudo.wheelNeedsPassword` to `true` in `base.nix` (§7) — `abl030` no
   longer has standing passwordless root, and the base diag-tools NOPASSWD block
   (see §4) goes empty.
2. `fleetDeploy.siblingLockdown = true` (in the host's `configuration.nix`):
   restores a **narrow** passwordless allowlist so you keep observability and
   bounded recovery without standing root.

The allowlist (`modules/nixos/services/fleet-deploy.nix`, `siblingLockdown`
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
`hostConfig.sudoPasswordless`**:

```nix
extraRules = lib.optionals (hostConfig.sudoPasswordless or false) [ … ];
```

- On a host where `abl030` already has passwordless root (doc1; igpu *before*
  the lock) the GTFOBins change nothing — root is root.
- On a **locked** sibling the block is empty, so `sudo strace …` etc. **prompt
  for a password** → not a bypass. Diagnose via the read-only allowlist (§3) +
  Loki, or escalate to the Proxmox console (§5).

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

| Host | `sudoPasswordless` | Posture | Local break-glass |
|---|---|---|---|
| **doc1** (proxmox-vm) | `true` | **Bastion** — keep passwordless root (already the crown jewel; holds fleet/deploy/bot/MCP creds). `fleetDeploy.bastion`. | n/a (it *is* root) |
| **doc2** | `false` | **Locked.** No password (`!`). `acceptTrigger` + `siblingLockdown`. | Proxmox console only |
| **igpu** | `false` | **Locked.** `acceptTrigger` + `siblingLockdown`. | Interactive sudo (has a password) → Proxmox console |
| **epimetheus** | unset → password-required | Workstation, interactive sudo. | (at the keyboard) |
| **framework** | unset → password-required | Workstation. **Open item:** still carries a passwordless `nixos-rebuild` grant in its own config — a partial standing-root surface not yet folded into this model. | (at the keyboard) |
| **wsl** | `true` | Special: dev box, ephemeral WSL2 VM, no fleet key. Passwordless sudo retained (low-value, behind the Windows host). | Windows-side |
| **hermes** | `true` | Special: locked-down agent VM, keyless re: the fleet, reached via Telegram. Passwordless sudo for its own `fleet-update`/`nixos-rebuild` deploy. See [hermes-agent](../services/hermes-agent.md). | Proxmox console |

**Open item (framework):** `sudoPasswordless` is unset (so sudo *is*
password-gated), but `hosts/framework/configuration.nix` still grants a
passwordless `nixos-rebuild`, which is passwordless root by another name. Folding
framework into the `fleet-deploy` trigger model (or at least removing that grant)
is the remaining lockdown gap. It is a workstation, not an always-on sibling, so
it ranks below doc2/igpu — but it is the next item, not a "won't do".

## 7. How to deploy now

From **doc1** (the only host with the trigger key):

```sh
fleet-deploy doc2     # kick doc2's verified rebuild
fleet-deploy igpu     # kick igpu's verified rebuild
```

No `sudo` runs on the target; the SSH connection *is* the success. The wrapper
uses the doc1-scoped sops deploy key with `IdentitiesOnly` / `BatchMode`.

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

- When framework's passwordless `nixos-rebuild` grant is removed or folded into
  the trigger model (the §6 open item).
- When [#241](https://github.com/abl030/nixosconfig/issues/241) (step-ca /
  short-lived certs) lands — the deploy trigger may move under a CA-signed
  ephemeral-cert model rather than a static forced-command key.
- If a future locked sibling needs a diag tool that isn't a GTFOBin and isn't in
  the §3 allowlist, add it to the `siblingLockdown` allowlist (read-only,
  no-shell-escape only) — never re-enable the §4 GTFOBin block on a locked host.
