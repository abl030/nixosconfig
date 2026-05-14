---
title: fix: Harden Youtarr and Tdarr container privileges
type: fix
status: active
date: 2026-05-14
origin: docs/brainstorms/2026-05-14-youtarr-tdarr-least-privilege-hardening-requirements.md
---

# fix: Harden Youtarr and Tdarr container privileges

## Summary

Implement the Youtarr/Tdarr hardening by extending the repo's existing static-user, tmpfiles ownership, and PUID/PGID-style container patterns. The plan changes only the two service modules and their service docs, narrows mounts to the paths each service actually needs, and requires runtime deploy verification for process identity, denied writes, service health, and Tdarr VAAPI behavior.

---

## Problem Frame

Issue #232 identified Youtarr and Tdarr as remaining Tier 1 least-privilege findings: both run their workloads as UID/GID 0 while holding write access to shared media storage. The origin requirements document fixes the scope: no workflow redesign, no native-service rewrite, and no splitting the core hardening into follow-up work.

---

## Requirements

- R1. Youtarr and Tdarr must both stop running their steady-state workload as UID/GID 0.
- R2. Each service must use a dedicated service identity rather than the operator user's identity.
- R3. Shared media group membership may be used where the existing media filesystem requires it, but only as a scoped compatibility mechanism for required paths.
- R4. Any upstream-required root container initialization is acceptable only if the actual long-running app or node process runs as the dedicated non-root identity.
- R5. The hardening pass must complete the core root and mount-scope reduction for both services in the same work item.
- R6. Youtarr must keep its current application workflow and external database shape.
- R7. Youtarr must have write access to its app state and YouTube output only.
- R8. Youtarr must not receive write access to unrelated media libraries, transcode scratch, music, downloads, or broader media parent paths.
- R9. Existing Youtarr state and public availability must survive the identity and mount-scope change.
- R10. Tdarr must keep the mapped-node model against the existing server on tower.
- R11. Tdarr must retain read access to both Movies and TV Shows.
- R12. Tdarr's node must treat source media as read-only unless a verified active flow requires node-side write access.
- R13. Tdarr's node must retain read-write access to transcode scratch/cache.
- R14. Tdarr must retain VAAPI/iGPU acceleration with the narrowest practical device exposure.
- R15. Tdarr must not receive access to unrelated media areas such as Music, YouTube output, metadata trees, downloads, or broader parent paths.
- R16. The implementation must include runtime verification after deploy for service health, filesystem permissions, and GPU/transcode behavior.
- R17. The implementation must update the relevant service wiki or inline comments so future agents know why media is read-only for the Tdarr node and why iGPU access does not imply root.

**Origin actors:** A1 operator/implementation agent, A2 Youtarr app container, A3 Tdarr node container, A4 Tdarr server on tower, A5 shared media storage.

**Origin flows:** F1 Youtarr root reduction, F2 Tdarr mapped-node transcode, F3 runtime verification.

**Origin acceptance examples:** AE1 non-root workload identity, AE2 Youtarr allowed/denied writes, AE3 Tdarr mapped-node read/cache behavior, AE4 Tdarr VAAPI under non-root identity, AE5 Tdarr mounted-path reduction, AE6 runtime verification, AE7 documentation breadcrumb.

---

## Scope Boundaries

- Do not redesign the Youtarr workflow.
- Do not redesign Tdarr's server/node workflow.
- Do not move or change the Tdarr server on tower.
- Do not replace the upstream containers with native NixOS services.
- Do not broaden this into a fleet-wide OCI image governance or digest-pinning project.
- Do not split core Youtarr and Tdarr root/mount hardening into follow-up issues.
- Do not grant Tdarr source-media write access unless current runtime verification proves the existing active flow requires it.

---

## Context & Research

### Relevant Code and Patterns

- `modules/nixos/services/youtarr.nix` currently sets `YOUTARR_UID = "0"` and `YOUTARR_GID = "0"`, mounts only the YouTube output and three app-state directories, and uses an isolated MariaDB helper.
- `modules/nixos/services/tdarr-node.nix` currently sets `PUID = "0"` and `PGID = "0"`, mounts the whole media root, mounts transcode scratch, and passes all of `/dev/dri`.
- `modules/nixos/services/jellyfin.nix` demonstrates the existing OCI pattern of non-root host writes through explicit numeric user/group values and `extraOptions = ["--user=..."]` for containers that can run that way.
- `modules/nixos/services/gotify-server.nix`, `modules/nixos/services/uptime-kuma.nix`, and `modules/nixos/services/overseerr.nix` demonstrate static service users and predictable ownership for virtiofs-backed service state.
- `modules/nixos/services/lidarr.nix` and `modules/nixos/services/slskd.nix` show the current convention of adding service users to `users` only where media write access requires the shared group.
- `docs/wiki/infrastructure/igpu-passthrough.md` records that Jellyfin already uses `/dev/dri/renderD128` natively, while Tdarr currently receives `/dev/dri`.

### Institutional Learnings

- `docs/wiki/infrastructure/media-filesystem.md` explains that the media tree uses mixed tower NFS and prom virtiofs storage, with group-based write semantics on shared media paths.
- `docs/wiki/services/youtarr.md` records the recent Youtarr database extraction and current verification expectations.
- `docs/wiki/services/tdarr-node.md` records that this service is only a node, not the server, and that existing management happens through tower.
- `.claude/rules/nixos-service-modules.md` requires least-privilege auditing for touched services and says service docs should leave breadcrumbs for future agents.

### External References

- Tdarr mapped-node docs say mapped nodes need source-library and transcode-cache access, with path translators or matching paths when server and node differ.
- Tdarr transcode-cache docs say the node writes transcode output to cache and the server handles later copy/replace behavior.
- Tdarr hardware-transcoding docs show VAAPI through `/dev/dri`, with ffmpeg using `renderD128`.
- Youtarr docs expose `YOUTARR_UID` and `YOUTARR_GID`, but pinned-image inspection showed those values are only used for config diagnostics; Podman's `--user` flag is required for the actual privilege boundary.

---

## Key Technical Decisions

- Static service users with explicit numeric identity for both containers: the module should make identity deterministic instead of relying on dynamically assigned system UIDs.
- Keep root init only where the image requires it: Tdarr keeps upstream root init so it can mutate and drop to the internal `Tdarr` user; Youtarr uses Podman `--user` because the pinned image does not perform a privilege drop itself.
- Give Youtarr the shared media group only because YouTube output lives on the existing media filesystem; do not make `users` the primary authority for its app state.
- Give Tdarr the shared media group for transcode cache compatibility and `render`/`video` for GPU access; do not use group membership to justify broad media mounts.
- Mount Tdarr source libraries read-only by default and transcode cache read-write. That follows the mapped-node docs and keeps final source-media writes with the server unless runtime verification proves the active workflow requires otherwise.
- Try narrow GPU device exposure first, with broader `/dev/dri` as a tested fallback. The fallback is acceptable only after preserving non-root workload identity and documenting why the narrower device was insufficient.

---

## Open Questions

### Resolved During Planning

- Concrete identity model: use dedicated static service users/groups with explicit numeric IDs because both affected images need numeric UID/GID settings.
- Youtarr mount shape: keep its current app/output mount set, but change ownership and identity so it cannot rely on root for writes.
- Tdarr mount shape: mount Movies and TV Shows read-only, transcode scratch read-write, and stop mounting the media root parent.
- Tdarr GPU approach: plan for narrow render-node exposure first, with runtime fallback to broader DRM exposure only if VAAPI fails.

### Deferred to Implementation

- Exact UID/GID numbers: implementation must pick unused static IDs that do not collide on the target hosts and then keep them stable in the module.
- Exact Tdarr device minimum: only deployment on `igpu` can prove whether render-node-only access is enough for the active Tdarr image and VAAPI probe.
- Exact safe write-denial probes: implementation should choose harmless test paths or temporary files that prove denied access without modifying real media.

---

## Implementation Units

### U1. Define Dedicated Service Identities

**Goal:** Establish predictable, dedicated non-root identities for Youtarr and Tdarr that can be passed into their containers and used for host-side ownership.

**Requirements:** R1, R2, R3, R4, R5, AE1

**Dependencies:** None

**Files:**
- Modify: `modules/nixos/services/youtarr.nix`
- Modify: `modules/nixos/services/tdarr-node.nix`

**Approach:**
- Add static service users and groups in each module, with explicit numeric UID/GID values chosen to avoid collisions on the affected hosts.
- Keep the service-specific primary group distinct from `users`.
- Add `users` as an extra group only where the service needs to write to the existing shared media filesystem.
- Add `render` and `video` to Tdarr's extra groups so the non-root workload can use the GPU devices exposed to the container.
- Keep identity declarations local to the service modules rather than creating a shared user abstraction; this is two services with different device and media needs.

**Patterns to follow:**
- Static service user pattern in `modules/nixos/services/overseerr.nix`
- Shared media group pattern in `modules/nixos/services/lidarr.nix`
- GPU group pattern in `modules/nixos/services/jellyfin.nix`

**Test scenarios:**
- Evaluation: both modules evaluate with deterministic user/group declarations and without duplicate user or group definitions.
- Happy path: the generated system contains dedicated `youtarr` and `tdarr` identities, and neither workload identity is the operator user.
- Covers AE1. Runtime identity: after deploy, inspecting long-running workload processes shows dedicated non-root identities, not UID/GID 0.

**Verification:**
- The target host configurations evaluate.
- The deployed hosts expose dedicated service users/groups with the expected memberships.

---

### U2. Harden Youtarr Ownership and Mount Authority

**Goal:** Move Youtarr's steady-state workload to the dedicated identity while preserving the existing external database and app workflow.

**Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, AE1, AE2

**Dependencies:** U1

**Files:**
- Modify: `modules/nixos/services/youtarr.nix`
- Modify: `docs/wiki/services/youtarr.md`

**Approach:**
- Replace root UID/GID environment values with the dedicated Youtarr identity for diagnostics, and use Podman's `--user` flag for the actual runtime UID/GID.
- Keep the existing external MariaDB wiring unchanged.
- Keep the current narrow mount set for config, images, jobs, and YouTube output; do not add broader media mounts.
- Change tmpfiles ownership and modes so Youtarr can write its app-state directories as the dedicated identity.
- Account for existing root-owned app-state contents from previous runs; the implementation must include a recursive ownership migration or equivalent tmpfiles rule before the service starts non-root.
- Ensure the YouTube output path remains writable through the existing media group model without making unrelated media paths visible.
- Add or update wiki guidance explaining the non-root identity, allowed writable paths, and runtime verification checks.

**Patterns to follow:**
- Youtarr migration notes in `docs/wiki/services/youtarr.md`
- Static service ownership patterns in `modules/nixos/services/overseerr.nix`
- Existing Youtarr DB restart-trigger pattern in `modules/nixos/services/youtarr.nix`

**Test scenarios:**
- Covers AE1. Runtime identity: Youtarr's long-running process runs as the dedicated Youtarr identity.
- Covers AE2. Happy path: Youtarr starts, connects to the existing external database, loads existing state, and the public health/UI check succeeds.
- Covers AE2. Writable path: a harmless write through the Youtarr process succeeds in its app state and YouTube output locations.
- Ownership migration: existing config/images/jobs contents created before this change are writable by the dedicated Youtarr identity after deploy.
- Covers AE2. Denied path: the Youtarr process cannot write to unrelated media library or transcode scratch paths.
- Regression: `container@youtarr-db.service` dependency and restart trigger behavior remains intact.

**Verification:**
- `nix build` for doc2 succeeds.
- After doc2 deploy, Youtarr and its MariaDB nspawn unit are active.
- Public Youtarr URL returns normally.
- Runtime checks prove allowed writes and denied writes.

---

### U3. Harden Tdarr Mounts and Workload Identity

**Goal:** Move Tdarr's node workload to the dedicated identity and narrow filesystem exposure to video sources plus transcode cache.

**Requirements:** R1, R2, R3, R4, R5, R10, R11, R12, R13, R15, AE1, AE3, AE5

**Dependencies:** U1

**Files:**
- Modify: `modules/nixos/services/tdarr-node.nix`
- Modify: `docs/wiki/services/tdarr-node.md`

**Approach:**
- Replace root PUID/PGID environment values with the dedicated Tdarr identity.
- Account for any existing root-owned config/log contents from prior runs so the dedicated Tdarr identity can keep using the node state after deploy.
- Stop binding the media root parent into the node.
- Bind Movies and TV Shows into stable in-container library paths as read-only.
- Bind transcode scratch/cache as read-write.
- Keep Tdarr's server connection and node identity unchanged.
- Adjust NFS watchdog coverage so it still detects the real source media dependency without requiring the whole media parent to be mounted into the container.
- Update the wiki to explain the mapped-node model: source media read-only, transcode cache read-write, server handles post-cache decisions.

**Patterns to follow:**
- Existing Tdarr service documentation in `docs/wiki/services/tdarr-node.md`
- Media filesystem layout in `docs/wiki/infrastructure/media-filesystem.md`
- OCI volume style in `modules/nixos/services/jdownloader2.nix`

**Test scenarios:**
- Covers AE1. Runtime identity: Tdarr node workload runs as the dedicated Tdarr identity, not UID/GID 0.
- Covers AE3. Happy path: Tdarr node connects to the tower server and can read from both Movies and TV Shows paths.
- Covers AE3. Cache write: Tdarr node can write to transcode scratch/cache as the dedicated identity.
- Ownership migration: existing config/log contents are readable and writable by the dedicated Tdarr identity after deploy.
- Covers AE3 and AE5. Denied source write: Tdarr node cannot modify source media in Movies or TV Shows through its mounted paths.
- Covers AE5. Mounted-path reduction: Tdarr node cannot see unrelated media areas such as Music, YouTube output, metadata trees, downloads, or broader media parent paths.

**Verification:**
- `nix build` for igpu succeeds.
- After igpu deploy, `podman-tdarr-node.service` is active and connected from tower's perspective or logs.
- Runtime mount inspection shows only the intended source and cache paths.
- Allowed cache write and denied source-media write checks pass.

---

### U4. Preserve Tdarr VAAPI With Narrow Device Access

**Goal:** Keep hardware transcoding working while minimizing the device surface granted to the Tdarr node.

**Requirements:** R4, R14, R16, R17, AE4, AE6, AE7

**Dependencies:** U1, U3

**Files:**
- Modify: `modules/nixos/services/tdarr-node.nix`
- Modify: `docs/wiki/services/tdarr-node.md`
- Modify: `docs/wiki/infrastructure/igpu-passthrough.md`

**Approach:**
- Prefer passing only the render device needed for VAAPI.
- Keep the non-root Tdarr identity in the relevant GPU groups.
- If runtime verification shows render-node-only exposure is insufficient for the current image's startup probe or active transcoding path, widen only to the smallest working DRM exposure and document the reason.
- Do not use privileged container mode or root identity as a workaround for GPU access.
- Update docs so future agents understand that iGPU access is a scoped device/group concern, not a root requirement.

**Patterns to follow:**
- Jellyfin's native render-device configuration in `modules/nixos/services/jellyfin.nix`
- iGPU notes in `docs/wiki/infrastructure/igpu-passthrough.md`
- Tdarr node encoder-probe notes in `docs/wiki/services/tdarr-node.md`

**Test scenarios:**
- Covers AE4. Happy path: Tdarr startup logs or a representative job show VAAPI encoders available under the non-root identity.
- Covers AE4. Fallback path: if render-node-only fails, the final wider device exposure is justified by observed runtime behavior and still preserves non-root workload identity.
- Covers AE6. Integration: a representative Tdarr transcode uses the GPU and writes output to cache without source-media write access.
- Covers AE7. Documentation: service docs explain the final device exposure and why it is the minimum verified shape.

**Verification:**
- igpu deploy leaves `/dev/dri` health intact.
- Tdarr encoder probe retains the expected hardware-encoding signal.
- Docs reflect the final verified device exposure.

---

### U5. Deploy, Verify, and Close the Issue Ledger

**Goal:** Prove the hardening in production-like runtime and update issue #232 with what changed.

**Requirements:** R5, R9, R14, R16, R17, AE1, AE2, AE3, AE4, AE5, AE6, AE7

**Dependencies:** U2, U3, U4

**Files:**
- Modify: `docs/wiki/services/youtarr.md`
- Modify: `docs/wiki/services/tdarr-node.md`
- Modify: `docs/wiki/infrastructure/igpu-passthrough.md`

**Approach:**
- Build affected host configurations before deploy.
- Deploy doc2 for Youtarr and igpu for Tdarr following the repo's remote-deploy rules.
- Verify service health, process identity, allowed writes, denied writes, Tdarr server connection, and VAAPI behavior.
- Record evidence in the relevant wiki docs and in issue #232.
- If a runtime fallback is needed for Tdarr device exposure, keep it inside this same work item and document the observed reason.

**Patterns to follow:**
- Deployment rules in `AGENTS.md`
- Youtarr migration verification style in `docs/wiki/services/youtarr.md`
- Tdarr operational checks in `docs/wiki/services/tdarr-node.md`

**Test scenarios:**
- Covers AE6. Build verification: doc2 and igpu system builds succeed before deploy.
- Covers AE1. Runtime verification: both services' long-running workloads are non-root after deploy.
- Covers AE2. Youtarr verification: existing state loads, public URL works, allowed writes work, denied writes fail.
- Covers AE3 and AE5. Tdarr filesystem verification: source reads and cache writes work while source writes and unrelated path access fail.
- Covers AE4. Tdarr GPU verification: VAAPI hardware encoding remains available after hardening.
- Covers AE7. Documentation verification: issue/wiki handoff records what was hardened and any remaining constraints.

**Verification:**
- No failed units on doc2 or igpu related to these services.
- Issue #232 has an update that marks the Youtarr/Tdarr UID-0 media-container item as handled with evidence.
- Working tree includes docs that match the deployed behavior.

---

## System-Wide Impact

- **Interaction graph:** Youtarr remains on doc2 with its MariaDB nspawn dependency; Tdarr remains a node on igpu connecting to the tower server.
- **Error propagation:** Permission errors should surface as service startup/log failures or denied write probes during deploy verification, not as silent acceptance.
- **State lifecycle risks:** Ownership changes can make existing app-state directories temporarily unwritable if tmpfiles ownership is wrong; plan units explicitly sequence identity before ownership and runtime checks.
- **API surface parity:** Public URLs and service ports remain unchanged.
- **Integration coverage:** Builds alone are insufficient; deploy verification must prove process identity, filesystem access, and GPU behavior.
- **Unchanged invariants:** Youtarr's external database shape, Tdarr's mapped-node workflow, and tower's server ownership stay unchanged.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Static UID/GID collision on a target host | Pick unused explicit IDs during implementation and verify with target host user/group database before deploy. |
| Youtarr image changes its startup model later | Current pinned image does not need root init and does not drop privileges itself, so use Podman's `--user`; re-inspect the entrypoint if the digest changes. |
| Existing service state contains root-owned files from prior runs | Include an explicit ownership migration or recursive tmpfiles rule for service-owned state before expecting non-root writes to succeed. |
| Tdarr image expects broader `/dev/dri` than render-node-only | Try the narrow device first; if runtime proof fails, widen only to the smallest working DRM exposure and document the evidence. |
| Tdarr active flow unexpectedly needs node-side source-media writes | Treat read-only source media as the default; if a real active flow fails specifically because of source writes, resolve it in this same work item rather than deferring. |
| Permission probes accidentally modify real media | Use harmless temporary test artifacts or dry-run checks chosen during implementation and record exactly what was tested. |

---

## Documentation / Operational Notes

- Update `docs/wiki/services/youtarr.md` with the final non-root identity, writable paths, and verification evidence.
- Update `docs/wiki/services/tdarr-node.md` with the final mount layout, source-media read-only rationale, transcode cache write behavior, and device exposure.
- Update `docs/wiki/infrastructure/igpu-passthrough.md` if Tdarr's GPU device exposure changes.
- Add an issue #232 comment with deployment date, hosts, process identity evidence, allowed/denied write evidence, and Tdarr VAAPI status.

---

## Sources & References

- **Origin document:** [docs/brainstorms/2026-05-14-youtarr-tdarr-least-privilege-hardening-requirements.md](../brainstorms/2026-05-14-youtarr-tdarr-least-privilege-hardening-requirements.md)
- Related issue: #232
- Related code: `modules/nixos/services/youtarr.nix`
- Related code: `modules/nixos/services/tdarr-node.nix`
- Related docs: `docs/wiki/services/youtarr.md`
- Related docs: `docs/wiki/services/tdarr-node.md`
- Related docs: `docs/wiki/infrastructure/igpu-passthrough.md`
- Related docs: `docs/wiki/infrastructure/media-filesystem.md`
- Tdarr docs: https://docs.tdarr.io/docs/nodes/nodes/
- Tdarr docs: https://docs.tdarr.io/docs/library-setup/transcode-cache/
- Tdarr docs: https://docs.tdarr.io/docs/installation/docker/hardware-transcoding/
- Youtarr docs: https://github.com/DialmasterOrg/Youtarr/blob/main/docs/ENVIRONMENT_VARIABLES.md
