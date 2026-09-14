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
  describes completed imports staying pending; [installation report #89](https://github.com/boludo00/bookkeep/issues/89)
  describes fresh database migration failures. These are open user reports,
  not failures reproduced during the initial research.
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

MariaDB (`booklore-db`, helper hostNum 11) and PostgreSQL (`bookkeep-db`, 12;
`readmeabook-db`, 13) have isolated state and service-only TCP credentials.
ReadMeABook uses internal Redis plus external PostgreSQL. Root entrypoint
capabilities are restricted to UID/ownership setup; applications run as dedicated
UIDs 2021–2024, never the operator's UID. No host control sockets or unrelated
libraries are mounted. Initial credentials are encrypted only to doc2, editor
and cold recovery recipients.

## Live verification and findings

Deployment and bootstrap in progress. Replace this paragraph with observed
versions, reachable endpoints, library counts, authentication checks and any
remaining setup limits before marking the work complete.

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
