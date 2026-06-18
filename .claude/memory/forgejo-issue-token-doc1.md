---
name: forgejo-issue-token-doc1
description: "How the doc1 agent files/edits Forgejo issues via a scoped nixbot write:issue token (sops-encrypted, doc1-only)"
metadata: 
  node_type: memory
  type: project
  originSessionId: d598a222-4ab0-4b23-89dd-e330fdac9177
---

The doc1 agent can create/edit Forgejo issues via the **Forgejo REST API** using a
scoped `nixbot` token (name `claude-agent-doc1`, scope **`write:issue`** only —
no code push, no admin). Minted 2026-06-18 (owner-authorised) via the forgejo
admin CLI on doc2. Issues authored as `nixbot`.

Token is stored **sops-encrypted, doc1-scope only** (recipients = doc1 host key
+ editor + break-glass) at `secrets/hosts/proxmox-vm/forgejo-claude-token.yaml`.
Decrypt + use on doc1 (never echo it):

```sh
cd /home/abl030/nixosconfig
TOKEN=$(env -C "$PWD/secrets" sops -d --extract '["token"]' hosts/proxmox-vm/forgejo-claude-token.yaml)
curl -s -H "Authorization: token $TOKEN" \
  https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues   # list
# create: POST .../issues  -d '{"title":"…","body":"…"}'   (Content-Type: application/json)
```

Why scoped this way: the push token ([[forgejo-push-from-doc1]]) is
`write:repository` only and gets 403 on issue endpoints; this token is the
inverse — issues only, no code. Forgejo PAT scopes are **per-category, not
per-repo**, so the repo boundary comes from `nixbot` being a collaborator on
nixosconfig only (not from the scope). Pushing code still uses the push-token
header trick, not this token.

**Revoke** if ever leaked: Forgejo web UI → nixbot → Settings → Applications →
delete the `claude-agent-doc1` token (or re-mint via `forgejo admin user
generate-access-token` on doc2 and re-key the sops file). Leak blast radius =
create/edit issues on nixosconfig — nothing else.
