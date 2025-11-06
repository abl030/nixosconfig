#!/usr/bin/env bash
set -e

echo "== Running kernel cmdline =="
cat /proc/cmdline
echo

echo "== nvme_core APST knob (0 = APST off) =="
cat /sys/module/nvme_core/parameters/default_ps_max_latency_us 2>/dev/null || echo "param not present"
echo

echo "== APST feature per controller =="
for d in /dev/nvme[0-9]; do
    [ -e "$d" ] || continue
    echo "--- $d ---"
    nvme get-feature -f 0x0c "$d" 2>/dev/null | sed -n '1,3p'
done
echo

echo "== Runtime PM control per NVMe =="
for p in /sys/class/nvme/nvme*/device/power/control; do
    [ -e "$p" ] || continue
    printf "%s: %s\n" "$p" "$(cat "$p")"
done
echo

echo "== Recent kernel NVMe/PCIe events =="
journalctl -k --no-pager --since "-5 min" | grep -Ei 'nvme|pciehp|pcieport|AER|link.*(up|down)|reset' | tail -n 50 || true
echo

echo "== ZFS quick status =="
zpool status -xvP nvmeprom || true
