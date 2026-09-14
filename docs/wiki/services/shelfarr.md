# Shelfarr audiobook and ebook requests

Date: 2026-09-14. Host: doc2. Application, integrations and Tailscale HTTPS access
deployed and verified at `https://shelfarr.ablz.au`.

Shelfarr connects Prowlarr, qBittorrent, NZBGet and the existing ABS AudioBooks
library. Source: <https://github.com/Pedro-Revez-Silva/shelfarr>. The upstream OCI
image uses `latest`, with the normal fleet update and recovery machinery.

## Access and state

- `https://shelfarr.ablz.au` is served by the `ts-shelfarr` / `caddy-shelfarr`
  sidecars. The node advertises `tag:share`; DNS publishes its Tailscale A/AAAA
  addresses. There is no LAN proxy or public application listener.
- The application binds host loopback and the Podman bridge on port 5056.
- Cullen's laptop (`tag:cullen`) has an exact TCP 443 grant to this sidecar's
  IPv4 and IPv6 addresses in `tailscale/acl.hujson`; other share access is unchanged.
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
Ebooks use the Calibre bridge below; comic output remains private application storage.

### Calibre ebook delivery

Enabled on doc2 on 2026-09-14 via `homelab.services.shelfarr.calibre.enable`.
Shelfarr has no native Calibre connector. `shelfarr-calibre.service` runs every
minute and reads acquired ebook records from Shelfarr's SQLite database in
read-only WAL mode. It only processes `book_type=1`, a populated `file_path`,
and no acquisition reservation. This is an explicit upstream schema dependency;
schema errors fail visibly rather than falling back to scanning download folders.

- Shelfarr's ebook output is `/ebooks`, backed by
  `/mnt/data/Media/Books/Shelfarr`; author/title folders and EPUB preference apply.
  Both existing qBittorrent and NZBGet paths feed the ordinary post-processing job.
- The bridge snapshots regular ebook files from that subtree, rejecting symlinks,
  traversal, empty/changing files and files above 512 MiB. Accepted formats are
  EPUB, PDF, MOBI, AZW, AZW3 and DJVU. It never removes the original files.
- `calibredb add --automerge ignore` sends each ebook to the **running Calibre
  GUI's** authenticated content server at `http://tower:8086/calibre/#Library`.
  Existing matching title/author formats are retained; missing formats are added.
  A repeated import after a crash therefore does not create another copy or
  overwrite an existing format. Calibre owns all changes to `metadata.db` and
  `/mnt/user/data/Media/Books/Calibre LIbrary` (the spelling is intentional).
- Private receipts in `/var/lib/shelfarr-calibre/imports.sqlite3` record successful
  imports. Unchanged files are skipped without rereading their contents. Failures
  retry on the next timer run. Successful imports persist a pending Komga scan;
  a scan failure retries without repeating the Calibre import.
- Komga library `0QFQQFTD08FRG` is scanned after imports. Browse the ebooks through
  the existing Calibre desktop or Komga, as before. This bridge does **not** sync
  existing Calibre inventory into Shelfarr's Library page or duplicate matcher.
  Shelfarr's acquired ebooks remain available in its own Library page.

Tower configuration is in the existing `calibre` container's persistent
`/config/.config/calibre`: `gui.py.json` now has `autolaunch_server=true`.
Existing `server-config.txt` already had `auth True`, port 8081 and prefix
`calibre`; Docker already published this at tower port 8086. Library API calls
require authentication; static application HTML is public. No new public proxy
or tailnet grant is introduced. Authentication uses HTTP Digest on the LAN.
The new `shelfarr` server account is restricted to `Library`, cannot change its
password through HTTP, and is separately revocable. Calibre's write account
includes editing/deleting within that library; it has no add-only permission.
The pre-existing `readarr` account is retained.

Credentials are in host-scoped `secrets/hosts/doc2/shelfarr-calibre.json`, supplied
as systemd credentials rather than command-line passwords. The bridge also gets
the existing Komga sync API credential, which has broader administrative access
than a single scan. It runs as a separate unprivileged account, with read-only
ebook and Shelfarr storage mounts, masked Shelfarr encryption keys, private
temporary/state directories, no host control socket and no Calibre library mount.
Every run checks authenticated Calibre access even with no pending ebooks.
Persistent failures log `SHELFARR_CALIBRE_FAILED` and alert through Loki.

Import activity: `journalctl -u shelfarr-calibre.service -n 50`. A Shelfarr request
becomes Completed when its local acquisition finishes; Calibre delivery follows
on the next bridge run, then Komga indexing. Shelfarr's Activity page continues to
show acquisition/search activity; the separate bridge log shows downstream imports.

Rollback: disable `homelab.services.shelfarr.calibre.enable`, sign/push and deploy
doc2. Keep downloaded ebooks and Calibre contents. Revoke the `shelfarr` account
through Calibre's server-user management. If retiring the server, turn off its
autostart in Calibre preferences. Pre-change settings and the server-user DB are
backed up under `/config/.config/calibre/before-shelfarr-ebooks-20260914/` in the
Calibre container; do not restore that whole user DB over later account changes.
Never point a separate `calibredb` process directly at `/Library` while the GUI
owns it. See [Calibre's supported remote CLI](https://manual.calibre-ebook.com/generated/en/calibredb.html).

Verification on 2026-09-14: ebook search returned eight downloadable results,
including NZBHydra2 and torrent indexers. Two synthetic EPUBs passed the ordinary
Shelfarr post-processing job from the qBittorrent and NZBGet completion folders,
then appeared as EPUB records in Calibre and READY one-page books in Komga.
Their Calibre file hashes matched the original fixtures exactly. A normal repeat
run skipped both; deleting one fixture's local import receipt and replaying the
import still left exactly two Calibre records. All 281 pre-existing book IDs and
titles were unchanged. Test books and source/output files were subsequently removed.
These are completed-file import tests, not actual tracker/Usenet transfers.

The first switch (`5ff6aa4f`) activated the bridge during a Shelfarr restart, while
its WAL/SHM files were briefly absent; the switch wrapper failed on that first
read-only open. The next timer run succeeded without any permission changes.
The reader now allows up to 30 seconds for CANTOPEN/BUSY startup errors, keeps
read-only access, and fails schema errors immediately. Nine behavior tests cover
these boundaries, retry/scan persistence, duplicate handling and unsafe paths.

### What ABS synchronization displays

Verified against the running application on 2026-09-14: ABS synchronization fills
an inventory cache for duplicate matching. It does not populate Shelfarr's Library
page, which lists books acquired/uploaded through Shelfarr and synced Audible
purchases. All 211 existing ABS records were available for matching while the
Library catalog correctly returned zero entries before any real acquisition.
Search results show matching ABS inventory under "Related titles in Audiobookshelf";
request screens show likely/possible matches. Settings shows sync counts and the
50 most recent cached items. Browse the existing collection in ABS; there is no
setting in this version to include it in Shelfarr's Library catalog.

### Metadata search timeouts

On 2026-09-14, searches for `rowling` and `j k rowling` intermittently failed.
Google Books anonymous access returned HTTP 429 with a daily quota of zero;
no Google or Hardcover key was configured. Open Library also intermittently
exceeded its hardcoded five-second connection/TLS deadline. Direct application
tests with a 15-second connection allowance returned 20 results for each of
`rowling`, `j k rowling`, and `harry potter`, including two calls taking 8–9 seconds.
The firewall received replies from Open Library's address and the sampled firewall
logs contained no matching blocks; no firewall or routing changes were made.

The module mounts a read-only Rails initializer that raises only Open Library's
connection timeout to 15 seconds. The upstream 15-second read timeout remains.
This tolerates slow connection setup; it cannot prevent provider outages. Remove
the initializer mount and its `metadataTimeout` definition to roll back, or when
upstream exposes a supported timeout setting. A dedicated Google Books or
Hardcover key would provide a second usable metadata source.

Deployment `612c87ea` passed on doc2. Authenticated HTTPS searches returned
20 results for `rowling`, 20 for `j k rowling`, and 17 for `harry potter`, with
ABS matches and no metadata error. The last search took 10 seconds. The mounted
initializer matched the built file, connection reset retained the override, and
the SQLite/worker/storage probe passed. Remote metadata remains the active source.

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
was pending. The startup fix is in `d8a46a11`; the subsequent verified deployment
includes it.

Enrollment completed on 2026-09-14. A temporary `shelfarr-enrol` container held
the interactive login open against the same `ts-state`, avoiding containerboot's
one-minute authentication timeout. It was stopped and removed before restoring
the generated sidecars. Never run two Tailscale daemons against that state at once.
The managed `ts-shelfarr` retained the enrolled identity with `tag:share`:
IPv4 `100.118.169.64`, IPv6 `fd7a:115c:a1e0::a83a:a942`. Authoritative public DNS
publishes both records. TLS verification and `/up` returned HTTP 200 over both
address families from doc1 and doc2. Administrator login and settings pages work
through the actual HTTPS hostname; anonymous API requests return HTTP 401.

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
