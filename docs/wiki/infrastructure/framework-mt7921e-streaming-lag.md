# Framework → Apollo streaming lag (mt7921e) — investigation + real-time capture kit

- **Date:** 2026-06-26, updated **2026-06-28** · **Status:** **STILL OPEN / UNSOLVED — but narrowed by a
  live dual-side capture (2026-06-28).** No working fix has been tested yet; the stream still lags. What
  the capture *did* establish: the lag reproduces with **`l1_aspm=0` the whole time** (so the ASPM fix is
  **not** the cure), the **server/encoder and the AP/channel are clean**, and the failure shows up as a
  **degraded AP→framework downlink** (rate-control dropped to ~48 Mbps + 12% retries while signal is −37/−39
  dBm). **Leading hypothesis:** mt7921e downlink/RX-path degradation under sustained load. This is still a
  hypothesis — it has NOT been confirmed by fixing it. See **[2026-06-28 capture findings](#2026-06-28-live-capture-findings--narrows-the-search-not-yet-solved)** below.
- **Host:** `framework` (Framework 13, NixOS) · WiFi = **MediaTek MT7922** (`mt7921e`, PCI `0000:01:00.0`).
- **Stream:** Moonlight on framework → Apollo on the gaming VM `120 apollo-007-first-light` (`.111`), LAN, direct over WiFi (not Tailscale-relayed).

## Symptom

Streaming a game from the VM to framework: smooth for a while, then **intermittently lags**. The
*reliable* workaround the user found is **exit Moonlight (Ctrl+Alt+Shift+Q) and re-enter** — the stream
is then perfect again, every time. **It does NOT auto-recover** if left lagging. Separately, earlier in
the day a full **WiFi driver reload** (`sudo modprobe -r mt7921e && sudo modprobe mt7921e`) also cleared
a degraded state.

Two different "resets" both work, which is the central puzzle (see Hypotheses).

## What we measured (2026-06-26)

- During one degradation, **ping framework→gateway was 25–175 ms** (avg ~78, jitter ~60, 0% loss) — i.e.
  a **WiFi-level** latency problem at that moment. Every wired host was <0.2 ms. RF was pristine
  (UniFi: -44 dBm, SNR 62 dB, 1.9% retries, 2% channel util — so **not** signal/congestion).
- `iw … power_save` = **off** (already disabled; `hibernate-fix.nix` also blocks deep WiFi PCIe states).
- **`l1_aspm = 1`** on the card's PCIe link **despite `mt7921e.disable_aspm=1`** — that param is
  driver-side only and doesn't clear link-level ASPM L1, which **resume re-enables**.
- The `mt7921e` re-inits ("disabling ASPM L1" + firmware reload) line up **exactly with suspend/resume**
  (s2idle), driven by the existing `wifi-hibernate-fix` module unload/reload.
- `page_pool_release_retry() stalled pool shutdown` logs every 60 s for ~22 h — a **separate, benign**
  mt76 buffer-leak on the suspend module-unload. Log spam only; not the streaming-killer.
- Moonlight's log during the lag was full of **`Invalidate reference frame request sent`** — i.e. it's
  losing/corrupting frames and asking the host for fresh I-frames, and losing that battle.
- Moonlight config: `bitrate=51500` (51.5 Mbps), 60 fps, 1080p, `framepacing=false`, vsync on,
  `packetsize=0` (auto). Nothing pathological.

## Two hypotheses (original framing — see [2026-06-28 capture findings](#2026-06-28-live-capture-findings--narrows-the-search-not-yet-solved) for what's since been ruled in/out)

**(A) WiFi-level — ASPM L1 / mt7921e firmware degradation.** PCIe ASPM L1 stays on; repeated L1
entry/exit during the bursty stream slowly wedges the MT7922 firmware → latency spikes → UDP frames
arrive late/lost → Moonlight frame corruption → lag. Supports: the 25–175 ms ping, `l1_aspm=1`, the
driver-reload fix. This is the well-documented mt7921 ASPM trap (Arch bbs 287846, Ubuntu LP#1955882,
morrownr/USB-WiFi #501).

**(B) Stream-level — the Moonlight↔Apollo flow.** The decode/network pipeline accumulates packet loss
and never self-recovers; restarting the **client** (Ctrl+Alt+Shift+Q) resets the decoder + UDP session.
Supports: a *client-app* restart can't un-wedge the card's firmware, yet it fixes it every time. The
WiFi spikes may be the *source* of the loss while Moonlight's non-recovery is *why a restart is needed*.

They are not mutually exclusive — most likely the WiFi spikes (A) cause the loss, and Moonlight's
pipeline (B) fails to recover from it.

## 2026-06-28 live capture findings — narrows the search, NOT yet solved

⚠️ **Nothing here is a fix.** We ran the dual-side capture kit during a real lag and pulled the AP's view
from UniFi. The data **rules several things out** and points at a leading suspect, but **no fix has been
tested** — the stream was still lagging when we stopped. Treat the conclusion as a *hypothesis to test*,
not a solved root cause.

**Setup:** Moonlight on framework ← Apollo on VM 120 (`.111`), ~51.5 Mbps / 1080p60, l1_aspm forced 0.
Kernel **7.1.1**, MT7922 firmware **1.1** (both current — not a stale-driver case). AP = "Living Room"
UAP-AC-Pro, **channel 149** (5745 MHz, 80 MHz, non-DFS UNII-3).

**What the two loggers showed (aligned by `HH:MM:SS`), over ~7.5 min:**

| Side | Reading during the lag |
| --- | --- |
| **VM (server) tx** | **steady, avg 5,529 KB/s** (max 6,101), GPU ~60%, NVENC 6%, temp 64 °C, **throttle `0x0`** |
| framework `gw_ms` (→AP) | **21% of samples = LOSS**, spikes to 74 ms (idle baseline ~7 ms, 0% loss) |
| framework `vm_ms` (→VM) | 13% LOSS, spikes to 36 ms |
| framework `rxKBs` | erratic — collapses to ~1,300 then bursts to ~13,100 (delayed / catch-up) |
| framework `lost` | **avg 29 Moonlight "Invalidate reference frame"/s** |
| framework `txRetry` | climbing ~6/s (3,133 → 4,804 over a minute) |
| framework `txMbps` (PHY) | swinging 866 → 433 → **173** |
| framework `l1_aspm` | **`0` the entire time** |
| framework signal | −37 dBm (−41…−39), excellent, beacon loss 0 |

**What UniFi (the AP's view) added — the decisive half:**

- AP is **healthy and near-idle**: 22 dBm TX, **11% airtime**, 3 clients, CPU 12%, 21-day uptime, no DFS
  events, channel unchanged.
- AP **hears framework's *uplink* perfectly**: −39 dBm, **866.7 Mbps uplink, the best client on the radio.**
  → framework's transmit side is fine; the client's reported **`txpower 3 dBm` is a cosmetic mt7921e driver
  artifact**, not a real cap (AU/ch149 allows 36 dBm).
- **The damage is on the *downlink* (AP→framework): only 48 Mbps with 12.1% TX retries** — the AP's
  rate-control has bailed out of VHT to a legacy rate **for framework only**. At −39 dBm it should be 866.
- **The other two clients on the same AP/channel are clean** (0–0.6% retries, 866 Mbps) → not the channel,
  not the AP, not airtime. framework-specific.

**What this rules OUT (well-supported):**
- **The old ASPM theory as the cure** — lag reproduces with `l1_aspm=0` throughout. The 9633d46a fix holds
  but does **not** prevent the lag. (Note: the original `l1_aspm=1` measurement on 2026-06-26 is no longer
  reproducible to test, since the fix now forces it 0.)
- **The server / encoder (old Hypothesis B's server angle)** — VM tx is rock-steady, GPU/NVENC fine, no
  throttle. Apollo sent a clean ~44 Mbps the whole time.
- **AP, channel 149, airtime, signal strength, and framework's uplink** — all measured clean.

**Leading hypothesis (still UNPROVEN):** the **mt7921e RX/downlink path degrades under sustained
high-throughput load** — framework fails to reliably ACK high-VHT-rate downlink frames, the AP retries
(12%) and rate-adapts down to 48 Mbps legacy, the ~44 Mbps stream no longer fits → frame loss → lag. The
gateway-ping loss is the AP dropping frames to framework after exhausting retries. This is *consistent*
with the two known resets (driver reload re-inits the NIC; a Moonlight restart drops the sustained load so
the link starts clean) — but **"consistent with" is not "confirmed."**

**To actually confirm/refute it (next session — none done yet):**
1. **A/B the bitrate.** Drop Moonlight to ~30 Mbps (or 20). If the downlink stops collapsing and the lag
   goes away, the load-induced-rate-collapse story holds and we have a usable workaround. If it still
   lags at 30 Mbps, the "sustained load" framing is wrong.
2. **Driver reload mid-lag** (`sudo modprobe -r mt7921e && sudo modprobe mt7921e`) *without* restarting
   Moonlight, and watch the AP downlink rate + `gw_ms` recover. Confirms it's the NIC/driver, not Moonlight.
3. **Different NIC / band.** Try a USB WiFi dongle (different chipset) or force 2.4 GHz / a different 5 GHz
   channel for one session — if a different radio path is stable under the same stream, it isolates to the
   mt7921e.
4. **mt76 debugfs under root** (`/sys/kernel/debug/ieee80211/phy0/mt76/`) during a lag — fw/queue/AMSDU
   stats may show the wedge directly (we couldn't read it non-root).
5. Search mt76 upstream for a load-induced RX rate-control / AMPDU-AMSDU bug on MT7922 at kernel ≥7.1.

**Raw capture saved:** `~/framework-streamlag-capture-20260628.log` on doc1 (framework side); VM side was
`C:\stream-vm.log` on VM 120.

## Fix already applied (validate it)

Commit **9633d46a** — `hibernate-fix.nix` now **forces `l1_aspm=0` (+ `clkpm=0`) on the mt7921e at boot
and on every resume** (the existing suspend reload re-triggers it). Targeted to the card, so other
devices keep ASPM/battery. **Deploy framework** (`sudo nixos-rebuild switch --flake .#framework`) to
make it permanent; runtime now: `sudo sh -c 'for d in /sys/bus/pci/drivers/mt7921e/0000:*; do echo 0 >
"$d/link/l1_aspm"; echo 0 > "$d/link/clkpm"; done'`. **Open question (now ANSWERED, 2026-06-28):** the lag
**still happens with `l1_aspm` confirmed `0` throughout** — so the ASPM fix is **not** the cure. Keep it
(it's cheap, targeted, and closes a real PCIe-ASPM trap that could still bite on resume), but stop treating
it as the streaming-lag fix. The cause is downstream — the mt7921e RX/downlink path, not PCIe ASPM. See the
[2026-06-28 capture findings](#2026-06-28-live-capture-findings--narrows-the-search-not-yet-solved).

## The decisive test (do this the instant it lags, BEFORE Ctrl+Alt+Shift+Q)

`ping 192.168.1.1` (gateway) **and `ping 192.168.1.111` (the VM)** from framework. **Bad ping →
WiFi-level (A).  Fine ping → stream-level (B)** and the ASPM fix won't help. Then restart and watch
whether the ping recovers with it. (As of 2026-06-28 `.111` answers ICMP — see the kit note below — so
`vm_ms` measures the *full* stream path framework→AP→prom→VM, a sharper signal than the gateway hop.)

## Real-time capture kit (durable dual-side logging)

> **Update 2026-06-28 — kit validated end-to-end and pre-staged.** Both loggers now live as ready-to-run
> files: **`~/stream-log.sh` on framework** and **`C:\stream-log.ps1` on the VM** (run the PS one from an
> **admin** PowerShell). Every column was confirmed to populate with sane idle values. Two infra fixes
> were needed and are now in place:
> - **`iw` is now in framework's `systemPackages`** (commit `d632e241`) — it shipped without `iw`
>   (NetworkManager-managed), so the old logger logged blanks for `tx retries`/`signal`. The staged
>   script prefers the system `iw` and falls back to a one-time `nix build nixpkgs#iw` if the box hasn't
>   been rebuilt yet. **Rebuild framework** to make `iw` native.
> - **`.111` now answers ICMP** so `vm_ms` works: a scoped `IN ACCEPT -p icmp` (LAN/tailnet source) in
>   `/etc/pve/firewall/120.fw` **plus** a Windows-firewall inbound ICMPv4-echo allow on the VM. (The VM
>   was firewalled silent before; `vm_ms` used to be a dead `LOSS` column.)

Plan: start both loggers → game → **stop the loggers DURING a lag** (don't restart Moonlight until after
you've stopped logging). The **tail of both logs is the smoking gun**; timestamps (`HH:MM:SS`) line up
between the two sides. Also flip on Moonlight's **performance overlay** (Settings → "Show performance
stats while streaming", or **Ctrl+Alt+Shift+S** mid-stream) and eyeball which metric spikes
(network-latency/packet-loss → link; decode-time → client GPU).

### Side 1 — framework (Linux). Pre-staged at `~/stream-log.sh` (already `chmod +x`). Run it, Ctrl+C during a lag.

This is the validated version (2026-06-28): hardens `PATH` for non-login shells, prefers the system `iw`
(falls back to a one-time `nix build nixpkgs#iw`, whose multi-output result needs the `/bin/iw` one
picked), pings both the gateway **and** `.111`, and adds `txMbps` (PHY bitrate — a collapse is a strong
Hypothesis-A tell).

```bash
#!/usr/bin/env bash
# framework streaming-lag logger. Run during a session; Ctrl+C while it's LAGGING.
# Columns: ts gw_ms vm_ms txRetry(cumul) sig(dBm) txMbps l1 rxKB/s lost/s
set -u
export PATH="/run/wrappers/bin:/run/current-system/sw/bin:$HOME/.nix-profile/bin:$PATH"
DEV=wlp1s0; PCI=0000:01:00.0; GW=192.168.1.1; VM=192.168.1.111
IW="$(command -v iw 2>/dev/null)"
if [ -z "$IW" ]; then            # framework not rebuilt yet → fetch iw from the cache once
  for p in $(nix build --no-link --print-out-paths nixpkgs#iw 2>/dev/null); do
    [ -x "$p/bin/iw" ] && IW="$p/bin/iw" && break   # nix emits iw + iw-man; take the binary one
  done
fi
[ -x "$IW" ] || { echo "FATAL: no iw (PATH or nix)"; exit 1; }
LOG="$HOME/stream-fra-$(date +%Y%m%d-%H%M%S).log"
echo "logging -> $LOG  (Ctrl+C DURING a lag)   iw=$IW"
printf '%-12s %7s %7s %9s %5s %8s %3s %7s %5s\n' ts gw_ms vm_ms txRetry sig txMbps l1 rxKBs lost | tee -a "$LOG"
prx=$(cat /sys/class/net/$DEV/statistics/rx_bytes)
while true; do
  ts=$(date +%H:%M:%S.%2N)
  gw=$(ping -nc1 -W1 "$GW" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); gw=${gw:-LOSS}
  vm=$(ping -nc1 -W1 "$VM" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p'); vm=${vm:-LOSS}
  d=$("$IW" dev $DEV station dump 2>/dev/null)
  rt=$(printf '%s' "$d" | sed -n 's/.*tx retries:[[:space:]]*//p' | head -1)
  sg=$(printf '%s' "$d" | sed -n 's/.*signal:[[:space:]]*\(-[0-9]*\).*/\1/p' | head -1)
  bw=$(printf '%s' "$d" | sed -n 's/.*tx bitrate:[[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
  l1=$(cat /sys/bus/pci/devices/$PCI/link/l1_aspm 2>/dev/null)
  rx=$(cat /sys/class/net/$DEV/statistics/rx_bytes); rxk=$(( (rx-prx)/1024 )); prx=$rx
  lost=$(journalctl --since '1 second ago' --no-pager -q 2>/dev/null | grep -ci 'Invalidate reference frame')
  printf '%-12s %7s %7s %9s %5s %8s %3s %7s %5s\n' "$ts" "$gw" "$vm" "${rt:-?}" "${sg:-?}" "${bw:-?}" "${l1:-?}" "$rxk" "$lost" | tee -a "$LOG"
  sleep 1
done
```

What the tail tells you:
- **`gw_ms`/`vm_ms` spike** (→100+ ms) → it's the WiFi link (Hypothesis A). Confirm `l1` stayed `0`.
- **`txRetry` jumping fast** between rows → WiFi retransmits (RF/driver). (It's cumulative; watch the rate.)
- **`txMbps` collapses** (idle baseline ~866) → PHY-rate degradation (RF/driver), supports Hypothesis A.
- **`rxKBs` collapses** (stream was ~6 MB/s = ~6000 KB/s at 51.5 Mbps) → the stream stopped arriving.
- **`lost`/s climbs** while `gw_ms`/`vm_ms` are *fine* → loss isn't WiFi latency; look server-side (B).
- **`l1` flips to `1`** → the ASPM fix didn't hold across a resume; that's the bug, re-apply.

### Side 2 — the gaming VM (Windows/PowerShell). Pre-staged at `C:\stream-log.ps1`. Run in an **admin** PowerShell; Ctrl+C during a lag.

Validated 2026-06-28 (idle row: `gpu/enc/temp/thr=0%,0%,42,0x..01 | tx=0 rx=0 KB/s`). Uses `Tee-Object`
so rows print live **and** append to `C:\stream-vm.log`.

```powershell
# Gaming-VM streaming-lag logger. Run in an ADMIN PowerShell during a session; Ctrl+C while it's LAGGING.
$log='C:\stream-vm.log'; $smi="$env:windir\System32\nvidia-smi.exe"
$alog='C:\Program Files\Apollo\config\sunshine.log'
"=== start $(Get-Date -f 'yyyy-MM-dd HH:mm:ss') ===" | Tee-Object $log -Append
$apos = if(Test-Path $alog){(Get-Item $alog).Length}else{0}
$n=Get-NetAdapterStatistics|Sort-Object ReceivedBytes -Desc|Select -First 1; $ptx=$n.SentBytes; $prx=$n.ReceivedBytes
while($true){
  $ts=Get-Date -f 'HH:mm:ss.ff'
  $g=(& $smi --query-gpu=utilization.gpu,utilization.encoder,temperature.gpu,clocks_throttle_reasons.active --format=csv,noheader 2>$null) -replace '\s+',''
  $n=Get-NetAdapterStatistics|Sort-Object ReceivedBytes -Desc|Select -First 1
  $txk=[math]::Round(($n.SentBytes-$ptx)/1KB,0); $rxk=[math]::Round(($n.ReceivedBytes-$prx)/1KB,0); $ptx=$n.SentBytes; $prx=$n.ReceivedBytes
  $anew=''
  if(Test-Path $alog){ $len=(Get-Item $alog).Length
    if($len -gt $apos){ $fs=[IO.File]::Open($alog,'Open','Read','ReadWrite'); [void]$fs.Seek($apos,'Begin'); $sr=New-Object IO.StreamReader($fs)
      $anew=(($sr.ReadToEnd() -split "`n") | Where-Object {$_ -match 'frame|loss|drop|nack|FEC|bitrate|slow|retransmit|CONNECT'} | Select -Last 2) -join ' || '
      $sr.Close(); $fs.Close(); $apos=$len } }
  "$ts | gpu/enc/temp/thr=$g | tx=$txk KB/s rx=$rxk KB/s | $anew" | Tee-Object $log -Append
  Start-Sleep 1
}
```

What the tail tells you:
- **`enc`% high / `temp` ok / `thr` = `0x...01`** → the GTX 1080 NVENC is fine; not the server GPU.
- **`tx KB/s` steady ~6000** while framework's `rxKBs` collapsed → the VM *sent* it; loss is in the
  **air/WiFi** (Hypothesis A).
- **`tx KB/s` itself drops / Apollo logs `slow`/`nack`/loss** → the server/encoder reacted (the client
  asked for re-sends, or Apollo throttled) — points server/flow-side (Hypothesis B).
- For richer Apollo data, optionally set `min_log_level=debug` in `sunshine.conf` for the test session
  (Stop-Service ApolloService, edit, Start) and revert after — it logs per-frame network stats at debug.

## How to read the smoking gun

Open both `*.log` tails at the moment you stopped (the lag). Line them up by `HH:MM:SS`:
- **framework `gw_ms` high + VM `tx KB/s` steady** → the VM sent fine, the WiFi ate it → **link (A)**,
  ASPM/firmware. Driver reload fixes it; the `l1_aspm=0` fix should prevent it.
- **framework `gw_ms` fine + `lost`/s high + VM tx fine** → the loss is in the **flow (B)**; the ASPM
  fix is irrelevant — try lower bitrate / frame pacing / packetsize, or a Moonlight/Apollo update.
- **VM `tx KB/s` drops or `thr` ≠ idle** → the **server** stalled (encoder/GPU/CPU), look there.

## Cheap A/B knobs to try next session

- **Enable Moonlight frame pacing** (`framepacing=true`).
- **Drop bitrate to ~30 Mbps** — if 30 survives where 51.5 didn't, it's WiFi-capacity/bufferbloat.
- Confirm `cat /sys/bus/pci/devices/0000:01:00.0/link/l1_aspm` stays `0` throughout.

## References

- Fix commit: `9633d46a` (`hibernate-fix.nix` ASPM-L1 off).
- mt7921 ASPM latency: <https://bbs.archlinux.org/viewtopic.php?id=287846> ·
  <https://bugs.launchpad.net/bugs/1955882> · <https://github.com/morrownr/USB-WiFi/issues/501>
- Related: `hosts/framework/README.md`, `modules/nixos/services/framework/hibernate-fix.nix`,
  `framework-lid-suspend-gsd-power.md`.
