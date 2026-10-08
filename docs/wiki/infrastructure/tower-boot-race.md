# Tower boot race: services that never come back after a power cut

**Date:** 2026-10-08 · **Status:** mitigated (recovery net + two decouplings
deployed). **Revisit:** if a host's units still sit cancelled after tower
returns, or when new hosts gain static tower mounts.

## What happened

At about 10:15 AWST on 2026-10-08, a house power cut took down pfSense, prom
(and every guest on it), and tower. pfSense and prom came back at about 10:30.
Tower did not power on by itself, so its BIOS needs "Restore on AC power loss"
set to Power On. Wake-on-LAN from both doc1 and pfSense did not wake it. It was
started by hand at 12:19.

The outage itself lasted 15 minutes, and Tailscale was not at fault. The long
tail came from the boot race:

- Tower takes about 6 minutes from power-on to exporting NFS, and most of that
  is the Unraid array start. Its NFS server answers while the array is
  stopped, with an **empty export list**, so a port check is not a readiness
  probe.
- prom, doc1, and doc2 are back in about 3 minutes.
- The static tower mounts (`homelab.mounts.nfsLocal`, static
  `homelab.mounts.magazines`, and prom's `/mnt/tower-*` in its fstab) time out
  once. Every unit with `RequiresMountsFor` on them is then cancelled with
  result `dependency`.
- A cancelled unit is **inactive, not failed**. systemd never retries it.
  `nfs-watchdog.nix` acts only on `is-failed`, so it skips these units too.
  The watchdogs do start the mount again when they restart their own
  service, but nothing restarts the other units.

Even with the BIOS fixed, a whole-house power cut would end the same way.

These units were still down two hours later, until they were started by hand:

- doc2: forgejo, immich, audiobookshelf, paperless (all 4 units), komga,
  syncthing (and syncthing-init), webdav, yoto-library, yoto-webdav,
  booklore, chaptarr, readmeabook, shelfarr, and `container@ali-cratedigger`.
- doc1: nginx (every doc1 site, nix-mirror included), fuse-mergerfs-movies/tv,
  and webhook.
- prom: `pve-container@111` (kopia). That one was blocked by
  `mnt-mum\x2dct.mount`, which comes from kerrynas over the tailnet, not
  tower.
- igpu: tdarr-node. Its bind of prom's empty `/mnt/tower-data` failed, and it
  hit the start limit.

The tailscale-share DNS-sync oneshots on doc2 and igpu also gave up at boot.
They were waiting for their sidecars, which is a separate and harmless race,
and a re-run fixed them.

## Fixes

1. **Recovery net, NixOS:** `modules/nixos/services/mounts/tower-nfs-recover.nix`.
   It is on by default wherever a static tower mount is enabled (doc1, doc2,
   servarr). A timer runs 3 minutes after boot and then every 2 minutes. Each
   run does two things:
   - When `showmount -e 192.168.1.2` lists the export, it starts any tower
     mount that is down.
   - Once every tower mount is active, it starts each **enabled** unit whose
     *last* job this boot ended in `dependency`. A later manual stop makes the
     last job `done`, so that unit is left alone.

   Each unit gets at most 3 attempts per boot. The counts are kept in
   `/run/tower-nfs-recover`.
2. **Recovery net, prom:** `scripts/prom/nfs-recover.{sh,service,timer}`,
   installed by hand. It follows the same logic for the four tower mounts.
   For `mnt-mum\x2dct.mount` it uses a TCP probe of `kerrynas-tailnet:2049`,
   because mountd is unreachable over the tailnet. It considers any service
   unit, since `pve-container@` is a static unit.
3. **Forgejo no longer requires tower.** Only `forgejo-dump` binds the NFS dump
   directory. See `docs/wiki/services/forgejo.md`.
4. **doc1 nginx no longer requires tower.** `podcast.ablz.au` is served by
   `podcast-static.service` (darkhttpd on 127.0.0.1:9010). That service owns
   the `RequiresMountsFor=/mnt/data` and has its own NFS watchdog, and nginx
   proxies to it. With tower down, only the podcast vhost returns 502. nginx
   keeps an ordering-only `After=mnt-data.mount`, so family-archive's optional
   originals bind still sees the mount on a normal boot.

## Install or remove on prom

```sh
scp scripts/prom/nfs-recover.sh root@prom:/usr/local/sbin/nfs-recover
scp scripts/prom/nfs-recover.service scripts/prom/nfs-recover.timer root@prom:/etc/systemd/system/
ssh root@prom 'chmod 0755 /usr/local/sbin/nfs-recover && systemctl daemon-reload && systemctl enable --now nfs-recover.timer'
# remove:
ssh root@prom 'systemctl disable --now nfs-recover.timer && rm /usr/local/sbin/nfs-recover /etc/systemd/system/nfs-recover.{service,timer} && systemctl daemon-reload'
```

## Checking after an outage

```sh
journalctl -u tower-nfs-recover -b        # NixOS hosts
ssh root@prom journalctl -u nfs-recover -b
# Anything cancelled this boot and still not running:
journalctl -b -o json JOB_RESULT=dependency --output-fields=UNIT | jq -r .UNIT | sort -u
```

## Not done

- **A boot-time wait gate.** We considered making the mounts wait for tower,
  but rejected it. With static `_netdev` mounts it holds `remote-fs.target`, and
  so `multi-user.target`, for as long as tower is down. The recovery net gets
  the same result with no boot delay.
- **A UPS.** Short outages would not reach prom, pfSense, or tower at all. This
  is a hardware decision for the owner.
