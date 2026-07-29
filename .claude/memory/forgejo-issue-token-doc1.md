---
name: forgejo-issue-token-doc1
description: "How the doc1 agent administers Forgejo via its persistent all-scope token (sops-encrypted, doc1-only)"
metadata: 
  node_type: memory
  type: project
  originSessionId: d598a222-4ab0-4b23-89dd-e330fdac9177
---

The doc1 agent administers Forgejo through the **Forgejo REST API** using the
`abl030` token `hermes-agent-admin-doc1-20260729` with scope **`all`**. The
operator explicitly authorized this persistent control-plane credential on
2026-07-29. It supersedes and revokes the old `nixbot` `write:issue` token.

Token is stored **sops-encrypted, doc1-scope only** (recipients = doc1 host key
+ editor + break-glass) at `secrets/hosts/proxmox-vm/forgejo-hermes-token.yaml`.
Decrypt + use on doc1 (never echo it):

```sh
cd /home/abl030/nixosconfig
TOKEN=$(env -C "$PWD/secrets" sops -d --extract '["token"]' hosts/proxmox-vm/forgejo-hermes-token.yaml)
curl -s -H "Authorization: token $TOKEN" \
  https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues   # list
# create: POST .../issues  -d '{"title":"…","body":"…"}'   (Content-Type: application/json)
```

This token can manage issues, pull requests, repositories, users, and instance
administration. Git pushes may continue using the dedicated push token, but API
operations should use this admin token rather than minting ephemeral credentials.

**Revoke** if ever leaked: use the Forgejo admin CLI on doc2 to replace the token,
update the SOPS file, then delete the old `access_token` row while Forgejo is
stopped.

UPDATE 2026-07-23: token file renamed → `secrets/hosts/proxmox-vm/forgejo-hermes-token.yaml`,
also materialized at `/run/secrets/forgejo/hermes-token` (owner `abl030`, mode
`0400`) — verified working. Replaced by the persistent admin token on 2026-07-29.
