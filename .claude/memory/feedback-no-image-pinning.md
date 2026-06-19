---
name: feedback-no-image-pinning
description: Never pin container image tags — auto-updates on everything is a hard line
metadata: 
  node_type: memory
  type: feedback
  originSessionId: a634fa58-2bc4-4ebd-a441-bb59a7d3bc4b
---

NEVER pin container images (no `@sha256:` digests, no frozen version tags). The
user wants `:latest` + auto-pull/auto-update on **every** container, fleet-wide.
This is an explicit, non-negotiable line — do not propose digest-pinning, a
`:latest`/`:master` CI gate, or "review on bumps" workflows again.

**Why:** the user values staying current automatically over the supply-chain
risk that image-pinning would mitigate. They accept that risk knowingly.

**How to apply:** issue #232 TIER-4 ("digest-pin images") and the cross-cutting
"CI check that flags `:latest`/`:master`" item are effectively **WONTFIX** —
record that on the issue, don't reopen the debate. The correct mitigation for
running `:latest` with auto-pull is **runtime hardening** (cap-drop=all +
no-new-privileges + minimal cap-add per container, via
[[`homelab.podman.hardenOptions`]]), NOT pinning. Harden the blast radius of a
compromised auto-pulled image instead of trying to prevent the pull.
