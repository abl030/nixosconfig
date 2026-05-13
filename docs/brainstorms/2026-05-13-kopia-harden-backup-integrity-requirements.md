# Kopia: harden backup integrity (issue #236)

**Date:** 2026-05-13
**Issue:** [#236](https://github.com/abl030/nixosconfig/issues/236)
**Scope:** Standard
**Status:** Decided, executing

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
