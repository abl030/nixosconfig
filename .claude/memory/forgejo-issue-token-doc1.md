---
name: forgejo-issue-token-doc1
description: "How the doc1 agent administers Forgejo via its persistent all-scope token (sops-encrypted, doc1-only)"
metadata: 
  node_type: memory
  type: project
  originSessionId: d598a222-4ab0-4b23-89dd-e330fdac9177
---

The doc1 agent administers Forgejo through the **Forgejo REST API** using the
persistent `abl030` all-scope control-plane token. The operator-authorized
credential is stored **sops-encrypted, doc1-scope only** at
`secrets/hosts/proxmox-vm/forgejo-hermes-token.yaml`.

Use the checked-in boundary on doc1 (never echo or assign the token):

```sh
cd /home/abl030/nixosconfig
./scripts/forgejo-auth.sh rest \
  --token-file /run/secrets/forgejo/hermes-token \
  --method GET \
  --url "https://git.ablz.au/api/v1/repos/abl030/nixosconfig/issues"
```

The boundary rejects non-Forgejo API URLs before opening the token file, keeps
the token out of argv and curl debug output, and removes trace settings from the
short-lived child. For JSON mutations, pipe the body to `--body-stdin` or use
`--body`; neither mode accepts or needs the token as an argument.

This token can manage issues, pull requests, repositories, users, and instance
administration. Git pushes may continue using the dedicated push token, but API
operations should use this admin token rather than minting ephemeral credentials.

**Revoke** if ever leaked: use the Forgejo admin CLI on doc2 to replace the token,
update the SOPS file, then delete the old `access_token` row while Forgejo is
stopped.

UPDATE 2026-07-23: token file renamed → `secrets/hosts/proxmox-vm/forgejo-hermes-token.yaml`,
also materialized at `/run/secrets/forgejo/hermes-token` (owner `abl030`, mode
`0400`) — verified working. Replaced by the persistent admin token on 2026-07-29.
