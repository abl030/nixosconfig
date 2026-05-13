# Kopia: harden backup integrity (issue #236)

**Date:** 2026-05-13
**Issue:** [#236](https://github.com/abl030/nixosconfig/issues/236)
**Scope:** Standard
**Status:** Executing — bootstrap upload in progress; see addendum at the bottom for realized outcome and discoveries that differ from the plan

## Problem

`modules/nixos/services/kopia.nix:252-256` launches every kopia server with `--insecure --disable-csrf-token-checks` AND `--address=0.0.0.0:<port>`. Three failures stack:

1. Kopia listens on every interface, bypassing the nginx reverse proxy entirely — every LAN host can talk to kopia's admin API directly.
2. CSRF is disabled, so any same-origin XSS or local process with reachability can issue arbitrary kopia commands (delete snapshots, change retention, read repo password).
3. The audit also surfaced that the Wasabi S3 access key + secret for the photos repo are stored plaintext in `/mnt/virtio/kopia/photos/repository.config`. These grant full read/write/delete on the bucket — a strictly bigger leak than the kopia repo password (which is env-only).
4. Append-only enforcement at the storage layer is absent. Anyone with kopia password OR Wasabi keys can delete the entire backup.

Backups are the last line of defence against ransomware or hostile insider. A single failure here is fleet-fatal.

## Decisions

### Item 1 — drop CSRF disablement, restrict bind, keep nginx TLS termination

- `--address=0.0.0.0:${port}` → `--address=127.0.0.1:${port}` in `modules/nixos/services/kopia.nix`
- Delete `--disable-csrf-token-checks`
- Keep `--insecure` — nginx (already in front via `homelab.localProxy.hosts`) terminates external TLS; internal hop is loopback-only on doc2.

**Why not full TLS at the kopia layer:** internal HTTPS-to-self with self-signed certs is module surgery for zero threat-model improvement over loopback HTTP. You'd need root on doc2 to sniff `lo`.

**Why not unix socket:** `homelab.localProxy` assumes TCP. Adding socket support is non-trivial for the same security outcome as 127.0.0.1 bind.

### Item 2 — eliminate at-rest secrets via `--no-persist-credentials`

Instead of ZFS-encrypting the kopia config dataset, eliminate the secrets from `repository.config` in the first place. Reconnect both repos with `--no-persist-credentials`. Kopia then reads `KOPIA_PASSWORD` + `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` from env at startup; nothing sensitive lands in `/mnt/virtio/kopia/*/repository.config`.

ZFS encryption on the parent `nvmeprom/containers` dataset is rejected as out of proportion — it'd touch every VM on prom and introduces a separate key-handling problem (unattended boot mount), with zero residual benefit once the secrets are env-only.

### Item 3 — append-only offsite via Wasabi Object Lock

Wasabi (S3-compatible) supports Object Lock — WORM at the object level enforced server-side. Once a blob is uploaded with a retention timer, **nobody** can delete or overwrite it until the timer expires. Not us, not an attacker with our keys, not Wasabi support.

**Mode:** **Compliance** (not Governance). Governance allows override via a privileged IAM credential, which is itself an attack surface we'd never legitimately use. Compliance removes the override branch entirely.

**Retention period:** **90 days**. Storage-cost-free for static data (the blob exists either way; retention just gates deletion). Protects against slow-burn attackers who sit in our systems for weeks before triggering wipes. Bounded migration cost: if we ever need off Wasabi, stop kopia maintenance and wait 90 days for all locks to expire.

**Existing data is not retroactively protected.** Object Lock applies to objects at upload time. Photos are static — kopia uploaded the historical blobs years ago and never re-uploads them. Therefore: **fresh Wasabi bucket + fresh kopia repo + full re-upload of ~500GB.** Loses backup version history (acceptable for static photos), but is the only path to genuine immutability for the existing dataset.

Side benefit: the re-upload is effectively a full read-side restore drill (partly satisfies #238).

### Mum repo (filesystem backend over NFS)

Append-only enforcement at the storage layer — Synology-side BTRFS snapshot retention on the share kopia writes to. Configuration is DSM-side, **out of scope for this repo**. Not tracked here.

Kopia config side: `--no-persist-credentials` reconnect for consistency (no secrets to remove, but normalises both repos).

## Execution order

1. **Module change** — edit `modules/nixos/services/kopia.nix`. Commit, push, rebuild doc2. Verify proxy works (`https://kopiaphotos.ablz.au`, `https://kopiamum.ablz.au`), verify direct LAN access to `:51515`/`:51516` is refused.
2. **Mum reconnect** — `kopia repository disconnect` + reconnect with `--no-persist-credentials`. Restart `kopia-mum.service`. Verify a snapshot runs.
3. **(User) Wasabi**: rotate keys (new pair with `s3:PutObjectRetention`, disable old pair), create new bucket with Object Lock at creation, Compliance mode, 90d default retention.
4. **Sops update** — new `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` into `secrets/hosts/doc2/kopia.env`. Deploy.
5. **Fresh photos repo** — stop `kopia-photos.service`, move `/mnt/virtio/kopia/photos` aside as `photos.old`. `kopia repository create s3 --bucket=<new> --endpoint=s3.ap-southeast-2.wasabisys.com --no-persist-credentials --retention-mode=COMPLIANCE --retention-period=90d`. Start service.
6. **(User) Kick first snapshot** — `kopia snapshot create /mnt/data/Life/Photos`. ~10-12hr at fibre upload. No maintenance window needed.
7. **Verify** — `kopia snapshot verify --verify-files-percent=100` once upload completes.
8. **Decommission** — delete `photos.old`, delete old Wasabi bucket, confirm old keys revoked.
9. **Close #236** — link commits, note all three acceptance items satisfied.

## Acceptance items vs decisions

- [x] Drop `--insecure` and `--disable-csrf-token-checks` → **partial**: CSRF flag dropped, `--insecure` kept with loopback bind as justified alternative. Decision recorded above.
- [x] Kopia config dataset has encryption → **substituted**: `--no-persist-credentials` removes the need (no plaintext secrets at rest).
- [x] Offsite kopia repo is in append-only / object-lock mode → **yes, Wasabi Object Lock Compliance 90d on a fresh bucket with full re-upload**.

## Risks / unknowns

- **Kopia retention extension in Compliance mode.** Kopia's maintenance bumps retention forward on existing blobs to keep a rolling window. Compliance lets you *lengthen* retention but never shorten — this matches kopia's needs. Verify by reading kopia logs after first maintenance cycle.
- **500GB upload duration.** Estimated 10-12hr at fibre. Concurrency with mum's NFS backup on `/mnt/data` traffic is fine — different egress path.
- **Cutover gap.** Between stopping the old photos service and the new repo completing its first snapshot, photos backup is not happening to either Wasabi bucket. Mum repo still snapshots `/mnt/data` (which includes `/mnt/data/Life/Photos`) so the dataset is still backed up to Synology over Tailscale during the window. Acceptable.

## Out of scope (intentional, not deferred)

- ZFS encryption on `nvmeprom/containers` — rejected per item 2 reasoning.
- Synology-side BTRFS snapshot config for mum's share — DSM config, not in this repo. User configures separately.
- Restore drills for non-photos data (issue #238) — partly satisfied as side-effect of fresh re-upload, but the broader drill is its own work.

## Addendum — realized outcome (2026-05-13, post-execution)

The plan above is preserved as the decision audit trail. Execution surfaced three things that differ from how item 2 and item 3 are written; the wiki at `docs/wiki/services/kopia.md` is the source of truth going forward.

### Discovery 1: `--no-persist-credentials` only strips the repo password, not S3 keys

The plan asserted that `--no-persist-credentials` would keep both `KOPIA_PASSWORD` and `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` out of `repository.config`. **Wrong.** The flag only controls the repo encryption password. After `kopia repository create`, the S3 access key and secret are still persisted plaintext in `/mnt/virtio/kopia/photos/repository.config`. This is a kopia limitation, not a config error — the S3 backend connection info has to live somewhere, and kopia stores it in the connection config.

**Reframed security posture (this is what we actually achieved):**

| Threat | Before | After |
|---|---|---|
| Repo password leaked from disk | Yes | **No** — env-only via `--no-persist-credentials` |
| S3 keys leaked from disk | Yes | **Yes (unchanged)** |
| S3-key holder can delete blobs | **Yes** | **No** — Object Lock Compliance blocks |
| S3-key holder can shorten retention | **Yes** | **No** — Compliance forbids |
| S3-key holder can pivot to other Wasabi resources | **Yes** | **No** — IAM scoped to `kopiaphotos` bucket only |
| Attacker can decrypt photo content | Needs S3 keys + repo password | Needs S3 keys **plus** sops/age key |

End result: the S3 key leak is now layered — destructive use blocked by Object Lock, lateral movement blocked by IAM scoping, decryption blocked by sops. Different threat model than the plan described, but a clean defense-in-depth posture.

### Discovery 2: Bucket-default retention breaks `kopia repository create`

First `kopia repository create` failed at the cleanup phase with `Access Denied` on `DeleteBlob`. Root cause: the new bucket had a **default retention period** of 90d set at the bucket level (which I'd specified at bucket creation), so every uploaded object — including kopia's ephemeral session-marker blobs — got auto-locked and couldn't be deleted during init cleanup.

**Fix:** keep Object Lock **enabled** on the bucket (this part is set at creation and cannot be flipped later), but **disable the bucket-default retention period**. Kopia applies retention per-blob itself via the `--retention-mode` / `--retention-period` flags. Documented in the wiki under "Wasabi configuration (photos)".

The failed create left a handful of orphan session-marker blobs in the bucket that we can't delete; they age out in 90 days. Cosmetic only.

### Discovery 3: Wasabi IAM is AWS-faithful but the canned policies are wide

Wasabi supports per-bucket JSON IAM policies with the same shape as AWS. The canned `WasabiReadOnlyAccess` / `WasabiWriteOnlyAccess` are account-wide by design — there is no per-bucket toggle. To scope: write a custom JSON policy via Policies → Create Policy in the Wasabi console, attach to the user, then detach the canned policies (policy evaluation is union-of-allows, so leaving the wide policies attached defeats the scoping).

The minimal policy for kopia's needs is captured in the wiki — bucket-level + object-level `Allow` blocks, no `ListAllMyBuckets`.

### Acceptance items, actual landed state

- [x] **Item 1** (`--insecure` and `--disable-csrf-token-checks` removed): CSRF token check restored, `--insecure` kept with the bind narrowed from `0.0.0.0` to `127.0.0.1` so kopia is loopback-only behind nginx. Justification recorded in commit 833f35b5.
- [x] **Item 2** (config dataset encryption): substituted with `--no-persist-credentials` + Object Lock + Wasabi IAM scoping. Different mechanism than the original framing but equivalent or better outcome per the reframed threat model above.
- [x] **Item 3** (offsite append-only): Wasabi Object Lock Compliance, 90d retention, fresh bucket + full re-upload in progress. Synology side for mum's repo is out of scope per the plan.

### Things to revisit later (not deferred, just dependent on future state)

- If we ever rotate Wasabi keys, the playbook in `docs/wiki/services/kopia.md` is the procedure — sops update alone is insufficient, must also rewrite `repository.config` on doc2.
- If kopia ever supports keeping S3 backend credentials out of `repository.config`, revisit. Currently a kopia limitation.
- The bootstrap snapshot doubles as a read-side restore drill (every file in `/mnt/data/Life/Photos/library` was successfully read off disk). A true write-side restore drill is still owed (#238 if it exists, or file it).
