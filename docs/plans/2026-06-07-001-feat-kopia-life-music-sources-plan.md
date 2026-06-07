---
title: "feat: widen kopia backup coverage — /Life and beets music sources"
type: feat
status: completed
date: 2026-06-07
origin: docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md
---

# feat: widen kopia backup coverage — /Life and beets music sources

## Summary

Add two kopia sources — `/mnt/data/Life` to the **existing** Wasabi photos repo (immutable, excluding the photo subdirs already covered plus the high-churn Unraid USB dir) and `/mnt/virtio/Music` to the Synology mum repo — and give the kopia module the per-source exclude capability it lacks today. No new bucket, key, or kopia instance.

## Problem Frame

Irreplaceable `/mnt/data/Life` data has only the single Synology copy; the curated ~495 GiB beets library has no offsite at all (origin: `docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md`). The photo library already lives immutably in the `kopiaphotos` repo, so adding `/Life` as a source **to that same repo** dedupes against the existing photo blobs — nothing re-uploads and no fresh 90-day Object Lock is incurred.

---

## Requirements

### Wasabi `/Life`
R1. `/mnt/data/Life` is backed up into the existing `kopia-photos` repo (Wasabi, 90-day Object Lock).
R2. The `/Life` source excludes `Photos/{library,thumbs,encoded-video,upload}` and `Tech/Backups/UnraidUSB`; it keeps `Photos/backups` (immich DB dumps) and everything else.
R3. The existing photo library is not re-uploaded (same-repo dedup + exclusion).

### Music
R4. `/mnt/virtio/Music` is backed up to `kopia-mum` (Synology only); the slskd `music/` tree is never added.
R5. `kopia-mum` waits for the `/mnt/virtio` mount before running.

### Module capability
R6. The kopia module supports per-source exclude rules (kopia `files.ignore` policy).

### Closeout
R7. #237 is closed — forgejo dumps confirmed present via `kopia source list`.

---

## Key Technical Decisions

- **Add `/Life` to the existing `kopia-photos` repo — not a new repo/bucket/instance.** A kopia repository dedupes by content, so the 314 GiB library never re-uploads and gets no fresh 90-day lock or cost. A separate repository (even in the same Wasabi bucket) has its own content store and *would* re-upload — that is the trap being avoided. (see origin)
- **Per-source excludes via a new `sourceExcludes` attrset (source path → ignore rules); the reconciler sets that source's `files.ignore` policy.** Must be per-source, not per-instance: `kopia-photos` will have multiple sources with different needs (the `library` source takes no excludes; the `/Life` source does). Keep `sources` a plain string list — `sourceExcludes` is additive and non-breaking.
- **Exclude the regenerable/duplicate Photos subdirs + `UnraidUSB` from `/Life`; keep `Photos/backups`.** The library is already covered by its own source; `thumbs`/`encoded-video`/`upload` are immich-regenerable; `UnraidUSB` is a high-churn backup-of-a-backup. The immich DB dump (`Photos/backups`) rides the `/Life` source into Wasabi.
- **Music goes to `kopia-mum` only.** Re-downloadable; per-GB Wasabi cost isn't worth it; Synology is sufficient. `mountDepsFor` gains a `/mnt/virtio` → `mnt-virtio.mount` mapping (the `RequiresMountsFor` → `mnt-virtio.mount` pattern other doc2 services already use). #267 (done) keeps the 100k-file walk from re-triggering virtiofsd ENFILE.
- **Keep the existing 39 GiB `Media/Music` source on `kopia-mum`.** A distinct small set; removing it risks coverage loss for no benefit.

---

## High-Level Technical Design

Source layout after this change (one Wasabi bucket, one Synology repo — only the sources change):

| Repo (instance) | Destination | Sources after change |
|---|---|---|
| `kopia-photos` | Wasabi `kopiaphotos` (90d Object Lock) | `…/Photos/library` *(unchanged)* · **`/mnt/data/Life`** *(new — excludes `Photos/{library,thumbs,encoded-video,upload}`, `Tech/Backups/UnraidUSB`)* |
| `kopia-mum` | Synology (Tailscale NFS) | `/mnt/data/Life`, `Media/Books`, `Media/Music` (39 GiB), `/mnt/backup/pfsense` *(all unchanged)* · **`/mnt/virtio/Music`** *(new)* |

`Photos/backups` (immich DB) and `Photos/profile` are not excluded, so they ride the new `/Life` source into Wasabi.

---

## Implementation Units

### U1. kopia module: per-source exclude (`sourceExcludes`)

**Goal:** let a source carry kopia ignore rules, applied by the reconciler.
**Requirements:** R6 (enables R1, R2).
**Dependencies:** none.
**Files:** `modules/nixos/services/kopia.nix`
**Approach:** add `sourceExcludes` to `instanceModule` as `attrsOf (listOf str)`, default `{}` — maps a source path to gitignore-style kopia ignore rules (a leading `/` anchors to the source root). Extend `mkSourceSyncScript`'s `set_policy()` so that when a source path is a key in `sourceExcludes`, the policy PUT body includes the source's `files.ignore` rules alongside the existing `scheduling`. Add `sourceExcludes` to the unit's `restartTriggers` so a rules change re-runs the reconcile. Keep everything idempotent.
**Patterns to follow:** the existing `set_policy()` PUT to `/api/v1/policy`; existing `instanceModule` option declarations; the `restartTriggers` JSON block.
**Technical design (directional, not spec):** the policy body gains a `files` block when the source has excludes, e.g. `{"scheduling":{…},"files":{"ignore":["/Photos/library", …]}}`. Confirm the exact kopia policy field (`files.ignore` vs `files.ignoreRules`) against `kopia policy show --json` / the API before wiring.
**Test scenarios:**
- Covers R6. `nix flake check` passes with an instance that sets `sourceExcludes`; the generated source-sync script embeds the ignore rules for the matching source path only.
- A source absent from `sourceExcludes` produces no `files.ignore` (the `library` source is untouched).
- Reconcile is idempotent: re-running with unchanged `sourceExcludes` issues the same PUT; changing the rules re-fires via `restartTriggers`.
- Test expectation: policy contents verified operationally post-deploy via `kopia policy show` (repo has no unit-test suite; validation is `nix flake check` + runtime checks).
**Verification:** `nix flake check` green; after deploy, `kopia policy show root@kopia:/mnt/data/Life` lists the ignore rules and the `library` source's policy is unchanged.
**Execution note:** this is the one feature-bearing change — confirm the kopia policy JSON shape before wiring the PUT.

### U2. kopia module: `/mnt/virtio` mount dependency

**Goal:** a kopia instance with a `/mnt/virtio` source waits for `mnt-virtio.mount`.
**Requirements:** R5.
**Dependencies:** none.
**Files:** `modules/nixos/services/kopia.nix`
**Approach:** extend `mountDepsFor` to map a `/mnt/virtio` prefix → `"mnt-virtio.mount"`, alongside the existing `/mnt/data` and `/mnt/mum` handling. The `Music` tree is an announced virtiofs submount under `/mnt/virtio`, so a dependency on `mnt-virtio.mount` is sufficient.
**Patterns to follow:** the existing `mountDepsFor` `lib.optional` pattern; `mnt-virtio.mount` deps in `forgejo.nix` / `mealie.nix` etc.
**Test scenarios:**
- `nix` eval: an instance with a `/mnt/virtio` source emits `After`/`Requires` on `mnt-virtio.mount`; existing `/mnt/data` and `/mnt/mum` deps are unchanged.
- Test expectation: verified post-deploy via `systemctl show kopia-mum -p After -p Requires`.
**Verification:** `kopia-mum` lists `mnt-virtio.mount` in `After`/`Requires` after deploy.

### U3. doc2: add `/Life` source to `kopia-photos`

**Goal:** back up `/mnt/data/Life` into the photos repo with the right excludes.
**Requirements:** R1, R2, R3.
**Dependencies:** U1.
**Files:** `hosts/doc2/configuration.nix`
**Approach:** in `homelab.services.kopia.instances.photos`, add `"/mnt/data/Life"` to `sources` and set `sourceExcludes = { "/mnt/data/Life" = ["/Photos/library" "/Photos/thumbs" "/Photos/encoded-video" "/Photos/upload" "/Tech/Backups/UnraidUSB"]; }`. Leave the existing `…/Photos/library` source as-is.
**Patterns to follow:** the existing `photos` instance block in `hosts/doc2/configuration.nix`.
**Test scenarios:**
- Covers R1, R2. After deploy, `kopia source list` (photos repo) shows `/mnt/data/Life`; a snapshot contains a non-photo file (e.g. a forgejo dump, an `immich-db-backup-*.sql.gz`) and the excluded paths (`Photos/library`, `Tech/Backups/UnraidUSB`) are absent from the snapshot tree.
- Covers R3. The first `/Life` snapshot uploads only the non-photo delta (kopia dedup) — repo/bucket size grows by roughly the non-photo `/Life` size, not +314 GiB. Confirm via kopia snapshot stats / Wasabi usage.
- Test expectation: operational verification (no unit tests).
**Verification:** `/Life` snapshot lands; library blobs not re-uploaded; excluded paths absent.

### U4. doc2: add `/mnt/virtio/Music` source to `kopia-mum`

**Goal:** back up the beets library to Synology.
**Requirements:** R4.
**Dependencies:** U2; #267 (done).
**Files:** `hosts/doc2/configuration.nix`
**Approach:** add `"/mnt/virtio/Music"` to `homelab.services.kopia.instances.mum.sources`. No excludes (whole tree). Leave existing sources, including the 39 GiB `/mnt/data/Media/Music`, in place.
**Patterns to follow:** the existing `mum` instance block.
**Test scenarios:**
- Covers R4. After deploy, `kopia source list` (mum repo) shows `/mnt/virtio/Music`; a snapshot lands a representative beets album.
- The ~100k-file walk completes with no `Too many open files` in journald and doc2's containers virtiofsd fd count stays low during the run (relies on #267).
- Test expectation: operational verification.
**Verification:** `/mnt/virtio/Music` snapshot lands; no ENFILE during the run.

### U5. Verify and close #237

**Goal:** confirm forgejo dumps are captured and close the issue.
**Requirements:** R7.
**Dependencies:** U3.
**Files:** none (operational).
**Approach:** run `kopia source list` on both `mum` (already covers `/mnt/data/Life`) and `photos` (the new `/Life` source covers `…/Life/Andy/Code/forgejo-dumps`); confirm a recent snapshot contains a dump file; comment the evidence on #237 and close it.
**Test expectation:** none — verification unit.
**Verification:** #237 acceptance boxes checked; issue closed.

---

## Scope Boundaries

**Not in scope:**
- New Wasabi bucket / key / kopia instance — unnecessary; same-repo dedup is the whole point.
- The slskd `music/` tree — transient and re-downloadable, and must not be deleted (cratedigger + Soulseek share).
- `/mnt/virtio` service-state offsite — deferred to ZFS-receiver + PBS (#268).

**Deferred to follow-up work:**
- Generalising the module's hardcoded `mum`/`photos` `errorPatterns` to per-instance generation — only needed if a future S3 instance is added, which this plan deliberately avoids.
- Optional slskd concurrency cap as #267 defense-in-depth.

---

## Risks & Dependencies

- **kopia policy ignore JSON shape (U1):** confirm `files.ignore` vs `files.ignoreRules` via `kopia policy show --json` / the API before wiring; a wrong field name silently no-ops the excludes.
- **Exclude anchoring:** rules are anchored to the source root; a wrong anchor over- or under-excludes. Verify against the first `/Life` snapshot tree (`kopia snapshot list` / browse).
- **#267 must be live for U4** (done and verified 2026-06-07) — otherwise the Music walk re-triggers virtiofsd ENFILE across doc2 services.
- **Deploy path:** doc2 builds from GitHub — push, then `ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"`; the existing reconciler registers the new sources + policies on rebuild.

---

## Sources / Research

- origin: `docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md`
- `modules/nixos/services/kopia.nix` — `instanceModule`, `mkSourceSyncScript` reconciler (`set_policy`/`trigger_upload`), `mountDepsFor`, static `errorPatterns`
- `hosts/doc2/configuration.nix` — `photos` and `mum` instance blocks
- `docs/wiki/services/kopia.md` — repo/bucket model, Object Lock, declarative source registration (#254/#255)
- `docs/wiki/infrastructure/virtiofsd-fd-exhaustion.md` — #267, the Music-walk prerequisite
- Verified this session: no exclude mechanism exists in `kopia.nix`; `mnt-virtio.mount` is the established dep pattern; `errorPatterns` is a static `mum`/`photos` list.
