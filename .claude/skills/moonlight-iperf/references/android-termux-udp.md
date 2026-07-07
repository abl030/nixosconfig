# Android / Termux UDP iperf notes

Use this reference when a phone can run TCP iperf but UDP reports are missing, zero, or contradictory.

## Known local observations

Environment: Samsung SM-A556E, Termux `iperf3 3.21`, doc1/proxmox-vm `iperf3 3.21`, LAN server
`192.168.1.29`, phone Wi-Fi `192.168.1.38`.

Observed:
- TCP downlink to phone, single stream: about `80.5 Mbit/s`.
- TCP downlink to phone, four streams: about `406 Mbit/s`.
- TCP uplink from phone: about `466 Mbit/s`, but with high retransmits.
- Phone-as-server UDP downlink: TCP control connected, but phone reported `0` received UDP datagrams.
- Reverse UDP with pinned client port: phone server reported it sent about `20 Mbit/s`, but doc1's nftables
  counter for the pinned UDP receive port stayed at `0`.
- Keeping a Termux wakelock did not make UDP iperf produce a trustworthy end-to-end result.

Interpretation: this is not enough evidence to call Wi-Fi UDP packet loss. Treat it as an Android/Termux
measurement limitation until corroborated by another UDP tool or real Moonlight telemetry.

## External grounding

- `iperf3 -u` still uses a TCP control channel, so control can connect while UDP payloads are missing.
- Moonlight-relevant iperf direction is server -> client: use `iperf3 -u -R`, not plain `-u`.
- Android/Termux is not an officially supported iperf3 platform, though Termux packages current iperf3.
- Android low-latency Wi-Fi behavior depends on foreground/screen-on/Wi-Fi-lock state, and Samsung battery
  features can restrict sleeping or background apps.
- Sunshine/Moonlight use UDP heavily for video/control/audio; raw UDP behavior matters more than bulk TCP.

Sources:
- ESnet iperf invocation docs: https://software.es.net/iperf/invoking.html
- ESnet iperf UDP/control discussion: https://github.com/esnet/iperf/discussions/1559
- Android Wi-Fi low-latency mode: https://source.android.com/docs/core/connect/wifi-low-latency
- Android wake locks: https://developer.android.com/develop/background-work/background-tasks/awake/wakelock
- Samsung battery optimization / sleeping apps:
  https://www.samsung.com/us/support/galaxy-battery/optimization/ and
  https://www.samsung.com/us/support/answer/ANS10003442/
- Moonlight setup guide: https://github.com/moonlight-stream/moonlight-docs/wiki/Setup-Guide
- Sunshine networking/config docs:
  https://docs.lizardbyte.dev/_/downloads/sunshine/en/v0.17.0/pdf/ and
  https://docs.lizardbyte.dev/projects/sunshine/master/md_docs_2configuration.html

## Practical workarounds

- Keep the screen awake and run `termux-wake-lock` before tests; run `termux-wake-unlock` after.
- Disable Samsung Power Saving for the test and put Termux / Termux:API in "Never sleeping apps" when
  possible.
- Prefer phone-as-server for TCP, because doc1 can initiate the TCP control connection.
- Prefer doc1-as-server for Moonlight UDP shape and run from Termux:
  `iperf3 -4 -c <server-ip> -u -R -b 20M -l 1200 -w 4M -O 3 -t 60 -i 1 --get-server-output`.
- If testing UDP reverse mode, pin the Linux-side UDP port with `--cport <port>` and add a temporary
  firewall counter/rule before conntrack to confirm packet arrival.
- If UDP shows zero, use `tcpdump` on the Linux server:
  `sudo tcpdump -ni <lan-iface> "host <phone-ip> and (tcp port 5201 or udp)"`.
- If UDP still fails, do not keep retrying variants indefinitely. Use TCP results plus a real Moonlight
  session at candidate bitrates (`30M`, `45M`, `60M`) and watch Moonlight/Sunshine stats for packet loss,
  frame drops, decode latency, and jitter.

## Reporting

Report Android UDP failures as:

> UDP iperf on Android/Termux was inconclusive: TCP control connected but UDP payload accounting failed.
> TCP shows aggregate capacity, but Moonlight bitrate should be chosen by a real Moonlight soak.
