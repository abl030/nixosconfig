# Book platform exploration

Date: 2026-09-14. Status: parallel evaluation; no winner selected and no migration
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
normal fleet update policy. No Tailscale nodes, sharing rules, DNS records or
reverse proxies are introduced. Application listeners bind doc2's LAN address
and loopback, not its tailnet address.

| Application | LAN URL | Persistent state | Role |
| --- | --- | --- | --- |
| Chaptarr | <http://192.168.1.35:8789> | `/mnt/virtio/chaptarr` | Collection manager |
| Booklore | <http://192.168.1.35:6060> | `/mnt/virtio/booklore` | Ebook catalog/OPDS |
| Bookkeep | <http://192.168.1.35:8788> | `/mnt/virtio/bookkeep` | Request/discovery portal |
| ReadMeABook | <http://192.168.1.35:3031> | `/mnt/virtio/readmeabook` | ABS-aware request portal |

Administrator username is `abl030` after bootstrap. Initial passwords are
separate random values in the operator-only SOPS secret. Recover one on doc2:

```sh
sudo jq -r '.booklore.password' /run/secrets/book-trials/bootstrap
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

Use the LAN IP for these trial URLs, including Bookkeep's Booklore connection.
Inside the OCI container, `doc2` resolved to inherited loopback `127.0.0.2`,
while `doc2.ablz.au` hit the wildcard legacy proxy. The module derives the LAN
address from `homelab.localProxy.localIp`; no new DNS arrangement is needed.

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
The final LAN endpoint and credential revision
`785bf596523450d83ea7570292bcbbb5d929d152` was verified running on doc2.
Anonymous requests to protected APIs returned 401/403 in all four apps. Their
ports were reachable on the LAN address and not on doc2's tailnet address;
existing-library mounts were confirmed read-only in the running containers.

| Application | Observed version | What is usable now |
| --- | --- | --- |
| Booklore | v2.3.1 | Existing library indexed: **280 ebooks**; browser catalog and authenticated OPDS download verified. |
| Bookkeep | v1.6.2 | Both integrations configured. Its own connector endpoints return **280 Booklore books** and **214 ABS items**. Discovery still requires a Hardcover API token. |
| ReadMeABook | v1.2.2 | ABS scan imported **214 items**; remote Red Rising search works. Homepage refresh was triggered. |
| Chaptarr | 0.9.911.0, develop | Remote metadata search works; copied Red Rising EPUB/audio were scanned into the catalog. |

These are library/UI trials. New acquisition pipelines are not yet enabled or
proven. Chaptarr and Bookkeep have no download clients/indexers configured.
ReadMeABook has Prowlarr configured and a **disabled** qBittorrent placeholder;
its `/downloads` and `/media` are isolated trial storage, not the production
download-client paths. Wire and test paths, categories, credentials and final
reader import before enabling a chosen candidate's downloader. Existing
acquisition continues through Shelfarr.

### Booklore and OPDS

Library 1, **Existing ebooks (read-only trial)**, scans `/books/existing` with
`watch=false`, `PREFER_SIDECAR` metadata and `BOOK_PER_FOLDER` organization.
`DISK_TYPE=NETWORK` is backed by an actual read-only bind mount. Its 280 detected
books differ from Calibre's 282 records; the two-record discrepancy has not yet
been audited and should not be assumed to be a sync success.

OPDS is enabled at <http://192.168.1.35:6060/api/v1/opds>. OPDS username is
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

Red Rising search still reports `isAvailable=false`, despite the ABS entry being
present. That entry has neither ASIN nor ISBN; the reviewed ReadMeABook matcher
depends on ASIN/work identity. This is a concrete false-negative case to evaluate,
not proof that the ABS scan failed. Original ABS metadata was left unchanged.

### Chaptarr sample import

Independent copies of the existing Red Rising audiobook directory and Calibre
ebook directory were placed under `/audiobooks/Pierce Brown/Red Rising` and
`/ebooks/Pierce Brown/Red Rising`. The managed roots are unmonitored, with no
automatic acquisition. The full original collection is visible only under
`/existing/*`, read-only; it was not bulk imported.

The scan created Pierce Brown catalog records for both formats. It assigned 47
audio files to Red Rising, 81 to Golden Son, and one EPUB to the ebook Red Rising
record. The 80 catalog records include author metadata for books without files;
they are not 80 owned books. Inspect the split audio assignment against file tags
and actual content before accepting its ownership display. Only copied files
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
