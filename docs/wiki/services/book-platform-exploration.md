# Book platform exploration

Updated: 2026-09-15. Status: parallel evaluation; no winner selected and no migration
authorized. Host: doc2. The user explicitly wants time to explore all candidates.

## What we are trying to improve

The desired experience is similar to Overseerr: browse/search around the existing
collection, see whether an ebook and/or audiobook is available, and request a
missing format. Successful downloading alone is insufficient. Calibre is optional;
OPDS delivery to KOReader and the current ABS listening experience matter more.

Shelfarr already delivers audiobooks through qBittorrent/NZBGet into ABS. Its
custom ebook bridge successfully delivered Red Rising into Calibre and Komga,
and the user downloaded the EPUB to KOReader. Keep that working setup during
evaluation. See [Shelfarr setup and evidence](shelfarr.md).

Shelfarr's ABS sync populates a duplicate-matching cache; it does not populate
the Library screen with the whole existing ABS collection. The Calibre bridge
imports newly acquired ebooks, but has no inbound inventory sync. The earlier
recommendation placed too much weight on acquisition and insufficient weight on
the visible ownership model.

## Candidates and evidence

These are documentation/source findings, not proof of end-to-end operation in
this homelab. The live verification section below records what was actually tried.

| Candidate | Inventory model | Main uncertainty |
| --- | --- | --- |
| Chaptarr | Imports existing files into one audiobook/ebook catalog; separate per-format monitoring and roots. qBittorrent and NZBGet implementations exist. | Arr-style management interface, beta matching, and existing-library import quality. Its ABS notification integration is outbound scan notification, not inbound ABS inventory/progress sync. |
| Bookkeep + Booklore | Bookkeep imports Booklore ebook inventory and ABS audiobook inventory; its book/request UI consumes separate availability flags. Booklore provides the ebook reader/catalog and OPDS. | Hardcover identity matching, reliable availability updates, deployment maturity, and acquisition completion. |
| ReadMeABook | Imports ABS inventory and enriches audiobook search results with availability. Ebook requests are children/companions of audiobook requests. | Stronger audiobook portal, but not a complete independent ebook collection manager. |
| Shelfmark | Search/request/download interface with delivery integrations. Library URLs are navigation links. | Did not find the inbound inventory model required here. Not installed for this trial. |
| Librarr (JeremiahM37) | Local file catalog, OPDS and some external library views. | README integration list overstates a unified inventory: Komga integration in reviewed source is manga-oriented, ownership lookup uses local DB, and no NZBGet client was found. Not installed. |

Primary sources reviewed on 2026-09-14:

- [Chaptarr](https://github.com/Chaptarr/chaptarr), source revision
  `7a06004eee40e9861a553c743d0436c91fe0224d`: book resource has separate local
  audiobook/ebook instances, disk scan/import supports existing files.
- [Bookkeep](https://github.com/boludo00/bookkeep), source revision
  `62ee01e139286a57c0d695651876034232707840`: `backend/app/tasks.py`
  implements `sync_from_booklore` and `sync_from_audiobookshelf`; scheduler
  defaults to daily runs. `src/pages/BookDetails.tsx` and
  `SearchReleaseDialog.tsx` use per-format ownership.
- [Bookkeep availability report #87](https://github.com/boludo00/bookkeep/issues/87)
  describes completed imports staying pending; this has not been tested here.
  [Installation report #89](https://github.com/boludo00/bookkeep/issues/89)
  describes fresh database migration failures; the same failure was subsequently
  reproduced and worked around during this deployment, as recorded below.
- [Booklore](https://github.com/booklore-app/booklore): OPDS, KOReader, BookDrop;
  `DISK_TYPE=NETWORK` disables file mutation/reorganization for network libraries.
  Booklore and its community fork [Grimmory](https://github.com/grimmory-tools/grimmory)
  are distinct targets. Do not assume Bookkeep API compatibility with Grimmory;
  [support is requested upstream](https://github.com/boludo00/bookkeep/issues/90).
- [ReadMeABook](https://github.com/kikootwo/ReadMeABook), source revision
  `bc371860d06c921e2f474ada226b7a3c6427fca5`: ABS inventory scan is implemented;
  an NZBGet client exists despite older README examples emphasizing SABnzbd.
  [Ebook lifecycle](https://github.com/kikootwo/ReadMeABook/blob/main/documentation/integrations/ebook-sidecar.md)
  ends at downloaded, rather than audiobook backend-confirmed availability.
- [Shelfmark environment variables](https://github.com/calibrain/shelfmark/blob/main/docs/environment-variables.md)
  and [Librarr](https://github.com/JeremiahM37/librarr).
- [Komga OPDS](https://komga.org/docs/guides/opds/) supports KOReader. OPDS
  delivery and reading-progress synchronization are separate capabilities.

## Trial access and boundaries

The four NixOS modules are enabled on doc2, using upstream OCI images with the
normal fleet update policy. At the user's request, named HTTPS URLs were added
through `homelab.localProxy` on 2026-09-14. Their DNS records point to doc2's LAN
address, with certificates and WebSocket proxying managed by the existing
infrastructure. No Tailscale nodes or sharing rules are introduced.

| Application | LAN HTTPS URL | Persistent state | Role |
| --- | --- | --- | --- |
| Chaptarr | <https://chaptarr.ablz.au> | `/mnt/virtio/chaptarr` | Collection manager |
| Booklore | <https://booklore.ablz.au> | `/mnt/virtio/booklore` | Ebook catalog/OPDS |
| Bookkeep | <https://bookkeep.ablz.au> | `/mnt/virtio/bookkeep` | Request/discovery portal |
| ReadMeABook | <https://readmeabook.ablz.au> | `/mnt/virtio/readmeabook` | ABS-aware request portal |

The original direct HTTP addresses remain available at `192.168.1.35` on ports
8789, 6060, 8788 and 3031 respectively. Application listeners bind the LAN address
and loopback, not the tailnet address. Prefer the HTTPS names for logins and OPDS.

Administrator username is `abl030` after bootstrap. Initial passwords are
separate random values in the operator-only SOPS secret. Recover one on doc2:

```sh
sudo jq -r '.booklore.password' /run/secrets/book-trials/bootstrap
```

From doc1 (`proxmox-vm`), retrieve all four passwords over SSH instead; the
decrypted file deliberately exists only on doc2:

```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 doc2 \
  "sudo jq 'map_values(.password)' /run/secrets/book-trials/bootstrap"
```

Replace `booklore` with `chaptarr`, `bookkeep` or `readmeabook`. Password changes
inside an app do not update this initial recovery record. Do not put passwords,
JWTs or API tokens in the wiki or command-line arguments.

Booklore sees the existing Calibre directory at `/books/existing`, read-only.
The actual host spelling is `/mnt/data/Media/Books/Calibre LIbrary` (capital I).
It writes only its own database/covers/cache. Chaptarr can see the same ebooks at
`/existing/ebooks` and ABS files at `/existing/audiobooks`, both read-only.
Trial output/config directories are independent. Read-only roots may not pass
Chaptarr's managed-root write validation; evaluate managed import on copies,
never loosen the mount merely to make a validation check green.

Bookkeep requires a Hardcover API token for discovery and matching. It can be
entered in Settings without replacing the container. Do not treat a missing
token as a metadata-service outage. The final setup status is recorded below.

Bookkeep's Booklore connection uses `https://booklore.ablz.au`. During the initial
port-only trial, `doc2` resolved inside OCI to inherited loopback `127.0.0.2`,
while `doc2.ablz.au` hit the wildcard legacy proxy. The temporary LAN-IP connection
avoided that ambiguity; the dedicated service name now follows doc2 through
the normal DNS ownership machinery. ReadMeABook's `PUBLIC_URL` and all four HTTP
health monitors also use their HTTPS service names.

MariaDB (`booklore-db`, helper hostNum 11) and PostgreSQL (`bookkeep-db`, 12;
`readmeabook-db`, 13) have isolated state and service-only TCP credentials.
ReadMeABook uses internal Redis plus external PostgreSQL. Chaptarr and Bookkeep
start as dedicated UIDs with all capabilities dropped. Booklore and ReadMeABook
allow the limited capabilities needed by their root initialization, then run
Java/Next.js as dedicated application users; ReadMeABook's container supervisor
remains root. Application UIDs are 2021–2024, never the operator's UID.
No host control sockets or unrelated
libraries are mounted. Initial credentials are encrypted only to doc2, editor
and cold recovery recipients.

## Live verification and findings

All four applications were deployed on 2026-09-14 and administrator login was
verified in a real browser. HTTP and deeper application-state/database-authority
probes passed. The existing Shelfarr, ABS, Komga and Calibre bridge remained
active. Initial deployment commit: `353dcd479a148017aeb5563b138fb71c2f944939`;
storage/bootstrap correction: `fce1480f1a27875bf768a27f233094539e151e1c`.
The initial direct-LAN endpoint and credential revision
`785bf596523450d83ea7570292bcbbb5d929d152` was verified running on doc2.
Anonymous requests to protected APIs returned 401/403 in all four apps. Their
ports were reachable on the LAN address and not on doc2's tailnet address;
existing-library mounts were confirmed read-only in the running containers.

The follow-up HTTPS deployment `3be5e9468acee2ddbbfa21ed438c6b3cb644d8de`
was verified running on doc2 at 19:56 AWST. All four authoritative DNS records
pointed to `192.168.1.35`, unproxied and owned by `managed-by:doc2`. Normal LAN DNS,
trusted TLS and health endpoints passed without resolver overrides. Authenticated
API reads passed through all four names, and Bookkeep returned 280 ebooks after
its Booklore URL was changed to HTTPS. The OPDS feed and exact Red Rising EPUB
download also passed through `booklore.ablz.au`. All four deep probes passed
after this deployment.

| Application | Observed version | What is usable now |
| --- | --- | --- |
| Booklore | v2.3.1 | Existing library indexed: **280 ebooks**; browser catalog and authenticated OPDS download verified. |
| Bookkeep | v1.6.2 | Both integrations configured. Its own connector endpoints return **280 Booklore books** and **214 ABS items**. Discovery still requires a Hardcover API token. |
| ReadMeABook | v1.2.2 | ABS scan imported **214 items**; remote Red Rising search works. Homepage refresh was triggered. |
| Chaptarr | 0.9.911.0, develop | Remote metadata search works; copied Red Rising EPUB/audio were scanned into the catalog. |

Chaptarr and Bookkeep remain library/UI trials with no download clients/indexers
configured. On 2026-09-15 the user preferred ReadMeABook's interface and asked to
improve confident matches and connect both download clients. ReadMeABook now uses
Prowlarr, qBittorrent and NZBGet with its own categories and ABS output subtree
(details below). Shelfarr remains available. A fresh ReadMeABook acquisition has
not yet been exercised; connection and filesystem checks are not evidence that
a particular release will download and import successfully.

### Booklore and OPDS

Library 1, **Existing ebooks (read-only trial)**, scans `/books/existing` with
`watch=false`, `PREFER_SIDECAR` metadata and `BOOK_PER_FOLDER` organization.
`DISK_TYPE=NETWORK` is backed by an actual read-only bind mount. Its 280 detected
books differ from Calibre's 282 records; the two-record discrepancy has not yet
been audited and should not be assumed to be a sync success.

OPDS is enabled at <https://booklore.ablz.au/api/v1/opds>. OPDS username is
`abl030`, with a separate password:

```sh
sudo jq -r '.booklore.opds_password' /run/secrets/book-trials/bootstrap
```

Both the authenticated Atom feed and Red Rising download were tested. Booklore
book 213 (`/api/v1/opds/213/download`) returned the same 2,920,422-byte EPUB as
the existing Calibre book 335, SHA-256
`16977a7da7f06dd2cfa5d2c793713d749bdc5b06bc9a862c9c535c8ed86bbd5e`.
KOReader has not yet been pointed at this new feed; the earlier phone download
was through Komga.

### Bookkeep inventory and remaining token

Bookkeep's Booklore integration uses dedicated `bookkeep-trial` credentials
restricted to library 1, not the administrator account. Its ABS integration uses
the separate read-only `trial-bookkeep` account. The connection test and actual
connector reads passed, but this does **not** prove its Hardcover-linked catalog
or search availability is populated. The browser currently displays **Hardcover
API Token Required**. Enter a personal Hardcover token in Settings, then run the
inventory sync and inspect matching results. This is the next useful evaluation
step, not an application outage.

Fresh Bookkeep startup failed at migration 004 → 005 with `NoSuchTableError:
books`: upstream ran migrations before creating the ORM base tables. The local
`bookkeep-initialize.py` wrapper creates the upstream ORM schema and stamps the
current heads **only when no application tables exist**. Populated databases
always follow normal upstream migrations. No existing application data was
dropped. Revisit this workaround when upstream fixes fresh installation #89.

### ReadMeABook matching

The completed ABS inventory scan imported 214 entries using the read-only
`trial-readmeabook` account. Both trial ABS accounts can access only the selected
audiobook library and cannot change metadata or files.

The initial Red Rising false negative was caused by its missing ASIN. On
2026-09-15, a full scan again read all 214 ABS items successfully; 196 had ASINs
and 18 did not. The user authorized confident metadata matches, then explicitly
asked to leave uncertain recordings for later rather than force matches.

Three ASIN-only updates were applied in ABS. Other metadata and audio files were
preserved; each update was re-read and compared with its saved metadata:

| ABS title | Verified ASIN | Local duration | Audible duration / narrator |
| --- | --- | --- | --- |
| Red Rising | [B00I2VWW5U](https://www.audible.com/pd/B00I2VWW5U) | 16h 12m 24s | 16h 12m, Tim Gerard Reynolds |
| Golden Son | [B00R6S1RCY](https://www.audible.com/pd/B00R6S1RCY) | 19h 4m 27s | 19h 3m, Tim Gerard Reynolds |
| Forward the Foundation | [B005WWT30E](https://www.audible.com/pd/B005WWT30E) | 16h 7m 39s | 16h 10m, Larry McKeever |

ReadMeABook's next inventory scan picked up the changes. Red Rising and Golden
Son search results now return `isAvailable=true`, while their different
dramatized adaptations remain unavailable. The remaining 15 include older
Foundation narrations, the Celeste Ciulla Ancillary Justice, a duration-mismatched
Carnegie recording, podcasts/course/meditation collections, Realm of Numbers and
an uncertain Cursed Child recording. Missing ASIN does not mean missing audio.
Do not assign a modern narrator's ASIN merely because the title matches.

Before-state and applied-ID records are root-only on doc2 under
`/mnt/virtio/readmeabook/metadata-backups/2026-09-15/`. To undo a match, use the
saved item ID and `PATCH /api/items/<id>/media` with its previous
`metadata.asin` (null for these three), then run ReadMeABook's Library Scan job.
ABS control credentials stay on doc1; the ReadMeABook account remains read-only.

### ReadMeABook downloading

Both client tests passed **from ReadMeABook**: qBittorrent v5.2.3 and NZBGet
v26.3. Its Prowlarr test found ten enabled indexers spanning torrents and usenet.
Each enabled client uses category `readmeabook`, TLS verification, and a relative
custom download path under `/downloads`; remote path mapping is unnecessary.

| Purpose | Host path | ReadMeABook path / client custom path |
| --- | --- | --- |
| qBittorrent | `/mnt/data/Media/Temp/readmeabook` | `/downloads/readmeabook` / `readmeabook` |
| NZBGet | `/mnt/data/Media/Temp/completed/readmeabook` | `/downloads/completed/readmeabook` / `completed/readmeabook` |
| ABS output | `/mnt/data/Media/Books/Audiobooks/ReadMeABook` | `/media` |

Only these category directories and the new output subtree are exposed to the
app. Unlike Shelfarr's copy-only import, ReadMeABook's metadata tagger writes
temporary siblings beside downloads before copying to the library, so its own
category mounts are writable. Original torrent bytes are preserved for seeding.
The application keeps UID 2024 and uses GID 100 for the NAS permission model.
Deep probes exercise writes as that UID in both download roots and `/media`.
They pass an explicit UID:GID to Podman: a numeric UID alone otherwise gives an
exec process GID 0, which would not test the application's real permissions.

On a fresh NAS, provision the NZBGet leaf on tower before enabling the mount:

```sh
ssh root@tower 'install -d -m 2775 -o 99 -g 100 /mnt/user/data/Media/Temp/completed/readmeabook'
```

The initial switch hit systemd-tmpfiles' unsafe-path check because `Temp` and
`Temp/completed` have different existing owners. Provisioning only the leaf
resolved startup; parent ownership was preserved. The module manages the other
two leaf directories and requires the existing mounts before starting.

qBittorrent uses the existing trusted servarr proxy route. NZBGet uses its existing
restricted control account; administrative credentials were not given to
ReadMeABook. Its category was provisioned on tower so the app does not need to
rewrite NZBGet configuration. The prior file is retained at
`/mnt/user/appdata/nzbget/nzbget.conf.before-readmeabook-20260915`; NZBGet was
restarted to load the added category. Category names are operational separation,
not an API authorization boundary.

ABS indexes the output subtree within the existing AudioBooks library. Its
filesystem watcher/hourly scan provides discovery; immediate API-triggered scans
remain off because ABS requires an admin role for that endpoint. The user's first
request, **Children of Time** (`B071Y9TTHC`), completed and appeared in ABS as item
`afc64e7b-7561-44c8-adb9-492614da007e`; ReadMeABook reports it available.

### Automatic companion EPUBs and Komga (2026-09-15)

The user selected automatic companions for every ReadMeABook audiobook request.
In **Admin Settings → E-book Sidecar**, indexer search and auto-grab are enabled,
preferred format is EPUB, and Anna's Archive and Kindle rewriting remain off.
The ten configured indexers already have ebook category `7020`. Both qBittorrent
and NZBGet are available; the automatic **Children of Time** companion selected a
NZBHydra2 result and completed through NZBGet. Its ebook request is
`d4aaae69-0c2c-4146-a16b-c029774c780f`, status `downloaded`, with a 1,902,641-byte
EPUB beside the audio under `Adrian Tchaikovsky/Children of Time B071Y9TTHC`.

This is a search-on-completion policy, not a guarantee that every title has an
EPUB release. EPUB is a ranking preference, not a strict format filter; a
non-EPUB/PDF fallback will not be served by Komga without conversion. The daily
**Find Missing Ebooks** job retries missing companions
for completed ReadMeABook requests (up to five automatic attempts). It does not
request ebooks for the entire imported ABS inventory. We triggered it once to
backfill the already completed Children of Time request and verify automatic
selection, downloading and organization without manually choosing a release.

Komga consumes the same ReadMeABook output directory through a read-only bind.
Its **ReadMeABook ebooks** library imports EPUB metadata, enables KOReader
hashing, and scans EPUB/PDF files; audio is ignored. Native hourly scans provide
a fallback, while `komga-readmeabook-scan.timer` requests a scan of only this
library every two minutes. The helper has no media filesystem access, uses a
systemd credential for Komga's existing API key, and can connect only over
loopback. Failed scan submissions and Komga scan failures are monitored.

New ebook delivery is **ReadMeABook → shared files → Komga → KOReader**, with no
Calibre import or second copy. The existing Calibre-backed Komga library and
Shelfarr bridge remain intact; this change does not retire the old services or
move their collection. Calibre remains optional for manual conversions/editing,
and Booklore remains an evaluation candidate. ReadMeABook does not synchronize
ownership from Komga, so existing ebooks can still be acquired again.

Use the existing <https://magazines.ablz.au> login and KOReader OPDS catalogue at
<https://magazines.ablz.au/opds/v1.2/catalog> (v2 also supported at
`/opds/v2/catalog`). New companions appear in **ReadMeABook ebooks**.

Verified on doc2 revision `cb9259f01e2733ea66c7a55168c51d9c8377e1aa`, deployed
at 08:03 AWST: the read-only bind is active, the credential-backed scan helper
exits successfully, and the two-minute timer is enabled. Komga library
`0RM7YEQPWPYVP` contains **Children of Time**, book `0RM7YEQW0PYSB`, media status
`READY`. The actual OPDS acquisition link returned HTTP 200, a valid English EPUB
ZIP, and bytes identical to the source file (SHA-256
`9eddc32d3667dffeefd0dfc5d11b2bea76dc10a42c88b003577144705423016b`).
The older Calibre-backed library already contained this title, demonstrating the
cross-library deduplication limitation; neither copy was removed.

Before deployment, the doc2 toplevel build, unit-hardening audit, Alejandra,
deadnix and statix passed. Komga, ReadMeABook and ABS remained healthy afterward.
Pre-change ebook settings are backed up on doc2 at
`/mnt/virtio/readmeabook/metadata-backups/2026-09-15/ebook-settings-before.json`.

Rollback: disable auto-grab and indexer search in ReadMeABook's E-book Sidecar
settings, stop/disable `komga-readmeabook-scan.timer`, remove only its Komga library
record, and revert the companion additions in `komga.nix` through fleet deploy.
The downloaded files and original audiobook request remain intact. The pre-change
ebook settings were both sources off, auto-grab on, preferred format EPUB, and
Kindle fixes off.

### ReadMeABook tailnet sharing (2026-09-15)

The dedicated share is configured in `readmeabook.nix`: node
`readmeabook`, tag `tag:share`, HTTPS at `readmeabook.ablz.au`, dual-stack DNS,
and separate root-owned state in `/mnt/virtio/tailscale-share/readmeabook`.
The application's port becomes loopback/Podman-bridge-only; the existing
LAN-owned DNS/nginx entry is replaced by the single-service Caddy sidecar.
DNS publication is ordered after the old local-proxy DNS cleanup.

The legacy doc2 enrollment OAuth credential returned HTTP 401. No new enrollment
secret was stored. A temporary `readmeabook-enrol` container on doc2 ran a stable
userspace `tailscaled` against the final `ts-state` directory while the owner
completed the browser login. Enrollment succeeded with `tag:share`:

- Node ID: `njSQ7rNh3411CNTRL`, name `readmeabook.tail13796.ts.net`.
- IPv4: `100.84.213.15`; IPv6: `fd7a:115c:a1e0::f93a:d510`.
- Cullen access: exact HTTP/HTTPS grants for both addresses in
  `tailscale/acl.hujson`, with deny tests for SSH and direct backend access.
- External recipients: existing `autogroup:shared → tag:share` HTTP/HTTPS grant;
  they must still accept a share of this specific node.

**Stop and remove the enrollment container before starting managed
`ts-readmeabook`**; never run two daemons against the same state. Persistent
`TS_AUTH_ONCE` preserves the enrolled identity across replacements. The owner
will share the node with their sister; no invitation has been sent. ReadMeABook
currently permits local registration without admin approval, so a recipient
with tailnet access can create their own account. Application API endpoints
still require authentication.

Deploy through signed Forgejo commits: doc1 installs/applies the ACL and doc2
runs the sidecars. Verify the persistent identity, DNS A/AAAA, HTTPS, login,
anonymous API denial, Caddy admin isolation, and the application deep probe.

Verified at 08:23 AWST on revision
`0d483573592102fcb3c818b21c696787d29a86ba` on both doc1 and doc2:

- The managed node retained the enrolled ID and both addresses; the temporary
  enrollment container was stopped and removed before deployment.
- Public DNS and pfSense return the sidecar A/AAAA. HTTPS health passed over
  IPv4 and IPv6 from doc1, and normal DNS/HTTPS and HTTP→HTTPS redirect passed
  from WSL on the Cullen laptop. Forced IPv6 from WSL could not connect; the
  laptop's working normal path used IPv4, while both address families are
  granted and IPv6 is independently verified from doc1.
- Local login, authenticated requests and retained ebook auto-grab settings
  passed. Anonymous requests/settings APIs return 401. The application deep
  probe passed after the switch; ABS and Komga remain active.
- Caddy runs as `2011:2011`, has only `NET_BIND_SERVICE` and `NoNewPrivs=1`;
  its admin port is unreachable from the Tailscale sidecar. Podman publishes
  the app only on `127.0.0.1:3031` and `10.88.0.1:3031`.
- The Tailscale policy validation API returned 200 and the applied policy
  semantically matches the committed file. The normal doc1 ACL unit applied it
  successfully; no manual-edit protection was disabled.

To share, select **readmeabook → Share** in Tailscale's Machines page and send
the recipient its invitation link. After accepting, they visit
<https://readmeabook.ablz.au> and register their own ReadMeABook account.
[Tailscale's sharing instructions](https://tailscale.com/docs/features/sharing#share-using-a-link).

Rollback the sidecar and Cullen additions through the verified deployment path,
restore the previous local-proxy entry, and remove the stale sidecar AAAA record
after the LAN A record is restored. Keep the sidecar state for future reuse.

### Chaptarr sample import

Independent copies of the existing Red Rising audiobook directory and Calibre
ebook directory were placed under `/audiobooks/Pierce Brown/Red Rising` and
`/ebooks/Pierce Brown/Red Rising`. The managed roots are unmonitored, with no
automatic acquisition. The full original collection is visible only under
`/existing/*`, read-only; it was not bulk imported.

The scan created Pierce Brown catalog records for both formats. It assigned 47
audio files to Red Rising, 81 to Golden Son, and one EPUB to the ebook Red Rising
record. The 80 catalog records include author metadata for books without files;
they are not 80 owned books. The 2026-09-15 ABS audit confirmed that the source
download is a two-book bundle with separate Red Rising and Golden Son folders,
so this split is consistent with the actual source layout. Only copied files
were used, so this trial cannot reorganize the original ABS library.

### Deployment lessons

The first switch exposed two local setup mistakes: database parent ownership
needed to permit the isolated DB service's traversal, and a space-bearing
systemd bind mapping needed quoting around the **source** path only. Both were
corrected in the service modules. Probes now wait for their application units and
exercise existing-table UPDATE authority in rolled-back transactions, avoiding
DDL that intentionally triggers the MariaDB audit alert.

Validation included a doc2 system build, `nix flake check --no-build`, formatting,
deadnix/statix and the recipient-scope, listener-bind, container-network, unit
hardening, error-pattern and secret-argv checks. Versions above are runtime image
versions, not assumptions from repository HEAD. The observed image revisions
were Booklore `58d3460eec68baac8450d062be7e3cdc0352f348`, ReadMeABook
`7c7d7bc7dd04c120d1ecffd5b48f37f0896a3a41`, and Chaptarr
`7d2a198661f0025d379807653cdc8f44c26ca5b4`; Bookkeep image ID was
`e3f04766947b39c7cf9bb71d1b17c4945cb8aa0483a5a1b4f44a250d301ba784`.

## How to compare them

1. Find several books that existed before these applications were installed.
   Check both search-result availability and any library-browse screen.
2. Find Red Rising: the existing audiobook and EPUB should be recognized as
   separate available formats of the same work, without new requests.
3. Choose a title with only one format. Check that the missing format can be
   requested without duplicating the existing one.
4. Evaluate metadata matching for editions, narrators and books without ISBNs.
   Count unmatched entries instead of accepting a successful sync status.
5. Exercise one explicitly selected request through each downloader, then verify
   the physical file and the reader backend. A completed download is not proof
   that the reader has indexed it.
6. Add/remove a copied trial item outside the requesting app; check whether
   availability updates and stale ownership clears. Do not delete originals.
7. Test Booklore OPDS in KOReader and compare browsing/search with Komga.

No date-driven decision is required. Record the user's impressions and measured
gaps here, then choose ownership and migration boundaries after exploration.

## Operations and rollback

Logs: `journalctl -u podman-chaptarr -u podman-booklore -u podman-bookkeep
-u podman-readmeabook`. Database logs use `container@<app>-db.service`.
Kuma monitors cover HTTP plus application-state/DB-write probes. Probe transactions
roll back; filesystem canaries are removed. Image references remain floating
per fleet policy, so capture the live image ID when reproducing a finding.

To retire a candidate, disable its `homelab.services.<name>.enable`, sign/push
and `fleet-deploy doc2`. Preserve its `/mnt/virtio/<name>` directory until the
user decides its requests/settings can be discarded. Revoke any trial-only API
accounts after retirement. The existing Shelfarr, Calibre, Komga and ABS services
remain enabled throughout this evaluation.
