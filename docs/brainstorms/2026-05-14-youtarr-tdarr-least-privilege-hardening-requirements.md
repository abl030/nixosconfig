---
date: 2026-05-14
topic: youtarr-tdarr-least-privilege-hardening
---

# Youtarr and Tdarr Least-Privilege Hardening

## Summary

Harden Youtarr and Tdarr in one pass by dropping root as the steady-state workload identity, narrowing each service's mounted paths to the data it actually needs, and preserving the current service workflows. Tdarr keeps iGPU acceleration, but GPU access is treated as a narrowly granted device capability rather than a reason to keep broad root-equivalent access.

---

## Problem Frame

Issue #232 identified Youtarr and Tdarr as remaining Tier 1 findings because both run as UID/GID 0 while holding write access to shared media storage. A compromised container in that shape can do more than break its own app state: it can rewrite, delete, or encrypt media trees outside the service's real job.

Youtarr's database lifecycle has already been isolated from upstream's old bundled MariaDB container, but the application container still runs with root identity and writes directly into its output and app-state directories. Tdarr is a worker node on `igpu`; it needs video library visibility, transcode scratch space, and VAAPI/iGPU access, but the current module gives it the whole media root and root identity.

The confusing part is Tdarr's server/node split. Upstream documentation says mapped nodes need access to source library paths and transcode cache paths, the node creates the transcoded cache file, and the server decides what happens next. That means the least-privilege target is not "node can only see scratch"; it is "node can read source media, write cache, and keep final media writes out of the node unless a concrete flow proves otherwise."

---

## Actors

- A1. Operator or implementation agent: changes the service modules, deploys to the affected hosts, and verifies runtime behavior.
- A2. Youtarr app container: manages YouTube-to-arr application state and writes YouTube output files.
- A3. Tdarr node container: performs transcoding jobs on `igpu` and reports results back to the Tdarr server on tower.
- A4. Tdarr server on tower: owns library orchestration and the final decision about cache output handling.
- A5. Shared media storage: provides Movies, TV Shows, YouTube output, and transcode scratch paths with existing group-based write semantics.

---

## Key Flows

- F1. Youtarr root reduction
  - **Trigger:** Youtarr starts after the hardening deploy.
  - **Actors:** A1, A2, A5
  - **Steps:** the app starts with any upstream-required container init; the steady-state workload runs as a dedicated Youtarr identity; it can write only its app-state directories and YouTube output; it cannot write unrelated media paths.
  - **Outcome:** Youtarr remains operational while a compromised app process has a materially smaller filesystem blast radius.
  - **Covered by:** R1, R2, R3, R4, R5, R6, R7, R8, R9

- F2. Tdarr mapped-node transcode
  - **Trigger:** The Tdarr server assigns a transcode job to the `igpu` node.
  - **Actors:** A1, A3, A4, A5
  - **Steps:** the node reads source media from the configured video library paths; writes intermediate or final transcode artifacts to the shared transcode cache; reports the cache path back to the server; the server handles post-transcode library actions.
  - **Outcome:** Tdarr keeps its current server/node workflow and iGPU acceleration without giving the node broad write access to canonical media.
  - **Covered by:** R1, R2, R3, R4, R5, R10, R11, R12, R13, R14, R15

- F3. Runtime verification
  - **Trigger:** The hardened services are deployed.
  - **Actors:** A1, A2, A3, A4
  - **Steps:** verify each service starts; verify Youtarr can read existing state and write a representative output/state artifact; verify Tdarr connects to the server; verify a VAAPI encoder remains available; verify a transcode can use cache without node-side writes to source media.
  - **Outcome:** The change is proven at runtime, not merely by Nix evaluation.
  - **Covered by:** R9, R14, R16, R17

---

## Requirements

**Shared least-privilege posture**
- R1. Youtarr and Tdarr must both stop running their steady-state workload as UID/GID 0.
- R2. Each service must use a dedicated service identity rather than the operator user's identity.
- R3. Shared media group membership may be used where the existing media filesystem requires it, but only as a scoped compatibility mechanism for required paths.
- R4. Any upstream-required root container initialization is acceptable only if the actual long-running app or node process runs as the dedicated non-root identity.
- R5. The hardening pass must complete the core root and mount-scope reduction for both services in the same work item rather than splitting either service into a follow-up.

**Youtarr**
- R6. Youtarr must keep its current application workflow and external database shape.
- R7. Youtarr must have write access to its app state and YouTube output only.
- R8. Youtarr must not receive write access to unrelated media libraries, transcode scratch, music, downloads, or broader media parent paths.
- R9. Existing Youtarr state and public availability must survive the identity and mount-scope change.

**Tdarr**
- R10. Tdarr must keep the mapped-node model against the existing server on tower.
- R11. Tdarr must retain read access to both Movies and TV Shows because both libraries are in use.
- R12. Tdarr's node must treat source media as read-only unless a verified active flow requires node-side write access.
- R13. Tdarr's node must retain read-write access to transcode scratch/cache because upstream's mapped-node flow writes transcoded outputs there.
- R14. Tdarr must retain VAAPI/iGPU acceleration with the narrowest practical device exposure.
- R15. Tdarr must not receive access to unrelated media areas such as Music, YouTube output, metadata trees, downloads, or broader parent paths.

**Verification and documentation**
- R16. The implementation must include runtime verification after deploy for service health, filesystem permissions, and GPU/transcode behavior.
- R17. The implementation must update the relevant service wiki or inline comments so future agents know why media is read-only for the Tdarr node and why iGPU access does not imply root.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R4.** Given either service has started after deployment, when the long-running workload process is inspected, it is running under that service's dedicated non-root identity rather than UID/GID 0.
- AE2. **Covers R7, R8, R9.** Given Youtarr is running, when it accesses existing app state and writes a normal YouTube output artifact, it succeeds; when the same process attempts to write outside its allowed state/output areas, the filesystem denies it.
- AE3. **Covers R10, R11, R12, R13.** Given Tdarr receives a normal mapped-node job for Movies or TV Shows, when the node reads the source media and writes transcode output to cache, the job can proceed without node-side write permission to the source library.
- AE4. **Covers R14.** Given Tdarr starts on `igpu`, when the encoder probe or representative transcode runs, VAAPI/iGPU support remains available under the non-root service identity.
- AE5. **Covers R15.** Given a compromised Tdarr node process, when it enumerates mounted paths, it cannot see or write unrelated media areas beyond the specific video library paths and transcode cache required for its job.
- AE6. **Covers R16.** Given Nix evaluation and build succeed, when the change is deployed, runtime checks still verify app health, writable paths, denied paths, and GPU/transcode behavior before the work is considered complete.
- AE7. **Covers R17.** Given a future agent reads the service docs or module comments, when they inspect the hardened Tdarr shape, they can see why source media is read-only and why GPU access is not coupled to root identity.

---

## Success Criteria

- Youtarr and Tdarr continue to work normally for their existing workflows.
- A compromise of either container no longer implies root-owned writes across the broad media tree.
- Tdarr keeps hardware transcoding while losing broad filesystem write authority.
- The implementation plan can focus on exact UID/GID mapping, mount options, ownership fixes, and deployment checks without re-opening whether to redesign workflows or split the work.

---

## Scope Boundaries

- Do not redesign the Youtarr workflow.
- Do not redesign Tdarr's server/node workflow.
- Do not move the Tdarr server off tower.
- Do not replace the upstream containers with native NixOS services.
- Do not make this a fleet-wide OCI image governance or digest-pinning project.
- Do not split core Youtarr and Tdarr root/mount hardening into separate follow-up issues.
- Do not require Tdarr node write access to source media unless a current, verified flow proves it is needed.

---

## Key Decisions

- Dedicated service identities over operator identity: service writes should be attributable to the service and should not inherit unrelated operator access.
- Root init is acceptable only as an image constraint: the security target is the long-running workload identity and reachable filesystem/device surface.
- Tdarr media read-only is the default: upstream's mapped-node flow supports a node that reads source media, writes cache, and lets the server handle the post-transcode decision.
- Tdarr keeps both Movies and TV Shows in scope: both libraries are actively used.
- iGPU access is a narrow capability: keep VAAPI working with the smallest device/group exposure that survives verification.
- One combined hardening pass: the issue's no-deferral framing means both services' root and mount blast-radius reductions land together.

---

## Dependencies / Assumptions

- Implementation inspection on 2026-05-14 showed the pinned Youtarr image only uses `YOUTARR_UID` and `YOUTARR_GID` for diagnostics, so Youtarr needs Podman's `--user` control for the actual privilege drop.
- Tdarr's official image needs to start as root for initialization before dropping to its internal workload user.
- Tdarr's mapped-node behavior follows upstream documentation: node reads source media, writes transcode cache, and returns the cache path to the server.
- The existing media filesystem's group-based write model remains in place for this work.
- Runtime verification is required because permission and device hardening can pass Nix builds while failing service behavior.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R1, R2, R3][Technical] Which concrete UID/GID values and host user/group declarations should be used for each service to fit existing file ownership and group-write semantics?
- [Affects R7, R8, R13, R15][Technical] What exact bind mounts and mount modes should be declared so each container sees stable in-container paths while losing unrelated host paths?
- [Affects R14][Technical] Can Tdarr use only the render device on this host, or does it need the broader DRM device directory for the active VAAPI probe and transcode workflow?
- [Affects R16][Technical] What deploy-time commands best prove positive behavior and denied access without damaging media state?
