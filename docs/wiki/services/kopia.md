# Kopia Backup Architecture

**Last updated:** 2026-06-07
**Status:** Operational
**Source module:** `modules/nixos/services/kopia.nix`
**Host:** doc2
**Related:** [#236](https://github.com/abl030/nixosconfig/issues/236) (security hardening), [#237](https://github.com/abl030/nixosconfig/issues/237) (forgejo dumps → kopia), brainstorms [`2026-05-13-kopia-harden-backup-integrity`](../../brainstorms/2026-05-13-kopia-harden-backup-integrity-requirements.md) + [`2026-06-07-backup-coverage-widening`](../../brainstorms/2026-06-07-backup-coverage-widening-requirements.md)

## Topology

Two kopia server instances run on doc2, each backing up to a different destination:

| Instance | Sources | Destination | Purpose |
|---|---|---|---|
| **photos** | `/mnt/data/Life/Photos/library` + `/mnt/data/Life` (excluding the `Photos/*` derivatives, the already-covered library, and `Tech/Backups/UnraidUSB`) | Wasabi S3 (`kopiaphotos` bucket, ap-southeast-2) | Immutable, jurisdictional offsite for irreplaceable personal data — photo originals + the rest of `/Life` (incl. immich DB dumps in `Photos/backups`) |
| **mum** | `/mnt/data/Life`, `/mnt/data/Media/Books`, `/mnt/data/Media/Music`, `/mnt/virtio/Music` (the beets library), `/mnt/backup/pfsense` | Mum's Synology NFS (over Tailscale, mounted at `/mnt/mum`) | Family-grade offsite for everything irreplaceable + the curated music library |

`/mnt/data/Life` is deliberately backed up to **both** repos — Synology (mum) for the full family-grade copy, Wasabi (photos) for the immutable, jurisdictionally-separate copy. The photos copy excludes the regenerable immich derivatives and dedupes the photo library against its own source, so nothing re-uploads. See the [2026-06-07 brainstorm](../../brainstorms/2026-06-07-backup-coverage-widening-requirements.md) and [#237](https://github.com/abl030/nixosconfig/issues/237).

Both run as systemd services under `kopia` user (with `runAsRoot = true` on both currently, because the upstream NFS share has restrictive perms — this is suboptimal and worth revisiting).

## Network exposure

Kopia binds **loopback only** (`127.0.0.1`) — nginx terminates external TLS via `homelab.localProxy.hosts` and proxies to the loopback port. Direct LAN access to the kopia admin ports is refused.

Why no end-to-end TLS at the kopia layer: nginx-on-doc2 → kopia-on-doc2 is loopback; an attacker would need root on doc2 to sniff it. Self-signed TLS between nginx and kopia would be module surgery for zero threat-model improvement.

### CSRF tokens — disabled, with rationale

`--disable-csrf-token-checks` is **on**, despite #236 originally targeting its removal. Discovered during execution: enabling CSRF tokens breaks Kuma's `json-query` monitor on `/api/v1/sources` (kopia's CSRF middleware is all-or-nothing and rejects basic-auth-only GET requests with "Invalid or missing CSRF token"). Re-enabling the flag is the practical answer; alternatives (kopia's `--control-api` with separate creds, or a custom monitoring sidecar) cost significantly more complexity for the same realized threat model.

Realized threat model with the flag on, given the rest of our hardening:

| CSRF threat surface | Mitigated by |
|---|---|
| "Any local process on localhost can issue commands" | **Loopback bind** — `127.0.0.1` only, requires root on doc2 (which would be game-over regardless) |
| "XSS-on-UI fires authenticated CSRF requests" | **Object Lock Compliance** — destructive ops (delete snapshots, shorten retention, wipe repo) physically blocked at the Wasabi layer regardless of who issues them. Damage a successful XSS-CSRF can do is reduced to "trigger wrong snapshot" or "change UI preferences" — annoying, not data-loss. |

The flag's been moved out of the "blanket security regression" category and into "documented operational trade-off backed by an external immutability layer." See the in-module comment in `modules/nixos/services/kopia.nix` for the inline version.

If kopia ever exposes a per-endpoint CSRF whitelist, or if `--control-api` matures enough to replace the standard `/api/v1/sources` endpoint with the same shape, revisit.

## Secret handling

- **Repository encryption password (`KOPIA_PASSWORD`)**: sops-encrypted at rest (`secrets/kopia.env`), decrypted to `/run/secrets/kopia/env` at boot, loaded into the systemd unit's `EnvironmentFile`. Kopia is started with `--no-persist-credentials` so the password is **never cached on disk** — kopia reads it from env on every operation.
- **Wasabi S3 access keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)**: also sops-encrypted and loaded via the same env file. **However**, kopia's `--no-persist-credentials` flag only strips the repo password, NOT S3 backend credentials. The S3 keys are persisted plaintext in `/mnt/virtio/kopia/photos/repository.config` (kopia limitation, not a config error). This is mitigated by Object Lock and IAM scoping — see below.

### Why the S3 key leak is acceptable

| Threat | Mitigation |
|---|---|
| Attacker reads `repository.config` and tries to delete backups | **Object Lock Compliance** blocks deletes for the retention period regardless of IAM permissions |
| Attacker reads `repository.config` and tries to shorten retention | Compliance mode forbids shortening — cannot be overridden by any IAM user |
| Attacker uses the keys to compromise other Wasabi resources | **IAM scoping** — the `kopia` user's keys are scoped to `kopiaphotos` bucket only via a custom JSON policy (see below) |
| Attacker reads encrypted blobs from Wasabi | They cannot decrypt without `KOPIA_PASSWORD`, which lives only in sops |

End result: an attacker would need **both** the on-disk Wasabi keys **and** the sops/age key to actually decrypt and read photo content. And nobody — including us — can delete or modify locked blobs until retention expires.

## Wasabi configuration (photos)

Bucket: `kopiaphotos` (ap-southeast-2, Sydney).

- **Object Lock**: enabled at bucket creation (cannot be enabled later — would have required bucket migration).
- **Default Retention on bucket**: **DISABLED**. Critical — if the bucket sets a default retention, kopia's session-marker blobs get locked too and can't be cleaned up after init, causing `kopia repository create` to fail with `Access Denied` on the cleanup phase. Kopia sets per-blob retention itself via the `--retention-mode` / `--retention-period` flags.
- **Mode**: **Compliance** (not Governance). Governance allows a privileged IAM credential to override — but that credential is itself an attack surface, and we'd never legitimately use the override. Compliance removes that branch entirely.
- **Retention period**: **90 days** rolling. Kopia maintenance extends retention on existing blobs to keep a rolling window. If maintenance stops running for >90 days, blobs become deletable — this is the natural "migrate-off-Wasabi" escape hatch.
- **Object Lock Extension**: enabled in kopia maintenance. Verified on 2026-05-14 with a forced full maintenance run: `extend-blob-retention-time` succeeded and extended 15,729 blobs for the 90-day retention period.

### IAM policy for the kopia user

The `kopia` Wasabi user has a single custom JSON policy attached (no canned `WasabiReadOnlyAccess` / `WasabiWriteOnlyAccess` — those are account-wide and would defeat the scoping). Policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "KopiaBucketLevel",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:GetBucketObjectLockConfiguration"
      ],
      "Resource": "arn:aws:s3:::kopiaphotos"
    },
    {
      "Sid": "KopiaObjectLevel",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:GetObjectRetention",
        "s3:PutObjectRetention",
        "s3:GetObjectLegalHold",
        "s3:PutObjectLegalHold"
      ],
      "Resource": "arn:aws:s3:::kopiaphotos/*"
    }
  ]
}
```

No `s3:ListAllMyBuckets` — leaked keys can't enumerate the rest of the Wasabi account.

`s3:DeleteObject` is granted because kopia's maintenance compacts old indexes. `s3:DeleteObjectVersion` + `s3:ListBucketVersions` + `s3:GetObjectVersion` were added on 2026-05-13 after we discovered that without them, even *we* couldn't clean up an accidental delete marker — only account-admin credentials could. The trade-off analysis:

- Destruction ceiling is unchanged — any version still inside its Compliance retention window cannot be deleted regardless of these permissions. Object Lock blocks the destructive use, not IAM.
- Added capabilities (enumerate versions, remove delete markers, target version-specific deletes) are cosmetic for an attacker — they can clean up their own delete-marker noise but cannot permanently destroy data covered by Object Lock.
- Operator + kopia-maintenance gain the agility to fix accidental delete markers and to compact away post-retention-expiry blobs (kopia's long-term maintenance correctness).

## Snapshot policy (photos)

The photos repo carries **two** sources (both `root@kopia`, daily at 06:00 — after the nixos-upgrade window and kopia-verify):

**1. `/mnt/data/Life/Photos/library`** — the original positive-scope source for immich's user-uploaded photo originals:

| Setting | Value | Rationale |
|---|---|---|
| **Source path** | `/mnt/data/Life/Photos/library` | Positive scope — immich's user-uploaded originals; avoids ignore patterns for the regenerable subdirs (`thumbs/`, `encoded-video/`, `upload/`, etc.) |
| **Retention** | Kopia defaults: 3 annual / 24 monthly / 4 weekly / 7 daily / 48 hourly / 10 latest | Photos are static, dedup makes additional snapshots near-free |
| **Compression** | Off | JPGs/HEICs are already compressed |

**2. `/mnt/data/Life`** (added 2026-06-07) — everything else under `/Life`, into the **same repo** so it dedupes against the photo blobs already present (the 314 GiB library never re-uploads). Carries a `files.ignore` policy set from the module's `sourceExcludes`:

| Excluded (relative to `/mnt/data/Life`) | Why |
|---|---|
| `/Photos/library` | Already its own source (above) |
| `/Photos/thumbs`, `/Photos/encoded-video`, `/Photos/upload` | immich-regenerable |
| `/Tech/Backups/UnraidUSB` | 4 GiB monthly full-rewrite, re-creatable |

`Photos/backups` (the daily immich Postgres dumps) and `Photos/profile` are **not** excluded, so the immich DB rides this source into immutable Wasabi.

## Snapshot policy (mum)

Mum's repo backs up a deliberately-chosen set, NOT all of `/mnt/data` (which would include video media we don't ship offsite):

- `/mnt/data/Life`, `/mnt/data/Media/Books`, `/mnt/data/Media/Music`
- `/mnt/virtio/Music` — the curated ~505 GiB beets library (its own ZFS dataset on prom, a virtiofs submount). Synology-only (re-downloadable → not worth per-GB Wasabi). Added 2026-06-07; walks ~100k files, which is why the [virtiofsd fd fix (#267)](../infrastructure/virtiofsd-fd-exhaustion.md) is a prerequisite.
- `/mnt/backup/pfsense` — the pfSense ZFS replica (see [pfsense-backup.md](../infrastructure/pfsense-backup.md)).

Each is its own kopia source with its own policy. Verify runs at 2% sample (vs photos at 5%) because the data volume is larger.

**Schedules:** all mum sources are on `06:00 daily, runMissed: true`, set via the kopia API by the reconciler. Drift on these schedules is what the freshness deep probe (#254) detects.

## Declarative source registration — `kopia-<name>-source-sync` (added 2026-05-20, #255)

After the #254 freshness probe caught 12 weeks of silent backup loss, we made `inst.sources` the source of truth via `kopia-<name>-source-sync.service` (per-instance systemd oneshot).

**Per-source excludes (`sourceExcludes`, added 2026-06-07):** a per-instance `sourceExcludes` option (attrset of source-path → gitignore-style rules) lets the reconciler write a source's `files.ignore` policy alongside its schedule, keeping exclusions declarative in nix rather than as a `.kopiaignore` file in the backed-up tree. Used for the photos `/mnt/data/Life` source (see Snapshot policy above). Note kopia also auto-reads `.kopiaignore` files (the global `files.ignoreDotFiles` default) — we deliberately don't use that, to keep the source tree clean and the config in one place.

**What it does on every rebuild:**

1. Waits up to 90s for `/api/v1/repo/status` to be reachable (the daemon may still be starting).
2. For every path in `inst.sources`:
   - `PUT /api/v1/policy?...path=...` with `scheduling.timeOfDay = [{ hour, min }]` from `inst.snapshotScheduleHour/Minute` (default `06:00`).
   - If the source isn't already registered in the daemon, `POST /api/v1/sources/upload` to create + trigger the initial snapshot.
3. Logs a WARNING for any registered source NOT in `inst.sources` — orphan detection. We never auto-remove; cleanup is manual via the kopia CLI (see below).

**Idempotent.** Re-running on unrelated rebuilds is cheap (~50ms per source). `restartTriggers` are keyed off the JSON-encoded `(sources, snapshotScheduleHour, snapshotScheduleMinute)` so any change re-runs the reconcile.

### Cleaning up orphan sources

The reconciler logs orphans to stderr but doesn't touch them. To remove via the kopia CLI:

```sh
# Find the policy manifest IDs for the unwanted source
sudo bash -c 'set -a; . /run/secrets/kopia/env; set +a
  /nix/store/<...>/kopia/bin/kopia --config-file=/mnt/virtio/kopia/<instance>/repository.config policy list'

# Delete each manifest (kopia warns; pass --dangerous-commands=enabled)
sudo bash -c 'set -a; . /run/secrets/kopia/env; set +a
  /nix/store/<...>/kopia/bin/kopia --config-file=... manifest delete --dangerous-commands=enabled <id>'

# Restart the kopia daemon so it re-reads source list from manifests
sudo systemctl restart kopia-<instance>.service
```

The daemon caches the source list in memory. Deleting the policy manifest alone doesn't drop the source from `/api/v1/sources` — the restart forces a re-read.

### Gotcha: kopia API can stall mid-snapshot

During a large initial upload (e.g. the 333 GB photos library), the kopia daemon's PUT/POST endpoints become unresponsive — 30s timeout. The reconciler doesn't fail loudly when this happens; it just logs `policy update failed` and the next rebuild retries. If you see "reconcile complete — declared=N missing=0 orphans=0" but the policy state didn't update, kopia was likely busy. Check `currentTask` on the affected source via `/api/v1/sources`.

**2026-06-07 — this stall hung a deploy.** Adding the 505 GiB `/mnt/virtio/Music` source to kopia-mum triggered its initial snapshot; the daemon went busy and the reconciler's *next* policy PUT blocked. The reconciler's curls had no `--max-time` and the `kopia-<name>-source-sync` oneshot had `TimeoutStartSec=infinity`, so the curl — and the `nixos-rebuild switch` waiting on that oneshot — hung indefinitely (released manually with `systemctl kill kopia-mum-source-sync`). Fixed in `modules/nixos/services/kopia.nix`: every reconciler curl now carries `--max-time 30` (a stalled PUT/POST/GET fails fast and the loop continues via the existing `|| echo failed` handling), and the source-sync oneshot has `TimeoutStartSec = 600` as a hard backstop. The snapshot itself is unaffected — `trigger_upload` only *starts* the upload; it runs in the background regardless of the reconciler.

### Gotcha: bash here-strings add a trailing newline

`url_encode() { jq -sRr @uri <<<"$1"; }` looks reasonable but the `<<<` operator appends a `\n` before passing to jq. jq's `@uri` faithfully encodes the newline as `%0A`, kopia accepts the URL, and creates a NEW SOURCE with a literal `\n` in the path. The fix is `printf '%s' "$1" | jq -sRr @uri`. Hit this on first deploy of the reconciler; left 3 orphan sources behind that needed manual `manifest delete` cleanup.

## Freshness monitoring — `check-kopia-fresh` (added 2026-05-20)

Per-instance deep probe declared in `modules/nixos/services/kopia.nix`:

```nix
monitoring.deepProbes = lib.mapAttrsToList (name: inst: {
  name = "Kopia ${name} freshness";
  command = ".../check-kopia-fresh";
  intervalSecs = 3600;     # check hourly
  serviceConfig.Environment = [
    "KOPIA_BASE_URL=http://localhost:${toString inst.port}"
    "KOPIA_AUTH_FILE=${config.sops.secrets.${kopiaMonitoringSecret}.path}"
    "KOPIA_MAX_AGE_HOURS=36"
  ];
}) cfg.instances;
```

The probe (`modules/nixos/services/probes/check-kopia-fresh.nix`) queries `/api/v1/sources`, parses each source's `lastSnapshot.endTime`, and fails if any source is older than `KOPIA_MAX_AGE_HOURS` (default 36h — covers the daily 06:00 schedule with 12h slack for slow runs / weekend skips).

**On a fresh deploy this immediately caught a 12-week-old silent backup outage**: the migration from doc1's container kopia to doc2's native module on 2026-02-26 left the 3 mum sources without schedules. The orphaned sources had `schedule: {runMissed: true}` with no `timeOfDay` — kopia knew about them but wouldn't snapshot. No HTTP probe noticed because they returned 200 with `errorCount: 0` (the error count of the LAST snapshot, taken 83 days ago, was indeed 0). #254 deep probe caught it; #255 tracks the kopia.nix change to prevent recurrence.

**Probe output classes:**

| Output | Meaning | Action |
|---|---|---|
| `OK` | All sources within `MAX_AGE_HOURS` | Push UP to Kuma. |
| `EMPTY` | `/api/v1/sources` returned no sources | Daemon up but no sources registered — investigate config. |
| `NEVER <paths>` | Source registered but never snapshotted | Run `kopia snapshot create <path>` once via API/CLI. |
| `STALE <paths> (<n>h)` | Source has snapshotted before but not within window | Check the source's schedule / repository connectivity. |

## Bootstrap verification

## Bootstrap verification

The fresh `kopiaphotos` repository bootstrap completed on 2026-05-13. The transient `kopia-verify-post-bootstrap.service` then ran a one-off 100% verify and completed successfully on 2026-05-13 22:57 AWST:

```text
Finished processing 49963 objects (324.8 GB). Read 45086 files (324.8 GB).
```

The service no longer exists because it was a transient closeout unit, but the journal entry remains on doc2. This verifies the fresh Wasabi repository could read back the entire initial photo snapshot.

## Append-only enforcement

- **Photos (Wasabi)**: server-side Object Lock Compliance as described above. No filesystem snapshots or other layers — Wasabi enforces.
- **Mum (Synology)**: **Synology-side BTRFS snapshot retention** on the share kopia writes to. This is **configured DSM-side**, not in this repo. Mum's user / admin handles this — we don't have access to DSM. If a snapshot retention regime isn't in place, mum's backup is not append-only-protected and a kopia compromise would let the attacker overwrite or delete on the Synology.

## Key operational details

- **Verify timer**: `kopia-verify-{photos,mum}.service` runs daily at 05:30 (`OnCalendar=*-*-* 05:30:00`). Photos verifies at 5% sample, mum at 2%. Failures send a Gotify ping.
- **Photos maintenance owner**: `root@kopia`. This must match the migrated source identity (`overrideHostname = "kopia"; overrideUsername = "root"`); otherwise manual full maintenance exits with `maintenance must be run by designated user: root@doc2`.
- **Both kopia instances share `secrets/kopia.env`** — adding/removing creds touches both services. Verify both instances after env changes.
- **Future Wasabi key rotation**: requires rewriting both `secrets/kopia.env` (sops) AND `/mnt/virtio/kopia/photos/repository.config` on doc2. Updating sops alone is insufficient because kopia reads S3 creds from the persisted config, not env, after initial connect. See the rotation playbook below.
- **NFS watchdog**: `homelab.nfsWatchdog` probes the mum NFS path every 5 min; restarts `kopia-mum.service` if the mount goes stale. Configured automatically by the module when an instance references `/mnt/mum`.

## Wasabi key rotation playbook

When rotating the Wasabi keys (e.g. after a suspected leak, or routine rotation):

1. Create new key pair in the Wasabi console for the `kopia` user. Don't disable the old pair yet.
2. Update `secrets/kopia.env` via sops, replace both `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
3. Commit + push.
4. Deploy doc2: `ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"`. Env file now decrypts to the new values.
5. On doc2, rewrite `repository.config` with the new keys:
   ```bash
   sudo systemctl stop kopia-photos.service
   sudo bash -c '
     set -a; source /run/secrets/kopia/env; set +a
     nix run nixpkgs#kopia -- repository disconnect --config-file=/mnt/virtio/kopia/photos/repository.config
     nix run nixpkgs#kopia -- repository connect s3 \
       --bucket=kopiaphotos \
       --endpoint=s3.ap-southeast-2.wasabisys.com \
       --no-persist-credentials \
       --override-hostname=kopia \
       --override-username=root \
       --config-file=/mnt/virtio/kopia/photos/repository.config
     nix run nixpkgs#kopia -- maintenance set \
       --config-file=/mnt/virtio/kopia/photos/repository.config \
       --owner=root@kopia \
       --extend-object-locks=true
   '
   sudo systemctl start kopia-photos.service
   ```
6. Verify a snapshot still runs cleanly.
7. **Then** disable the old key pair in the Wasabi console.

## Restore drill

A real restore drill is its own work — see [#238](https://github.com/abl030/nixosconfig/issues/238) if it exists, or file it. The fresh-repo re-upload performed on 2026-05-13 was effectively a read-side drill of the whole dataset (every file in the 334.8 GB `/mnt/data/Life/Photos/library` snapshot was successfully read), but a true restore drill would write a snapshot back to a scratch path and compare. Not done yet.

## Decision history

All decisions on this page were made via the 2026-05-13 brainstorm. Key moments:

- **Why not full TLS at kopia layer**: loopback hop, zero threat-model improvement, module surgery cost.
- **Why not ZFS encryption on `nvmeprom/containers`**: `--no-persist-credentials` for the password sidesteps the at-rest issue cleanly; ZFS encryption would touch every VM on prom and add unattended-mount key handling for negligible residual benefit.
- **Why Compliance not Governance**: single-operator homelab — the Governance override credential is theatre, and removing it removes its attack surface.
- **Why 90d retention**: balance — protects against slow-burn ransomware (attacker sits in systems for weeks before triggering), bounded migration cost (~3 months dual-pay worst case), storage-cost-free for static data.
- **Why fresh bucket and full re-upload**: Object Lock applies at upload time. Existing blobs uploaded years ago would never get retroactively locked, defeating the whole point. The only path to genuine immutability for static data was a fresh bucket + full re-upload.
- **Why narrow source to `/library` not full Photos dir**: positive scope is cleaner than maintaining ignore patterns for immich's regenerable subdirs. Single source-of-truth.
- **Why Covert Copy was rejected**: considered (Wasabi marketing surfaced it), rejected because single-operator means the multi-user-auth gate is theatre, and the doubling of storage cost outweighs the marginal protection beyond Object Lock.
- **Why daily snapshots at 06:00**: after the 04:00–05:00 nixos-upgrade window and the 05:30 kopia-verify, with a full day of headroom for retries.
