---
name: forgejo
description: Create, search, comment on, and manage issues in the canonical nixosconfig Forgejo tracker via its REST API.
version: 1.0.0
metadata:
  hermes:
    tags: [homelab, forgejo, issues, nixosconfig]
---

# Forgejo issue operations

Use this skill whenever the user asks to create or manage an issue for the
canonical `abl030/nixosconfig` Forgejo repository. GitHub is a read-only code
mirror; its issue tracker is not authoritative.

## Access

- API base: `https://git.ablz.au/api/v1`
- Repository: `abl030/nixosconfig`
- Token file: `/run/secrets/forgejo/hermes-token`
- Pre-deploy fallback on doc1: decrypt
  `secrets/hosts/proxmox-vm/forgejo-hermes-token.yaml` with `sops` directly
  into the same short-lived shell variable. Do not write plaintext to disk.
- Token scope: `write:issue` only; Forgejo includes issue reads. It cannot push
  source code.

Never print, interpolate into a URL, or persist the token. Read it into a
short-lived shell variable and send it only in Forgejo's token-authentication
header. Use mode-0600 `mktemp` files for request/response bodies and remove them
with a trap.

## Workflow

1. Search open and closed issues through
   `GET /repos/abl030/nixosconfig/issues?state=all&limit=100` before creating a
   new one. Compare both title and body for the named subsystem and intent.
2. If no duplicate exists, create with
   `POST /repos/abl030/nixosconfig/issues` and JSON fields `title` and `body`.
3. Require HTTP 200 or 201, parse the JSON response, and report the returned
   issue number and `html_url`.
4. Read an issue with `GET /repos/abl030/nixosconfig/issues/{number}`; comment
   with `POST .../comments`; update title/body/state with `PATCH .../{number}`.
5. If Forgejo returns HTTP 403, inspect its JSON `message`. Scope errors are a
   token configuration problem, not evidence that issue operations require the
   web UI.

## Quality bar

Issue bodies should capture motivation, current state, desired invariants,
security boundaries, acceptance criteria, migration/rollback needs, and
verification. Do not prescribe an architecture that has not been inspected;
link to existing NixOS patterns when known.
