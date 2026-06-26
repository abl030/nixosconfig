---
name: servarr-nfs-static-and-sudo
description: servarr's /media/data must be a STATIC NFS mount (never automount) or qbt torrents ESTALE; abl030 now has passwordless sudo on servarr
metadata:
  type: project
---

Two settled facts about **servarr** (the *arr VM on tower; qbt microVM cage), landed 2026-06-26
after the "Curb Your Enthusiasm 47 GB pack kept erroring" incident.

**1. `/media/data` MUST be a static NFS mount — NEVER `x-systemd.automount`.** It backs the qbt
`/downloads` virtiofs share, and virtiofsd holds open handles into it for the VM's life. An
automount lazily remounts underneath virtiofsd → cached handles go stale → guest sees
`file_open: Stale file handle` (ESTALE) → qBittorrent **errors the whole torrent** (pause/resume
in the WebUI doesn't help — virtiofsd still holds the dead handle). The box had hand-rolled an
inline `fileSystems."/media/data"` with the laptop automount pattern. Fixed by folding it onto the
shared **server** module `homelab.mounts.nfsLocal` (the same one doc2 uses for this export):
`mountPoint="/media/data"; appdata=false; networkdWaitOnline=false` → static + `hard` + `softreval`.
**Never re-introduce automount on a server that re-shares an NFS mount over virtiofs.** Recovery if
it recurs: `sudo systemctl restart microvm@qbt.service` (resume state survives in `qbt-state.img`);
a `homelab.nfsWatchdog.qbt` automates it. The roaming/laptop pattern (automount + idle-timeout) is
the *other* module, `nfs.nix` (framework/epi). Full writeup:
`docs/wiki/services/servarr-and-qbt-cage.md` (the "host NFS mount MUST be static" gotcha).

**2. abl030 now has PASSWORDLESS sudo on servarr** (hermes-style `security.sudo.extraRules` mkAfter
NOPASSWD ALL). So unlike the other locked siblings, **`ssh servarr "sudo ..."` from doc1 WORKS** —
the agent can restart the qbt microVM / manage the box without a password prompt. This is a
deliberate exception to the "nothing passwordless but doc1" rule (servarr is firewall-caged and
bastion-key-only). Relates to [[ssh-bastion-model]] / [[fleet-deploy-and-sibling-lockdown]].
Note servarr deploys are still special: built on doc1 + closure pushed (it OOMs on local rebuild,
`update.enable=false`), NOT `fleet-deploy servarr`.
