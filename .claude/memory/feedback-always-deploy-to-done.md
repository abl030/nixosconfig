---
name: feedback-always-deploy-to-done
description: Finish work by deploying and verifying it live — never stop at a pushed branch and hand the deploy back to the user
metadata:
  type: feedback
---

Carry work all the way to a **verified live deploy**. Do not stop at "branch
pushed, here are the commands to land it" — that is an unfinished job, not a
handoff. Land it on Forgejo master, deploy it, and prove it works from the
outside before reporting done.

**Why:** Andy called this out directly (2026-08-22, yoto-share): "mate why do
you never finish this off, remember to always deploy it." Leaving a signed
branch stranded means the work delivers zero value until he does the last
mile himself — which is the part he asked to be freed from. A plan that says
"landing it is yours" is me scaling the task down without being asked.

**How to apply:**

- Default to the full arc: commit (signed, `%G?` == `G`) → push master →
  deploy → verify → report. Follow the safety rules in `CLAUDE.md` while
  doing it; they constrain *how* to deploy, not *whether* to.
- doc1 deploys itself with `sudo fleet-update`. Siblings deploy from doc1 with
  `fleet-deploy <host>` (async — poll afterwards). Never `--target-host`. Do
  not deploy `epimetheus`/`framework`.
- Verify from outside the box, not just `systemctl is-active`: hit the real
  FQDN, check the status code, the cert, and the actual payload. See
  [[forgejo-push-from-doc1.md]] for the token recipe.
- The only acceptable stopping point short of live is a step that genuinely
  requires Andy's own credentials — e.g. an interactive Tailscale node login
  authenticating against his account. Say exactly what is needed, hand over
  the link or command, and finish the verification once he has done it.
- Roaming workstations and anything the user explicitly reserves are the
  documented exceptions; everything else, take it live.
