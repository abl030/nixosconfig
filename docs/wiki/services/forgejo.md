# Forgejo

**Date researched:** 2026-06-10
**Status:** active, post-v15 migration verified
**Host:** doc2
**Source module:** `modules/nixos/services/forgejo.nix`
**Related:** #223, #235, #270

Forgejo runs at https://git.ablz.au on doc2. It is currently a private forge
for `abl030/books` and `abl030/agents`; `nixosconfig` cutover is tracked in
the signed fleet deploys plan.

## Runtime

- Package: `forgejo-lts-15.0.2`
- State: `/mnt/virtio/forgejo`
- Repositories: `/mnt/virtio/forgejo/repositories`
- Database: SQLite at `/mnt/virtio/forgejo/data/forgejo.db`
- HTTP: `127.0.0.1:3023`, proxied by nginx as `https://git.ablz.au`
- SSH Git: built-in Forgejo SSH server on `git.ablz.au:2222`
- Dumps: `/mnt/data/Life/Andy/Code/forgejo-dumps`

The module deliberately keeps Forgejo private for now:

```ini
[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = true

[repository]
DEFAULT_PRIVATE = private
DEFAULT_PUSH_CREATE_PRIVATE = true
```

`REQUIRE_SIGNIN_VIEW` flips to `false` only during the `nixosconfig` cutover,
when that repository is made public for anonymous host fetches. Private repos
must stay private per repository.

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
