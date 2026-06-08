# SSH bastion model — doc1 as the sole fleet-key holder

**Status:** live (shipped via [#270](https://github.com/abl030/nixosconfig/issues/270), 2026-06-08). No-infra interim ahead of the full CA architecture in [#241](https://github.com/abl030/nixosconfig/issues/241).
**Researched/written:** 2026-06-08 (during the #270 work + its ce-code-review pass).

## The problem it solves

Before #270, every host deployed the **same** fleet SSH private key
(`ssh_key_abl030`) to `~/.ssh/id_ed25519` and authorized it. Pop **any** host →
read that file → it *is* the fleet skeleton key → SSH to every other host. One
compromised host = the whole fleet. sshd also honored hand-edited
`~/.ssh/authorized_keys` files holding stray/unknown keys outside `hosts.nix`.

## The model

- **doc1 (proxmox-vm) is the bastion** — the ONLY host that holds the fleet
  identity private key (`homelab.ssh.deployIdentity = true`; the module default
  is now **false**, enforced by `bastionInvariantCheck` in `flake.nix`).
- **Every sibling is keyless.** It trusts only `fleetKeys = [fleetIdentity]`
  inbound (so doc1 can reach it) but holds no fleet key, so a popped sibling
  can't move laterally. Verified: `sibling → other-sibling` = Permission denied.
- **Entry to doc1** = per-device **passphrase** keys (`bastionDeviceKeys`:
  epi/framework/wsl) + the phone, each `from="100.64.0.0/10,192.168.1.0/24"`
  pinned (tailnet + home LAN only), with `ssh.secure = true` (no password auth,
  no root login). The passphrase is the real gate; `from=` bounds where it can
  be presented.
- **Authorization is 100% declarative.** `authorizedKeysInHomedir = false` →
  sshd reads ONLY `/etc/ssh/authorized_keys.d/%u` rendered from `hosts.nix`. The
  hand-edited `~/.ssh/authorized_keys` surface is closed (an audit found stray
  unknown keys even on the bastion itself).
- **Access pattern = stepping-stone.** Land on doc1 with `~/.ssh/id_doc1`
  (`ssh -i ~/.ssh/id_doc1 doc1`), then reach siblings *from* doc1 using its
  resident fleet key. ProxyJump does NOT work here (siblings don't trust your
  device keys, so `ssh -J doc1 sibling` is rejected at the sibling) — you hop.
- **Claude/agents run on doc1**, so the autonomous deploy path (#241's
  load-bearing constraint) is unchanged: Claude-on-doc1 → keyless siblings.

## Key files

| File | Role |
|---|---|
| `hosts.nix` (`let` block) | `fleetIdentity`, `fleetKeys`, `bastionDeviceKeys`, `phoneKey`, `bastionFrom`, `bastionKeys` |
| `modules/nixos/services/ssh/default.nix` | `deployIdentity` (default false), `authorizedKeysInHomedir=false`, `purgeFleetKeyOnKeylessHost` activation script, github knownHosts pin |
| `hosts/proxmox-vm/configuration.nix` | the one `deployIdentity = true` + `ssh.secure = true` |
| `flake.nix` | `bastionInvariantCheck` — build fails unless exactly one `deployIdentity = true` |

## Private flake inputs (the keyless enabler)

The only `git+ssh://` input (`vinsight-mcp`) was the sole reason every host
needed an SSH key. #270 re-pointed it to `github:` so it fetches via the
read-only `nix-netrc` PAT (with `cellar-manager`). See
[github-pat-and-private-inputs.md](./github-pat-and-private-inputs.md).
**Trade-off:** a dead PAT fails eval of the two private inputs fleet-wide — use
a **no-expiry**, Contents:read, 2-repo fine-grained token.

## Gotchas / operational notes

- **Break-glass:** Proxmox console on prom (console login is unaffected by
  `secure=true`). If you lose all `bastionKeys`, that's the only way back in.
- **Lateral service hops need a dedicated key.** A keyless host can't SSH to a
  sibling with the fleet key any more. `gwm-archiver` on doc2 (which triggers
  `marker-convert` on epi) hit this — fixed with a dedicated, **forced-command**
  key (`secrets/hosts/doc2/gwm-trigger-key`, locked to `systemctl start
  marker-convert.service` in `marker-convert.nix`). Copy this pattern for any
  future keyless-host → sibling automation. `syncoid-pfsense` is the other
  example.
- **`purgeFleetKeyOnKeylessHost`** removes `/root/.ssh/id_ed25519` (real copy
  from the old mirror) + the dangling `~/.ssh/id_ed25519` sops symlink husk on
  every keyless switch. Only removes a *broken* user symlink, never a real key.
- **caddy is HM-only** — outside the NixOS sshd domain, so `authorizedKeysInHomedir`
  doesn't apply; its key surface is managed separately.
- **wsl** reaches doc1 via the Windows host's *tailnet* IP (100.x), so the
  `from=` belt admits it even though wsl physically sits on 192.168.100.x
  (Cullen) — always connect via tailscale from Cullen.

## When to revisit

When [#241](https://github.com/abl030/nixosconfig/issues/241) (step-ca /
CA-signed certs / YubiKey broker) lands — this bastion becomes the trust hub
under it, or is replaced by short-lived certs. Open #241 Phase-1 hygiene item
still pending: `forwardAgent = false` default in `modules/home-manager/services/ssh.nix`.
