#!/usr/bin/env bash
# prom (hand-managed Proxmox): recover NFS mounts that missed boot, and the
# guests whose start was cancelled because of them.
#
# Installed by hand as /usr/local/sbin/nfs-recover with nfs-recover.service and
# nfs-recover.timer from this directory. prom is not a flake host; see
# docs/wiki/infrastructure/tower-boot-race.md for why this exists and how to
# install or remove it. The NixOS fleet equivalent is
# modules/nixos/services/mounts/tower-nfs-recover.nix.
set -euo pipefail

tower=192.168.1.2
maxAttempts=3
state=/run/nfs-recover
mkdir -p "$state"

# unit  readiness-probe  probe-argument
# tower: the export must be listed (its NFS server answers with an empty list
# while the Unraid array is still starting). kerrynas: mountd isn't reachable
# over the tailnet, so a TCP check of 2049 is the best cheap probe.
mounts=(
  "mnt-tower\\x2ddata.mount showmount /mnt/user/data"
  "mnt-tower\\x2dscans.mount showmount /mnt/user/data"
  "mnt-tower\\x2dmagazines.mount showmount /mnt/user/magazines"
  "mnt-tower\\x2dvmbackups.mount showmount /mnt/user/VMBackups"
  "mnt-mum\\x2dct.mount tcp kerrynas-tailnet:2049"
)

towerExports=$(timeout 20 showmount -e --no-headers "$tower" 2>/dev/null | awk '{print $1}' || true)

for entry in "${mounts[@]}"; do
  read -r unit probe arg <<<"$entry"
  systemctl is-active --quiet "$unit" && continue
  case "$probe" in
    showmount) grep -qxF "$arg" <<<"$towerExports" || continue ;;
    tcp) timeout 5 bash -c "</dev/tcp/${arg%:*}/${arg#*:}" 2>/dev/null || continue ;;
  esac
  echo "$unit is down but its server is ready; starting it"
  systemctl reset-failed "$unit" 2>/dev/null || true
  systemctl start "$unit" || echo "starting $unit failed" >&2
done

# Start any service whose LAST job this boot was cancelled by a failed
# dependency (e.g. pve-container@111 behind mnt-mum-ct.mount). A later manual
# stop makes the last job 'done', so it is left alone. Bounded per boot so an
# unrelated broken dependency can't loop.
journalctl -b -o json JOB_RESULT=dependency --output-fields=UNIT \
  | jq -r '.UNIT // empty' | sort -u \
  | while read -r u; do
    case "$u" in *.service) ;; *) continue ;; esac
    [ "$(systemctl show -p ActiveState --value "$u")" = inactive ] || continue
    last=$(journalctl -b -o json UNIT="$u" --output-fields=JOB_RESULT \
      | jq -rs 'map(select(.JOB_RESULT)) | last | .JOB_RESULT // empty')
    [ "$last" = dependency ] || continue
    f="$state/$(systemd-escape "$u")"
    n=$(cat "$f" 2>/dev/null || echo 0)
    if [ "$n" -ge "$maxAttempts" ]; then
      echo "$u: still cancelled after $maxAttempts recovery attempts; leaving it" >&2
      continue
    fi
    echo $((n + 1)) >"$f"
    echo "starting $u (its start was cancelled by a failed dependency this boot)"
    systemctl start --no-block "$u"
  done
