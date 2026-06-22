# tower (Unraid) — fleet SSH integration

**Date:** 2026-06-22 · **Status:** working · **Host:** tower (Unraid 7.3.0, 192.168.1.2 / 100.103.140.44, `tag:server`)

tower was moved from **Tailscale-SSH-only** onto the **standard doc1-bastion fleet SSH
model**: native OpenSSH, key-only root, reached with the fleet identity from doc1 exactly
like every NixOS sibling. The Tailscale plugin's `--ssh` is **disabled**.

Why: uniformity (the Unraid control agent + `service-debug`/`service-deploy` skills treat
tower like any host) and it let us **revert the ACL ssh-block root widening** (commit
`c6d75b84`, reverted by `27c90f67`). doc1→tower now rides the existing `tag:server` mesh
grant (`ip *`), not a special Tailscale-SSH rule.

## How to reach tower now

From **doc1** (holds the fleet private key at `~abl030/.ssh/id_ed25519` → `/run/secrets/ssh_key_abl030`):

```sh
ssh root@tower        # MagicDNS → 100.103.140.44 → native sshd, fleet key
ssh root@192.168.1.2  # LAN path, same sshd
```

Auth is **pubkey-only** (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`,
`AllowUsers root`). Only the fleet key (`…QQS0K1qy master-fleet-identity`) is authorized.
Siblings can't reach tower directly (keyless); hop via doc1 — same stepping-stone model as
the rest of the fleet (#270).

> Host key changed vs the old Tailscale-SSH path. If you see a host-key mismatch on doc1:
> `ssh-keygen -R tower; ssh-keygen -R 100.103.140.44` then reconnect (accept-new). tower's
> real host key: `SHA256:13sMPfUvmUxqjypOoCqQpNm4hmebt3477SCgt3vNAr4` (ed25519).

## Where it all lives (Unraid is NOT Nix-managed — this is the only record)

Everything persists on the **flash** (`/boot`). `/etc` and `/root` are tmpfs, rebuilt each
boot. `/etc/rc.d/rc.sshd` regenerates `/etc/ssh/sshd_config` at boot, so you cannot just
edit the live config.

| What | Where (flash) | Notes |
|---|---|---|
| Enable sshd | `/boot/config/ident.cfg` → `USE_SSH="yes"` (`PORTSSH="22"`) | rc.sshd reads this at boot |
| Hardened sshd_config | `/boot/config/ssh/sshd_config` | `rc.sshd` does `cp -f /boot/config/ssh/* /etc/ssh/` at SSH start; `sshd_build` only rewrites `Port`/`ListenAddress`, leaving auth settings intact |
| root authorized_keys | `/boot/config/ssh/root/authorized_keys` + restored live by a `/boot/config/go` stanza (marker `FLEET-BASTION-SSH`) | belt-and-suspenders; Unraid's UserEdit mechanism also mirrors `/boot/config/ssh/root/` → `/root/.ssh/` |
| Disable Tailscale SSH | `/boot/config/plugins/tailscale/tailscale.cfg` → `SSH="0"` + live `tailscale set --ssh=false` | both needed: cfg stops the plugin re-enabling at boot; live clears `RunSSH` in the flash statedir |

`BIND_MGT="no"` ⇒ sshd binds all live interfaces (br0 + tailscale1), regenerated each boot —
matches the fleet's bind-all posture; self-heals via `rc.sshd update` when tailscale1 appears.

## Reboot recovery / verification

A reboot is the ultimate test (not done during setup to avoid disrupting the NAS). On boot:
`USE_SSH=yes` → rc.sshd copies flash config + host keys into `/etc/ssh`, builds, starts sshd;
the go stanza restores `authorized_keys`; the plugin honours `SSH="0"`. If locked out after a
reboot, recover from the **Unraid console** (IPMI/physical): re-run the go stanza by hand, or
re-enable Tailscale SSH (`tailscale set --ssh=true`) as a fallback door.

Quick health check from doc1:
```sh
ssh -o PreferredAuthentications=publickey root@tower 'whoami; tailscale debug prefs | grep -i runssh'
# expect: root  /  "RunSSH": false
```

## Rollback (back to Tailscale-SSH-only)

1. On tower: `tailscale set --ssh=true`; set `SSH="1"` in `tailscale.cfg`; `USE_SSH="no"` in
   `ident.cfg`; `/etc/rc.d/rc.sshd stop`.
2. Re-add `"root"` to the `tag:server→tag:server` ssh-block rule in `tailscale/acl.hujson`
   and deploy (see `[[tailscale-acl-state]]` for the gitops-pusher apply path).

## Related

- Fleet SSH bastion model: `docs/wiki/infrastructure/ssh-bastion-model.md` (#270)
- ACL apply/revert: `docs/wiki/infrastructure/tailscale-acl.md`, `.claude/memory/tailscale-acl-state.md`
- The other Unraid node, **downloader2** (100.120.54.133), still uses Tailscale SSH — the
  ssh-block `tag:server→tag:server` nonroot rule remains for it.
