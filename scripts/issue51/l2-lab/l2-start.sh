#!/usr/bin/env bash
RUNNER="$1"
systemctl stop l2-virtiofsd l2-guest 2>/dev/null
for p in $(ps -eo pid,args --no-headers | grep -E 'cloud-hypervisor|virtiofsd|supervisord' | grep -v grep | awk '{print $1}'); do
  [ "$p" = "$$" ] && continue
  kill -9 "$p" 2>/dev/null
done
sleep 3
rm -f /tmp/l2guest-virtiofs-*.sock /tmp/l2guest.sock
rm -rf /mnt/virtiofs/l2-scratch
mkdir -p /mnt/virtiofs/l2-scratch
systemd-run --unit=l2-virtiofsd --working-directory=/tmp --collect --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
  "$RUNNER/bin/virtiofsd-run" >/dev/null 2>&1
sleep 6
echo "sockets: $(ls /tmp/l2guest-virtiofs-*.sock 2>/dev/null | wc -l)  listeners: $(ss -xl 2>/dev/null | grep -c l2guest-virtiofs)"
systemd-run --unit=l2-guest --working-directory=/tmp --collect --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
  "$RUNNER/bin/microvm-run" >/dev/null 2>&1
sleep 40
echo "=== guest unit: $(systemctl is-active l2-guest) ==="
journalctl -u l2-guest --no-pager 2>/dev/null | grep -a 'L2H' | tail -8
echo "=== sync ==="; ls /mnt/virtiofs/l2-scratch/_sync/ 2>&1
