---
date: 2026-05-14
topic: tailscale-share-boundary-hardening
---

# tailscaleShare Boundary Hardening

## Summary

Preserve `tailscaleShare` as the owned inter-tailnet pinhole pattern while hardening the boundary between its Tailscale and Caddy sidecars. The work should fix the verified shared-loopback Caddy admin exposure and reduce Caddy's runtime authority without replacing the module's domain, certificate, or per-service sharing model.

---

## Problem Frame

`tailscaleShare` exists to share one specific service across tailnets without exposing the host proxy, the whole VM, or unrelated services. It gives each shared application its own Tailscale node identity, FQDN, Cloudflare DNS record, and Caddy-managed certificate. That shape is itself a least-privilege access boundary.

Issue #232 originally described the Tier 2 risk as Caddy inheriting `NET_ADMIN` from the Tailscale sidecar. Runtime verification on 2026-05-14 corrected that premise: only the `ts-*` containers have `CAP_NET_ADMIN`; the `caddy-*` containers do not. The remaining verified risk is that Caddy shares the Tailscale sidecar's network namespace, so the Tailscale container can reach Caddy's unauthenticated localhost admin API over shared loopback. Caddy also runs as root with default container capabilities and no `no-new-privileges`.

---

## Actors

- A1. Operator: wants controlled inter-tailnet service sharing through owned DNS and certificate automation.
- A2. Shared-service user: reaches one specific exposed service from another tailnet.
- A3. Tailscale sidecar: owns the per-service Tailscale node identity and tailnet connectivity.
- A4. Caddy sidecar: terminates HTTPS for the service FQDN and reverse-proxies to the local upstream.
- A5. Upstream service: the single application being exposed by an instance, such as Overseerr or Jellyfin.
- A6. Implementation agent: changes the module, deploys to affected hosts, and verifies runtime behavior.

---

## Key Flows

- F1. Inter-tailnet service access
  - **Trigger:** A shared-service user opens the service FQDN from another tailnet.
  - **Actors:** A2, A3, A4, A5
  - **Steps:** traffic reaches the dedicated Tailscale node for that instance; Caddy serves the owned certificate for the FQDN; Caddy reverse-proxies only to the configured upstream service.
  - **Outcome:** the user reaches exactly the intended service, not the host proxy or unrelated services.
  - **Covered by:** R1, R2, R3, R4

- F2. Tailscale sidecar compromise containment
  - **Trigger:** the Tailscale sidecar is compromised or behaves unexpectedly.
  - **Actors:** A3, A4, A5
  - **Steps:** the sidecar retains only the authority required for tailnet connectivity; it cannot use shared loopback to reconfigure Caddy; it cannot read Caddy's certificate, config, or Cloudflare material through mounts or environment.
  - **Outcome:** compromise of the Tailscale node does not automatically become control over the HTTPS reverse proxy or its secrets.
  - **Covered by:** R5, R6, R7, R8, R9

- F3. Caddy sidecar compromise containment
  - **Trigger:** the Caddy sidecar is compromised or the image gains unexpected behavior.
  - **Actors:** A3, A4, A5
  - **Steps:** Caddy has only the secrets and mounts it needs for TLS/proxying; it cannot read Tailscale auth keys or state; it runs with reduced process authority where the image permits.
  - **Outcome:** compromise of Caddy does not automatically become control over the Tailscale node or host-level networking.
  - **Covered by:** R5, R7, R8, R10, R11

- F4. Runtime verification
  - **Trigger:** the hardened module is deployed to hosts with active shares.
  - **Actors:** A1, A3, A4, A5, A6
  - **Steps:** verify both active instances still serve their FQDNs; inspect capabilities, process identity, namespace sharing, mounts, environment separation, Caddy admin reachability, and upstream reachability.
  - **Outcome:** the hardening is proven in the running containers rather than inferred from Nix evaluation alone.
  - **Covered by:** R12, R13, R14

---

## Requirements

**Pinhole behavior**
- R1. `tailscaleShare` must continue to expose one configured upstream service per instance, not a host-wide reverse proxy or the whole VM.
- R2. Each instance must keep its dedicated Tailscale node identity and FQDN.
- R3. Each instance must keep the repo-owned certificate and DNS automation model.
- R4. Existing active shares for Overseerr on doc2 and Jellyfin on igpu must remain externally reachable after hardening.

**Sidecar boundary**
- R5. The requirements and issue language must treat the verified risk as shared-loopback Caddy admin exposure plus weak Caddy runtime hardening, not as inherited `NET_ADMIN`.
- R6. The Tailscale sidecar must not be able to reconfigure Caddy through Caddy's localhost admin API.
- R7. Tailscale and Caddy sidecars must keep separate state, secret, and mount authority.
- R8. The Tailscale sidecar must not gain Caddy's Cloudflare token, Caddy data, Caddy config, or certificates through normal mounts or environment.
- R9. The Caddy sidecar must not gain Tailscale auth keys, Tailscale state, or Tailscale control sockets through normal mounts or environment.

**Runtime authority**
- R10. Caddy must run with the smallest practical capability set for HTTPS reverse proxying inside the current sharing model.
- R11. Caddy must avoid root and privilege escalation where the active image and bind-port needs permit it.
- R12. Tailscale may keep the capabilities required for the dedicated tailnet node, but those capabilities must remain scoped to the Tailscale sidecar.

**Verification and documentation**
- R13. Deployment verification must cover every active `tailscaleShare` instance, currently Overseerr on doc2 and Jellyfin on igpu.
- R14. Verification must prove service reachability, Caddy admin API non-reachability from the Tailscale sidecar, capability posture, `no-new-privileges` posture, process identity, mount separation, and secret separation.
- R15. Service-module rules and issue #232 must be updated so future agents understand the corrected finding and the intended hardening model.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3, R4.** Given the hardened module is deployed, when a user opens the Overseerr or Jellyfin share FQDN from an allowed tailnet, the intended service still responds through the dedicated per-service share.
- AE2. **Covers R5, R6.** Given the hardened module is deployed, when the Tailscale sidecar attempts to reach Caddy's local admin interface over shared loopback, the request cannot read or mutate Caddy configuration.
- AE3. **Covers R7, R8, R9.** Given either sidecar is inspected at runtime, when mounts and environment are checked, each sidecar only has its own state and secret material.
- AE4. **Covers R10, R11, R12.** Given the hardened containers are running, when process capabilities, `no-new-privileges`, and user identity are inspected, Caddy has reduced runtime authority while the Tailscale sidecar keeps only the authority needed for tailnet operation.
- AE5. **Covers R13, R14.** Given both active hosts are deployed, when verification is run on doc2 and igpu, the evidence covers reachability, admin API exposure, capabilities, identities, mounts, environment, and service health for each active instance.
- AE6. **Covers R15.** Given a future agent reads issue #232 or the service-module rules, when they inspect the Tier 2 item, they see the corrected shared-loopback/admin-API risk rather than the disproven inherited-capability claim.

---

## Success Criteria

- The inter-tailnet sharing value remains intact: one service, one FQDN, owned certificate automation, and no whole-host proxy exposure.
- The verified Tailscale-to-Caddy admin API pivot is removed or made non-useful.
- Caddy's runtime authority is materially reduced without breaking HTTPS proxying.
- Runtime evidence exists for both active instances and is recorded where future agents will find it.
- Planning can proceed without re-litigating whether to replace `tailscaleShare` with a different exposure pattern.

---

## Scope Boundaries

- Do not replace `tailscaleShare` with Tailscale Serve, Tailscale Funnel, or another exposure product.
- Do not expose the host proxy or the whole VM over Tailscale.
- Do not remove Caddy, Cloudflare DNS challenge, owned FQDNs, or repo-managed certificate plumbing.
- Do not combine this with the separate Tier 4 image-pinning work for `tailscale:latest` or `caddy-cloudflare:latest`.
- Do not redesign individual upstream services such as Overseerr or Jellyfin.
- Do not grant Caddy access to Tailscale state as a shortcut.
- Do not grant Tailscale access to Caddy state or Cloudflare material as a shortcut.

---

## Key Decisions

- Preserve the current module shape: the per-service Tailscale node plus Caddy proxy is the desired least-privilege access pattern.
- Correct the finding before fixing it: runtime verification disproved inherited `NET_ADMIN`, so the work targets shared-loopback Caddy admin access and Caddy runtime authority instead.
- Keep Tailscale and Caddy as separate trust domains even when they share a network namespace.
- Verify on all active instances because the module is shared and both doc2 and igpu currently depend on it.

---

## Dependencies / Assumptions

- The active Caddy image can proxy the configured services with Caddy admin disabled or otherwise inaccessible from the Tailscale sidecar.
- The active Caddy image can tolerate reduced capabilities and `no-new-privileges`; if not, planning must identify the smallest justified exception.
- The Tailscale sidecar still needs tailnet-node privileges for the current container shape.
- Existing DNS records, auth keys, and certificate state should be preserved through the hardening.

---

## Outstanding Questions

### Deferred to Planning

- [Affects R6][Technical] What is the smallest Caddy admin posture that blocks sidecar-to-admin control while preserving normal startup, reload, and certificate behavior?
- [Affects R10, R11][Technical] Which exact Caddy runtime user, capability, and privilege-escalation settings work with the active image and ports?
- [Affects R12][Technical] Can the Tailscale sidecar itself be reduced further, or is the current tailnet-node authority the minimum practical shape for this module?
