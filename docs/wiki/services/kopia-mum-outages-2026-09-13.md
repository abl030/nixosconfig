# Kopia Mum outages after the LXC migration

**Date:** 2026-09-13
**Status:** Remediation deployed and verified with clean replacement snapshots and matching restored files. Next full daily cycle remains to be observed.
**Related:** [Forgejo #218](https://git.ablz.au/abl030/nixosconfig/issues/218), [LXC migration](kopia-lxc.md)
**Hosts:** kopia (CT 111), prom (repository mount), doc2 (Kuma/Gotify)

The evidence points to our storage integration and monitoring, with no evidence
of a sustained offsite network outage. The strongest explanation for the slow
repository is overlapping verification, snapshots and maintenance through the
new single-threaded bindfs view. A subsequent controlled directory-listing
comparison confirmed that concurrency improves this path; the effect on a full
daily cycle remains to be measured. The source-permission regression and the
monitoring schema bug below are directly proven.

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

At the incident, prom's `/etc/fstab` gave bindfs
`force-user=100000,force-group=100000`, created files as `1000:100`, and did not
enable multithreading. The running bindfs
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
Music and Ali Cratedigger initially received plain binds.

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

During the incident,
`modules/nixos/services/probes/check-kopia-backup-errors.nix` correctly detected
the source's latest errors using `.lastSnapshot.stats.errorCount`. It then
fetched `/api/v1/snapshots` and incorrectly used `.stats.errorCount` again.

The history response has **`.summary.numFailed`**, with no `stats` field.
The old probe defaulted the absent field to zero, concluded that the previous
snapshot was clean, and sent an UP heartbeat despite consecutive failures.
Evaluating both expressions against the last two live snapshots produced:

| Source | Existing predicate: both failed | Actual `summary.numFailed`: both failed |
| --- | --- | --- |
| Music | false | true (329, 329) |
| Ali Cratedigger | false | true (2, 2) |

This explains the misleading `last snapshot errored but previous was clean`
journal messages. The shared probe is also used by Kopia photos; the schema bug
also prevented it from detecting consecutive errors. Photos had no
corresponding incident in this investigation.

The old verify wrapper had a separate reporting gap: it captured all command
output in a shell variable and sent its failure notification after the command
returned. systemd's 12-hour kill terminated that wrapper before it reported. The
unit had no `OnFailure`, and its specific error-pattern rule did not match
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

The initial RCA was read-only. The user then authorized remediation, recorded
below.

## Remediation and live proof, September 13

Signed code commit `f76bf6786a69413d7de2aa54e48e5e5c5307394a` was pushed to
Forgejo and deployed through the signed-cache push-deploy receiver. The CT's
running `configurationRevision` matches it. The active system is
`/nix/store/gsdzpd000ym3p2mcaridhrsz118gn4kq-nixos-system-kopia-lxc-proxmox-26.11.20260910.aff8a0b`.

- The shared error probe now validates both API response shapes, reads history
  failures from `summary.numFailed`, and fails on malformed/unknown responses.
  Before the replacement snapshots, the deployed executable correctly exited
  1 and named both sources with consecutive errors.
- Music and Ali now have private, read-only ownership-translating bindfs views.
  All **331 previously failing entries** were readable from the CT after the
  change. All 331 original ownership/mode tuples matched the saved baseline;
  write-open attempts through the source views were rejected. Every source
  mount is read-only. No production chmod/chown was needed.
- The destination view now uses `multithreaded` with fixed presented ownership
  `100000:100000` and fixed creation ownership `1000:100`. A bounded local
  concurrency test checked 100 creations and 1,000 reads/stat operations:
  correct underlying ownership, expected presented ownership, and denial to an
  unrelated UID. The live destination process used seven threads during the
  new snapshot. New source views also use concurrency, `nodev` and `nosuid`.
- A pre-change read-only A/B on the same **96 repository directories / 54,397
  entries**, with eight clients, took **33.482 s single-threaded, 2.179 s
  concurrent, 3.894 s concurrent, 7.175 s single-threaded**. The cold first pass
  exaggerates the gain; even the warm comparison favors concurrency. These are
  directory-listing measurements, not a claimed speedup for an entire backup.
- Mum verification now starts at **18:00 AWST**, separated from the 06:00
  snapshot schedule. Output streams into the journal. An independent systemd
  `OnFailure` handler reports timeout and exit context. A one-second synthetic
  timeout triggered a copy of the deployed handler under its unchanged sandbox
  and produced `result=timeout, code=killed, status=TERM`, priority 8. Only curl
  was intercepted; no test notification was delivered. Temporary units and
  files were removed.
- Full `nix flake check` passed, including **13 probe cases and three verifier
  cases**. Formatting, deadnix, statix and shellcheck checks passed for the
  touched code/scripts.

Prom's root-only rollback/evidence directory is
`/root/kopia-mount-change-20260913T071350Z`. It contains the previous fstab, CT
config, old system path, original source metadata and restore-canary hashes.
The original deployment had no CT mount dependency drop-in. Authored mount
files and rollback steps are linked from [the LXC guide](kopia-lxc.md).

Replacement snapshots and restores completed successfully:

| Source | Snapshot finished (AWST) | Errors | Content size | Snapshot ID |
| --- | --- | --- | --- | --- |
| Music | 15:29:30 | **0** (previously 329) | 475,454,366,279 bytes | `c5cd6d0c5731da8d306efd0d1b293f78` |
| Ali Cratedigger | 15:30:26 | **0** (previously 2) | 956,810 bytes | `25247135d36526a295a2922fe0021f28` |

Music's first pass re-hashed 109,774 files in 4m14s because the presented metadata
changed. Its snapshot contains about **6.30 GB more content** than the previous
incomplete one. A formerly unreadable 737,283-byte Music file and an 18-byte file
inside Ali's previously inaccessible `state` directory were restored from these
exact snapshot roots into private temporary directories. Both SHA-256 hashes
matched the pre-change originals, whose hashes and timestamps were also checked
again. Restore targets were removed. The detailed receipt is
`snapshot-restore-proof.json` in the root-only evidence directory above.

The corrected error probe changed from exit **1 before** these snapshots to exit
**0 after** them. All four actual deep-probe units then completed successfully
and delivered new Kuma heartbeats at **15:31:32**. All six Kopia monitors were UP;
both HTTPS endpoints returned their expected authentication response (401), and
the CT had no failed units. The sources API remained responsive during the new
snapshot (observed calls 19–23 ms).

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

Revisit after the next complete daily backup/verify/maintenance cycle: confirm
completion times, bounded API latency and absence of probe timeouts. The new
18:00 verification had not yet started when remediation was verified. The
canary restores prove those selected files; they are not a full repository
restore or evidence of future-cycle stability.
