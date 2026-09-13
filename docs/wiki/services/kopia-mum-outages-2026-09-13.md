# Kopia Mum outages after the LXC migration

**Date:** 2026-09-13
**Status:** RCA complete; remediation not applied. HTTP recovered and today's verification completed; two sources still have repeated permission errors.
**Related:** [Forgejo #218](https://git.ablz.au/abl030/nixosconfig/issues/218), [LXC migration](kopia-lxc.md)
**Hosts:** kopia (CT 111), prom (repository mount), doc2 (Kuma/Gotify)

The evidence points to our storage integration and monitoring, with no evidence
of a sustained offsite network outage. The strongest explanation for the slow
repository is overlapping verification, snapshots and maintenance through the
new single-threaded bindfs view. Its exact contribution has not been isolated
with a before/after configuration experiment. The source-permission regression
and the monitoring schema bug below are directly proven.

All times below are **AWST (UTC+8)**. Gotify/Kuma database times and Kopia's
on-disk debug logs are UTC; the journal renders local time.

## Incident timeline

| Date/time | Observation |
| --- | --- |
| Sep 11 14:01–14:06 | HTTP DOWN page during migration/restarts: nginx returned 502 because the daemon was not listening. The retry sequence began during cutover at 12:31. This was our migration, not the WAN. |
| Sep 12 05:30 | Daily repository verification started. |
| Sep 12 10:50–20:29 | Full maintenance ran **9h39m**. On doc2 it took 1h13m on Sep 9 and 1h51m on Sep 10. |
| Sep 12 14:09–18:13 | Both hourly Mum probes timed out after 250 seconds. Backup/freshness DOWN pages at 15:19; HTTP DOWN at 15:43. |
| Sep 12 17:30 | systemd terminated verification at its 12-hour limit. It was still making progress immediately before termination: 1,038,640 objects processed, 56.9 GB sampled. |
| Sep 12 18:28 / 19:09 | HTTP recovered / backup-error probe resumed passing. Freshness still failed: several sources were actually stale. |
| Sep 13 02:09 / 03:09 | Books and Music reached **44 hours** since their previous snapshots; by 03:09 all source timestamps were fresh again. |
| Sep 13 12:09 and 13:09 | Backup-error probe timed out while the freshness probe succeeded. The error probe also queries snapshot history, which can block independently of the sources endpoint. Backup DOWN 13:19–14:09. |
| Sep 13 14:17–14:28 | Another HTTP retry sequence returned 504, then recovered before exhausting the alert threshold. |
| Sep 13 14:27 / 14:29 | Full maintenance finished after 3h38m; verification finished successfully after **8h59m**, processing 1,122,739 objects (2.7 TB), reading 15,616 files (47.3 GB). |

Recovery of an HTTP/probe heartbeat does not establish backup completeness.

## Why the earlier external-storage classification was premature

The automatic RCAs (Gotify messages 5748, 5750, 5775) found bindfs waiting in
`nfs_file_read` or NFS lookup, then classified the incident as external/storage.
That stack identifies what the process is waiting for at one instant; it does
not establish a dead NAS or broken connection.

Independent checks in this investigation:

- Prom's `tailscale0` receive metric continued through yesterday's HTTP outage.
  At one-minute evaluation steps, the five-minute rate averaged **1.765 MiB/s**
  from 13:30–17:30. After verification was killed, traffic dropped to metadata
  levels while maintenance continued. There were no zero-rate samples from
  13:30–18:30; this excludes a sustained blackout, not brief packet loss.
- The live NAS connection was direct, with three Tailscale pings at **16 ms**.
- Prom's repository NFS mount had remained mounted since Sep 11. At the live
  check, READ/WRITE/LOOKUP/GETATTR counters showed no RPC retransmissions or
  major timeouts. A 15-second sample completed 271 reads (27.12 MiB) and 214
  lookups; read RPCs averaged 48.57 ms and lookups 19.72 ms.
- Prom's kernel had no `kerrynas` unresponsive messages in the investigated
  window. Its two brief NFS warnings were for **tower (`192.168.1.2`)** around
  06:00, not the offsite NAS and not the afternoon outage.
- During a current API timeout, stat of the repository marker succeeded through
  both the direct NFS path (64 ms) and bindfs path (146 ms).

We did not inspect Synology disk/USB telemetry, and have not ruled out shorter
NAS latency spikes or packet loss. There is no basis here for blaming Mum's ISP.

## Storage contention in our new mount path

The live path is CT `/mnt/mum` → prom `/mnt/mum-ct` → bindfs → prom `/mnt/mum`
→ NFSv4 over Tailscale → Synology USB share.

Prom's `/etc/fstab` gives bindfs `force-user=100000,force-group=100000`, creates
files as `1000:100`, and does not enable multithreading. The running bindfs
1.14.7 process had **one thread**; its FUSE connection (`0:333`) had 10–11
requests waiting. Verification uses two workers; maintenance and snapshots
share the same view. Ordinary remote latency therefore delays other queued
filesystem work.

Kopia's debug logs show successful repository listings taking **6h47m–6h49m**
on Sep 12. For example, prefix `p6` returned 7,048 entries at 20:08:06 after
`6h49m1.263688528s`, with `error: null`. Today's index listings also took
5–10 minutes. These are slow operations that eventually complete, while
repository-dependent API requests time out and withhold Kuma heartbeats.

The regression in maintenance/verification duration supports contention as a
major contributor. The workload also changed and caches had moved, so the
entire slowdown cannot yet be attributed quantitatively to bindfs alone.

[Upstream bindfs documentation](https://bindfs.org/docs/bindfs.1.html) confirms
single-threaded operation is the default and documents a permission race in
multithreaded mode. Any concurrency change needs a review of our ownership and
file-creation semantics, followed by a measured comparison.

## Definite backup omissions: source UID mapping

CT root maps to prom UID/GID `100000`, not prom root. The destination and
pfSense source received ownership-translating bindfs views during migration;
Music and Ali Cratedigger are plain binds.

The live sources API and snapshot history show:

| Source | Latest snapshot end | Errors | Verified cause |
| --- | --- | --- | --- |
| `/mnt/virtio/Music` | Sep 13 08:09:56 | **329** | Files under `Incoming/auto-import` and `Incoming/failed_imports/bad_files` cannot be read. A representative file is mode `0600`, prom owner `963:100`. |
| `/mnt/virtio/ali-cratedigger` | Sep 13 06:01:54 | **2 directories** | `processing` and `state` cannot be entered. `processing` is mode `0700`, owner `960:960`. Two directory errors can omit many descendant files. |

Read/search checks as UID/GID `100000` confirmed the access failures. The last
two retained snapshots have 329/329 and 2/2 failures respectively. The other
eight sources had fresh snapshots reporting zero errors at the final check;
that is snapshot evidence, not a restore test.

## Definite monitor bug: wrong history field

`modules/nixos/services/probes/check-kopia-backup-errors.nix` correctly detects
the source's latest errors using `.lastSnapshot.stats.errorCount`. It then
fetches `/api/v1/snapshots` and incorrectly uses `.stats.errorCount` again.

The live history response has **`.summary.numFailed`**, with no `stats` field.
The probe defaults the absent field to zero, concludes that the previous
snapshot was clean, and sends an UP heartbeat despite consecutive failures.
Evaluating both expressions against the last two live snapshots produced:

| Source | Existing predicate: both failed | Actual `summary.numFailed`: both failed |
| --- | --- | --- |
| Music | false | true (329, 329) |
| Ali Cratedigger | false | true (2, 2) |

This explains the misleading `last snapshot errored but previous was clean`
journal messages. The shared probe is also used by Kopia photos; the schema bug
affects its ability to detect future consecutive errors too. Photos had no
corresponding incident in this investigation.

The verify wrapper has a separate reporting gap: it captures all command output
in a shell variable and sends its failure notification after the command
returns. systemd's 12-hour kill terminates that wrapper before it reports. The
unit has no `OnFailure`, and its specific error-pattern rule does not match
`start operation timed out`. There was no Kopia verification-failure Gotify
message for the Sep 12 timeout in the inspected messages.

## Remediation order and proof required

1. Fix the history parser to read `summary.numFailed` and treat unexpected
   response shapes as unknown/failure. Exercise it with representative real API
   shapes: consecutive errors, one transient, clean history, malformed history.
2. Correct read access for the two source trees while preserving source
   read-only isolation. Follow the existing pfSense ownership-view approach or
   another scoped mapping; do not recursively relax production file modes.
   Re-snapshot and verify that formerly unreadable entries are present.
3. Separate heavy verification, backup and maintenance work, and measure a
   safe alternative to the single-worker destination view. Compare completion
   times and API latency under an equivalent workload before calling it fixed.
4. Report verification timeouts through systemd failure handling and retain
   progress in the journal. Keep genuine stale/error alerts effective; simply
   extending alert grace periods does not fix backup omissions or contention.

No restarts, mount changes, snapshot triggers or service/config fixes were made
as part of this RCA. Repository changes only record these findings.

## Evidence locations and revisit condition

- Kuma: doc2 `/mnt/virtio/uptime-kuma/kuma.db`, read-only query of monitors
  98–103 and heartbeat transitions.
- Gotify: `sudo gotify-triage msg
  5721,5722,5723,5746,5747,5748,5749,5750,5757,5759,5774,5775,5776` on doc2.
- Journals: `kopia-mum`, `kopia-verify-mum`, both Mum deep probes, and nginx on
  kopia; historical Kopia units on doc2; kernel and tailscaled on prom.
- Debug logs: prom `/nvmeprom/containers/kopia/.cache/kopia/cli-logs/`, daemon
  `kopia-20260911-060658-444-server-start.*.log` and verifier files containing
  `8387` (Sep 12) or `16537` (Sep 13). Logs rotate; the evidence above records
  the relevant measurements without copying source filenames or credentials.
- Mimir: `rate(node_network_receive_bytes_total{host="prom",device="tailscale0"}[5m])`.
- Live kernel data: `/proc/self/mountstats`, bindfs `/proc/<pid>/task` and
  `/proc/<pid>/stack`, `/sys/fs/fuse/connections/333/waiting` on prom. IDs are
  specific to this investigation and must be rediscovered after remounts.

Revisit after the parser and source-access fixes, then after one complete daily
backup/verify/maintenance cycle. Successful sampled verification alone cannot
prove that unreadable source files were included.
