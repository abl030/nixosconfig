---
name: moonlight-iperf
description: Measure Wi-Fi/LAN throughput with iperf3 to choose a safe Moonlight/Sunshine streaming bitrate. Use when the user asks to test iperf, size a Moonlight stream, compare Wi-Fi clients, check phone/laptop streaming performance, or diagnose UDP/TCP throughput from an SSH-reachable client such as framework or phone.
---

# Moonlight Iperf

Use this skill to run repeatable iperf3 checks between a known-good wired server and an SSH-reachable client, then translate the result into a practical Moonlight bitrate.

## Quick Start

Prefer the bundled helper:

```sh
.claude/skills/moonlight-iperf/scripts/moonlight-iperf.sh --client <ssh-host>
```

Defaults assume the agent is on doc1/proxmox-vm:
- server IP: `192.168.1.29`
- client reached by SSH
- iperf port: `5201`
- UDP downlink rates: `30M,60M,120M`
- UDP payload/window: `-l 1200 -w 4M`
- temporary doc1 firewall rules scoped to the discovered client LAN IP

Use the actual SSH alias from the current host, e.g. `fra` for Framework from doc1.

For a phone where doc1-as-server cannot be reached, use the fallback:

```sh
.claude/skills/moonlight-iperf/scripts/moonlight-iperf.sh --client phone --remote-server
```

## Workflow

1. Confirm the path is the real LAN/Wi-Fi path, not Tailscale:
   - On server: `ip -brief addr`.
   - On client: `ip route get <server-lan-ip>` and inspect `src`.
   - Prefer `192.168.1.x` client/server addresses for local Moonlight tests.
2. Run the helper with `--client <ssh-host>`.
3. If the helper cannot reach doc1 as an iperf server, retry with `--remote-server`.
4. For Android/Termux clients, keep the display awake if possible and let the script hold a `termux-wake-lock`.
5. Always clean temporary firewall rules and wake locks. The helper installs traps for this; if interrupted badly, rerun cleanup commands from its output or inspect `iptables -S nixos-fw`.

## Interpreting Results

For Moonlight, the important direction is **server to client downlink**:
- TCP downlink: `iperf3 -R`
- UDP downlink: `iperf3 -u -R -b <rate>`

Do not use plain `iperf3 -u` as the Moonlight test; that sends client -> server. Moonlight video is server -> client, so use `-R`.

Use UDP downlink when it works. Pick the highest UDP rate with:
- `0%` loss, or at most tiny isolated loss under real household load
- jitter comfortably below `5 ms`
- stable per-second rates with no long collapses

Recommended Moonlight bitrate:
- If UDP downlink is clean: start at about `70%` of the highest clean UDP rate, capped by what the encoder/client can handle.
- If only TCP is available: use a conservative `40-60%` of single-stream TCP downlink, and treat it as provisional.
- If single-stream TCP downlink is much lower than multi-stream downlink, be conservative. That usually means one flow is fragile under congestion or client power management.

Rules of thumb:
- `30 Mbps`: safe 1080p60 baseline.
- `50-60 Mbps`: good 1080p60 / light 1440p.
- `80-100 Mbps`: high-quality 1440p/4K only when UDP is clean.
- Do not set Moonlight near the headline PHY rate (`866 Mbps`, etc.); it is not application throughput.

## Android / Termux Notes

Read `references/android-termux-udp.md` when testing phones.

Observed Samsung/Termux behavior in this environment:
- TCP iperf works.
- Phone-as-iperf-server can accept TCP control while receiving zero UDP payloads.
- Reverse UDP can show the phone sending datagrams while the Linux receiver gets no UDP on the pinned port.
- `termux-wake-lock` helps with sleep but did not by itself make UDP iperf reliable.

When Android UDP iperf is inconclusive, report it as a measurement limitation, not packet loss. Use TCP plus a real Moonlight session and Sunshine/Moonlight stats to set the final bitrate.

## Manual Commands

Doc1 as server:

```sh
nix shell nixpkgs#iperf -c iperf3 -s -B 192.168.1.29
ssh <client-alias> 'iperf3 -c 192.168.1.29 -t 20'
ssh <client-alias> 'iperf3 -c 192.168.1.29 -R -t 20'
ssh <client-alias> 'iperf3 -c 192.168.1.29 -R -P 4 -t 20'
ssh <client-alias> 'iperf3 -4 -c 192.168.1.29 -u -R -b 60M -l 1200 -w 4M -O 3 -t 60 -i 1 --get-server-output'
```

Remote client as server:

```sh
ssh <client-alias> 'iperf3 -s -B <client-lan-ip>'
nix shell nixpkgs#iperf -c iperf3 -c <client-lan-ip> -t 20
nix shell nixpkgs#iperf -c iperf3 -c <client-lan-ip> -R -t 20
nix shell nixpkgs#iperf -c iperf3 -c <client-lan-ip> -P 4 -t 20
```
