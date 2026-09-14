# Shelfarr audiobook requests

Date: 2026-09-14. Host: doc2. Application and integrations deployed and verified;
the dedicated Tailscale node still needs its first interactive authentication.

Shelfarr connects Prowlarr, qBittorrent, NZBGet and the existing ABS AudioBooks
library. Source: <https://github.com/Pedro-Revez-Silva/shelfarr>. The upstream OCI
image uses `latest`, with the normal fleet update and recovery machinery.

## Access and state

- `https://shelfarr.ablz.au` is served by the `ts-shelfarr` / `caddy-shelfarr`
  sidecars. The node advertises `tag:share`; DNS publishes its Tailscale A/AAAA
  addresses. There is no LAN proxy or public application listener.
- The application binds host loopback and the Podman bridge on port 5056.
- Initial administrator: `abl030`. Recover the initial password with
  `ssh doc2 'sudo cat /run/secrets/shelfarr/admin-password'`, then change it in
  Profile. This recovery secret is not updated by later profile changes.
- State: `/mnt/virtio/shelfarr/{storage,tmp,log}`. Back up all of `storage`,
  including `.secret_key_base` and `.encryption_keys`, alongside the SQLite
  databases. Losing the encryption keys loses stored client credentials.
- The separate sidecar state is `/mnt/virtio/tailscale-share/shelfarr`.
  Never delete it to troubleshoot authentication.
- Additional bootstrap credentials are encrypted in
  `secrets/hosts/doc2/shelfarr-bootstrap.json`, to doc2, editor and break-glass
  recipients. Only the initial application password is deployed by sops-nix.

## Integrations and import policy

Prowlarr uses `https://prowlarr.ablz.au`, including its NZBHydra2 indexer. NZBGet
uses `https://nzbget.ablz.au` with a restricted account; qBittorrent uses
`https://qbt.ablz.au` and its existing trusted servarr proxy authentication path.
The new `shelfarr` qBittorrent category has save path `/downloads/shelfarr`.
NZBGet's existing `AppendCategoryDir=yes` puts category `shelfarr` beneath its
completed directory. Other categories are unchanged.

| Purpose | Host path | Shelfarr path |
| --- | --- | --- |
| qBittorrent completed content | `/mnt/data/Media/Temp/shelfarr` | `/downloads/shelfarr` (read-only) |
| NZBGet completed content | `/mnt/data/Media/Temp/completed/shelfarr` | `/downloads/completed/shelfarr` (read-only) |
| New library content | `/mnt/data/Media/Books/Audiobooks/Shelfarr` | `/audiobooks` |

ABS scans this subtree inside its existing AudioBooks library. Its dedicated
`shelfarr` account has a separately revocable API key. ABS requires admin role to
trigger scans; library access is limited to AudioBooks and download, upload and
delete permissions are disabled, but admin role still carries administrative API
power. Prowlarr's key and the existing qBittorrent proxy likewise provide broader
client control than a category; category selection is not an authorization boundary.

Approvals and manual release selection are enabled. English, M4B and single-file
audiobooks are preferred. Copy mode preserves seeding bytes, and automatic Usenet
source removal is disabled. Shelfarr does not transcode MP3 releases into M4B:
select M4B releases, or use the existing conversion workflow before manual import.
Ebook/comic outputs point to private application storage and are not ABS libraries.

## Ownership and health

Unraid exports `data` with `all_squash,anonuid=99,anongid=100`. New files arrive as
UID 99 regardless of the requesting UID. Shelfarr rejects staging directories
owned by another UID, so the dedicated doc2 account runs as UID 99, GID 2020,
with supplementary media group 100. UID 99 was unused on doc2 before deployment.
The container drops all capabilities, cannot gain privileges, uses an isolated
bridge and has a 2 GiB memory limit. Its private state is mode 0750; no host control
socket, whole media library or other clients' downloads are mounted.

On a fresh NAS, provision just the three leaf paths in the table as `99:100`,
mode 2775; root-squashed NFS cannot change ownership. Never recursively chown the
existing audiobook library. Application state belongs to `99:2020`.

The deep probe performs rolled-back SQLite insert/read transactions in the main
and queue databases, checks worker/dispatcher/scheduler heartbeats, writes and
reads a temporary library file, and opens both download folders. It runs as the
application UID inside the container. The shallow probe checks `/up`, and the NFS
watchdog restarts the application on stale handles. The log alert watches database
corruption/read-only/full failures and unexpected worker-supervisor exit.

## Operations and rollback

Preflight on 2026-09-14 verified administrator login, authenticated API access,
metadata search, 26 indexer search results, all four integration connection tests,
and synchronization of 211 existing ABS inventory records. Two-second M4B fixtures
were placed in each download folder; fresh imports completed through Shelfarr's
post-processing job and appeared in ABS with the correct two-second duration.
The test files and records were removed. These tests verify completed-file import
and scan integration; they did not fetch an audiobook from a tracker or Usenet.
The default atomic-publication policy remains enabled; the NFS fallback was not
needed. The SQLite/worker/storage probe also passed as the final application UID.

The first switch exposed a probe startup race: OCI readiness preceded the queue
workers registering. The probe now allows 30 seconds for those heartbeats within
its existing 45-second outer timeout. The first switch installed revision
`a769db5c`, but the deployment wrapper reported failure while Tailscale enrollment
was pending. Re-run the verified deployment after enrollment to deploy the probe
startup fix and obtain a successful fleet-update receipt.

Enrollment is held open in temporary container `shelfarr-enrol`, using the same
`ts-state` as the final sidecar. Its daemon uses userspace networking and no
capabilities. The generated Caddy/Tailscale units are stopped while it owns that
state. After the browser login, stop/remove `shelfarr-enrol`, then run
`fleet-deploy doc2` and start the generated sidecars/DNS sync if needed. Never run
both Tailscale daemons against the state directory at once. Verify the public
FQDN, both DNS address families, the final app's four integration connections,
and the deep probe before calling the service complete.

Use `fleet-deploy doc2` from doc1 after a signed Forgejo push. Verify the active
revision and `podman-shelfarr`, `podman-ts-shelfarr`, `podman-caddy-shelfarr`,
`tailscale-share-dns-sync-shelfarr` and `deep-probe-shelfarr-write-path` units.
Interactive first-run Tailscale authentication prints a login URL in
`sudo podman logs ts-shelfarr`. Complete that login, then restart DNS sync if its
bounded first-run wait has expired. See [Tailscale sharing](tailscale-share.md).

To roll back, disable `homelab.services.shelfarr.enable`, commit/sign/push and
deploy doc2. Keep state and imported books. Revoke the dedicated ABS key/account
if retiring the integration. NZBGet's pre-change config backup is
`/mnt/user/appdata/nzbget/nzbget.conf.before-shelfarr`; restore only the restricted
authentication fields if later unrelated settings have changed. Remove the new
qBittorrent category only after checking for torrents still assigned to it.
