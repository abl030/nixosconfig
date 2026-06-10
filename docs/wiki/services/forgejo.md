# Forgejo

**Date researched:** 2026-06-10
**Status:** active, post-v15 migration verified; Phase D U8 write-root setup landed
**Host:** doc2
**Source module:** `modules/nixos/services/forgejo.nix`
**Related:** #223, #235, #270

Forgejo runs at https://git.ablz.au on doc2. It hosts the private repos
`abl030/books` (beancount ledger) and `abl030/agents`, and — as of 2026-06-10 —
the **public** `abl030/nixosconfig`, which is becoming the signed-fleet-deploys
write root (mirrored to GitHub). See
[signed-fleet-deploys.md](../infrastructure/signed-fleet-deploys.md) and the
**Phase D (U8) Write-Root Setup** section below.

## Runtime

- Package: `forgejo-lts-15.0.2`
- State: `/mnt/virtio/forgejo`
- Repositories: `/mnt/virtio/forgejo/repositories`
- Database: SQLite at `/mnt/virtio/forgejo/data/forgejo.db`
- HTTP: `127.0.0.1:3023`, proxied by nginx as `https://git.ablz.au`
- SSH Git: built-in Forgejo SSH server on `git.ablz.au:2222`
- Dumps: `/mnt/data/Life/Andy/Code/forgejo-dumps`

Instance settings (as of the Phase D U8 setup):

```ini
[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false   # anonymous read for PUBLIC repos only

[repository]
DEFAULT_PRIVATE = private
DEFAULT_PUSH_CREATE_PRIVATE = true
```

`REQUIRE_SIGNIN_VIEW = false` lets anonymous clients fetch **public** repos
(only `nixosconfig`); `books`/`agents` stay private and 404 anonymously, and
`DEFAULT_PRIVATE = private` keeps every new repo private. The git.ablz.au
localProxy also sets `maxBodySize = "0"` so git-over-HTTP push packs (the
full-history seed, large rebases, the dev/bot HTTPS push path) don't hit
nginx's 1m default and HTTP 413.

## Health Checks

Basic service checks:

```sh
ssh doc2 'systemctl is-active forgejo'
curl -fsS https://git.ablz.au/api/healthz
ssh doc2 'sudo ss -ltnp | grep -E ":(3023|2222)"'
```

Run Forgejo doctor from the Forgejo working directory so git does not try to
read the SSH user's inaccessible home:

```sh
ssh doc2 'cfg=/mnt/virtio/forgejo/custom/conf/app.ini
bin=/run/current-system/sw/bin/forgejo
tmp=/mnt/virtio/forgejo/doctor-$(date +%s).log
sudo -u forgejo sh -c "cd /mnt/virtio/forgejo && HOME=/mnt/virtio/forgejo $bin --config $cfg --work-path /mnt/virtio/forgejo --custom-path /mnt/virtio/forgejo/custom doctor check --all --log-file $tmp"'
```

Observed on 2026-06-10 after the unattended v11 to v15 upgrade: doctor exits
0 and the consistency checks pass. The first `Garbage collect LFS` line prints
`ERROR` even though LFS is disabled; later LFS checks explicitly skip and the
command still exits 0.

## Post-v15 Verification

The 2026-06-10 nightly update moved doc2 from Forgejo v11.0.12 to v15.0.2.
Verification performed after the upgrade:

- `https://git.ablz.au/api/healthz` returned 200.
- `forgejo.service` was active and listening on `127.0.0.1:3023` plus `:2222`.
- `abl030/books` and `abl030/agents` existed with `master` refs.
- `git ls-remote ssh://forgejo@git.ablz.au:2222/abl030/agents.git HEAD`
  succeeded from doc1 with the current personal Forgejo SSH key.
- `beancount-pull.service` was successfully fetching `abl030/books` every
  five minutes over `ssh://forgejo@git.ablz.au:2222/abl030/books.git`.
- The Jun 10 dump zip listed successfully and included `app.ini`, repository
  data, and Forgejo state.

Breaking-change review against v12, v13, v14, and v15 release notes found no
current settings fallout:

- v12 removed query-string API auth when `DISABLE_QUERY_AUTH_TOKEN=false`; this
  instance does not set that override.
- v12 OAuth/OIDC issuer changes do not apply; this instance is not currently an
  OAuth provider for fleet services.
- v13 raised the minimum git version to 2.34.1; the running closure has git
  2.54.0.
- v14 validates Forgejo-managed OpenSSH `authorized_keys`; this deployment uses
  Forgejo's built-in SSH server, not a Forgejo-managed OpenSSH key file.
- v15 rootless-container config path changes do not apply to the NixOS service.
- v15 cookie-name changes only require users to log in again.
- v15 repository-scoped access tokens are useful for the future `nixbot` and
  mirror-poller tokens.

Sources:

- https://forgejo.org/2025-07-release-v12-0/
- https://forgejo.org/2025-10-release-v13-0/
- https://forgejo.org/2026-01-release-v14-0/
- https://forgejo.org/2026-04-release-v15-0/
- https://forgejo.org/docs/latest/admin/upgrade/

## Phase D (U8) Write-Root Setup

Landed 2026-06-10. **These objects are Forgejo runtime/DB state, not Nix config**
— only the instance settings (sign-in view, body size) live in
`forgejo.nix`. The repo, accounts, collaborators, branch protection, and tokens
below are reproduced from the Forgejo dump/DB, not the flake. Recreate via the
admin CLI + API if restoring to a fresh instance.

**Repo:** `abl030/nixosconfig`, public, default branch `master`, seeded with the
full history pushed from doc1 (HTTPS, after the `maxBodySize` fix).

**Write-path accounts** (all `--restricted` — they see only repos they are added
to; throwaway random passwords, they auth via token, not password):

| Account | Purpose | Token |
|---|---|---|
| `nixbot` | nightly rolling-flake-update bot push | `nixbot-push` (`write:repository`) → `secrets/hosts/proxmox-vm/forgejo-nixbot-token` |
| `doc1-writer` | interactive dev push from doc1 | per-machine, issued in U9 |
| `epimetheus-writer` | dev push from epimetheus | per-machine, issued in U9 |
| `framework-writer` | dev push from framework | per-machine, issued in U9 |
| `wsl-writer` | dev push from wsl | per-machine, issued in U9 |

All five are **write collaborators** on `nixosconfig`. Personal `abl030` is the
owner but is not used for ordinary pushes.

**Branch protection on `master`:** push restricted to the five writer accounts
(`enable_push_whitelist`); force-push and deletion blocked for everyone (verified:
a nixbot force-push to master is rejected with "branch master is protected from
force push"); `require_signed_commits = false` — signing keys are deliberately
NOT uploaded to Forgejo (auth/signing conflation, forgejo#4268), so host-side
signature verification is the trust control, not Forgejo's "Verified" badge.

Create/manage accounts and tokens with the admin CLI on doc2 (works against the
live SQLite DB):

```sh
fj=/run/current-system/sw/bin/forgejo
run() { sudo -u forgejo env FORGEJO_WORK_DIR=/mnt/virtio/forgejo FORGEJO_CUSTOM=/mnt/virtio/forgejo/custom "$fj" --work-path /mnt/virtio/forgejo "$@"; }
run admin user create --username <name> --email <name>@ablz.au --restricted --random-password --must-change-password=false
run admin user generate-access-token -u <name> -t <token-name> --scopes write:repository --raw   # pipe to sops, never echo
```

Repo/collaborator/branch-protection operations use the API with an admin token.
Mint an ephemeral admin token via `run admin user generate-access-token -u abl030
... --scopes all`, and **revoke it when done** — token-auth cannot delete tokens
(HTTP 401), so revoke by stopping forgejo and deleting the row:
`sqlite3 /mnt/virtio/forgejo/data/forgejo.db "DELETE FROM access_token WHERE id=<n>;"`.

### Deferred (blocked on the GitHub mirror PAT)

These U8 items need the operator-created GitHub machine-user (`abl030-forgejo-mirror`)
and its fine-grained PAT (GitHub does not mint PATs via API):

- Forgejo → GitHub push-mirror (`sync_on_commit`) with the mirror PAT.
- Mirror-health poller on doc2 + its dedicated read-only Forgejo token
  (`secrets/hosts/doc2/forgejo-mirror-poller-token`) — defined once a mirror
  exists to poll.
- GitHub `master` ruleset allowing only `abl030-forgejo-mirror` to update.
- Synthetic propagation test (signed commit → Forgejo → GitHub).

## SSH Keys

Audit keys from the Forgejo database:

```sh
ssh doc2 'sudo -u forgejo sqlite3 /mnt/virtio/forgejo/data/forgejo.db \
  "select public_key.id, user.name, public_key.name, substr(public_key.content,1,80) from public_key left join user on public_key.owner_id = user.id order by user.name, public_key.name;"'
```

Observed keys on 2026-06-10:

| Owner | Key name | Purpose |
|---|---|---|
| deploy key | `doc2-fava-deploy` | beancount/Fava pull path |
| `abl030` | `master-fleet-identity` | current personal SSH access |

Cutover gate: remove or replace `master-fleet-identity` before Forgejo becomes
the `nixosconfig` write root. Uploading the fleet identity to a personal
Forgejo profile grants account-level SSH auth and is not compatible with the
least-privilege cutover model. Do this only after the per-machine HTTPS writer
tokens and signing keys are live, because it can affect current manual SSH
workflows.

Do not upload SSH signing public keys to Forgejo for UI badges. Forgejo treats
uploaded SSH keys as authentication keys.

## Dumps And Restore

Daily dumps land in:

```sh
/mnt/data/Life/Andy/Code/forgejo-dumps
```

List and inspect the latest dump:

```sh
ssh doc2 'latest=$(ls -t /mnt/data/Life/Andy/Code/forgejo-dumps | head -1)
unzip -l /mnt/data/Life/Andy/Code/forgejo-dumps/$latest | sed -n "1,40p"'
```

The dump zip includes `custom/conf/app.ini`, repositories, and Forgejo data.
Treat dumps as credential-bearing secret material. They can include app
secrets today and will include mirror credentials in Forgejo repository state
after the GitHub push mirror is configured. Any restore, dump extraction, or
off-host copy requires mirror PAT rotation before mirror sync is re-enabled.

Restore outline:

1. Stop Forgejo on the restore target.
2. Restore `/mnt/virtio/forgejo` from the VM/ZFS/Kopia source when possible.
3. If using a Forgejo dump zip, extract into a clean state directory, preserving
   ownership as `forgejo:forgejo`.
4. Start Forgejo and run the doctor command above.
5. Verify `https://git.ablz.au/api/healthz`, SSH on `:2222`, and refs for
   critical repos.
6. If mirror state was restored or extracted, rotate the GitHub mirror PAT
   before enabling mirror sync.

## Least-Privilege Notes

The current Forgejo instance is intentionally private and has registration
disabled. It runs behind doc2's local proxy, with only the Forgejo HTTP loopback
port and built-in SSH port exposed. The source-of-truth cutover changes the
blast radius unless the planned controls land first:

- host-side signed commit verification must enforce before Forgejo becomes a
  fleet deploy source;
- `nixosconfig` must use dedicated writer identities and repo-scoped tokens;
- personal accounts must not be ordinary `master` writers;
- GitHub must be demoted to a push mirror with a dedicated mirror actor;
- backup and dump handling must account for mirror credentials stored in the
  Forgejo database.
