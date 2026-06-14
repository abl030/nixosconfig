---
name: hermes-full-operator-posture
description: "User wants Hermes (and agents generally) to be full-prod operators that iterate in front of them, not over-caged proposers"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 95306b3e-5345-417b-b287-ebc21355e81f
---

The user explicitly chose to build the Hermes agent toward a **full operator**
model (deploy + verify the real loop itself, while they watch) over a
propose-only/PR model — *"since you've had an agent iterate in front of you, I
can't go back."* The close-the-loop experience (change → deploy → read logs →
fix → repeat) is the workflow they value most.

**Why:** watching an agent actually run the deploy+verify loop on live infra is
strictly more useful to them than handing over a diff; propose-only feels like a
demo.

**How to apply:** default to *capability with safety via exposure control*, not
blanket lockdown. The pattern they accepted: keep the always-on / public-facing
surface (Telegram gateway) credential-free so it is read-only **by
construction**, and grant full prod creds only to human-present sessions (TUI
launched from the doc1 bastion) via ephemeral SSH-agent forwarding — capability
follows presence, no standing keys on the box. Ask "how do we make this safe to
be powerful," not "how do we restrict it." Don't reflexively over-cage. Relates
to [[forgejo-push-from-doc1]] and the bastion model.
