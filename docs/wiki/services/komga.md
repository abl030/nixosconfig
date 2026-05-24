# Komga — wine magazine library

**Date written:** 2026-05-23
**Status:** ✅ deployed on doc2 at https://magazines.ablz.au since 2026-05-23
**Module:** `modules/nixos/services/komga.nix`
**Upstream:** `services.komga` (nixpkgs)
**Port:** 8089 (loopback only; surfaced via `homelab.localProxy.hosts`)
**State:** `/mnt/virtio/komga/` (SQLite + thumbnails + search index)

## Why Komga and not Kavita / Calibre-Web / ABS

Brief comparison decided on 2026-05-23:

* **Komga** — explicitly markets itself as a server for "comics, mangas, BDs,
  **magazines** and eBooks". Series → Book model maps cleanly onto
  Publication → Issue. Native upstream NixOS module. OPDS for KOReader.
  Reflowable EPUB reader in the web UI. ← **chosen**
* **Kavita** — slicker EPUB typography but treats periodicals as
  second-class. Book/Volume/Chapter model is Manga-flavoured.
* **Calibre-Web** — needs a pre-built Calibre `.db` (extra moving part), no
  periodical concept.
* **Audiobookshelf** — ebook support exists but is a side feature; no
  per-issue metadata UI.

If you ever reconsider, **the magazine-specific advantage matters less once
EPUB is the primary format** (since KOReader reads the EPUB's own nav doc
and Komga just needs to serve the file via OPDS). Kavita's EPUB UX edge
would tilt the choice if you ever want richer in-browser reading and aren't
using OPDS-only.

## Architecture

```
       /mnt/data/Media/Magazines/
       ├── GAW/2026/05_GW_MAY_2026-WEB.pdf
       ├── GAW/2026/05_GW_MAY_2026-WEB.json   ← sidecar (TOC, tags)
       ├── GAW/2026/05_GW_MAY_2026-WEB.epub   ← once marker batch finishes
       ├── WVJ/2024/V39-3_WVJ_Winter_24_FULL_ISSUE.pdf
       ├── ...
       │
       └── (read-only bind-mounted into komga.service)
                 ↓
       komga.service (nixos)  ← /mnt/virtio/komga/ (rw, SQLite + thumbnails)
                 ↓ :8089/actuator/health
       homelab.localProxy → nginx → magazines.ablz.au :443 (TLS via ACME)
                 ↓
       browser / KOReader (OPDS at /opds/v2)
```

The archive is **read-only** from Komga's perspective. The archiver scripts
own the write side; Komga only consumes.

## Libraries

Three libraries configured via REST API on first deploy:

| Library | ID (env-specific) | Root | Books | Source of truth |
|---|---|---|---|---|
| Grapegrower & Winemaker | `0QFB0VEFMZBE3` | `/mnt/data/Media/Magazines/GAW` | 107 PDFs (→ 214 once EPUBs land) | gwm-archiver + marker-batch |
| Wine & Viticulture Journal | `0QFB0WAJ0Z3KF` | `/mnt/data/Media/Magazines/WVJ` | 28 PDFs (→ 56) | wvj-archive + marker-batch |
| Calibre Library | `0QFQQFTD08FRG` | `/mnt/data/Media/Books/Calibre LIbrary` | 273 (228 EPUB + 45 PDF, 3.2 GB) | Calibre on the desktop |

Settings used at creation: `scanPdf=true`, `scanEpub=true`,
`scanForceModifiedTime=true`, `scanInterval=DAILY`, `scanOnStartup=true`,
`importLocalArtwork=true`, `analyzeDimensions=true`, `hashFiles=true`.
`hashKoreader` is set to true at creation (Calibre Library) or
auto-flipped on next komga-sync run (the magazine libraries pre-date
the [koreader-sync.md](./koreader-sync.md) work).

### Calibre Library specifics

- **Layout:** Calibre stores each book at
  `<Author>/<Title> (<calibre_id>)/<Book>.{epub,pdf}` plus `cover.jpg`
  and `metadata.opf`. Komga creates a series per `Title (id)`
  directory; Author dirs become parent series. Each leaf series has
  exactly one book.
- **Read-only by design.** The Komga unit binds the Calibre tree with
  `BindReadOnlyPaths` -- Calibre on the desktop is the canonical owner
  of metadata, conversions, and the OPF sidecar. Komga's only writes
  are inside its own stateDir (H2 DB, thumbnails, search index). If
  we ever want OPDS upload or Komga-side metadata edits, that fights
  Calibre's metadata management and we'd need to revisit. For now,
  Komga is purely a serve-side for OPDS access to KOReader on the
  Boox/phone.
- **Path has a literal space in `Calibre LIbrary`** (capital I in
  "LIbrary", that's the actual directory name). systemd
  `BindReadOnlyPaths` parses each line as whitespace-separated, so
  paths with spaces must be **double-quoted in the value** -- the
  `\x20` escape is NOT honoured for path entries (only for
  ExecStart-style args). Module handles this via `quotePathIfSpaced`.
- **KOReader sync works out of the box.** The library was created
  with `hashKoreader=true`, so partial-MD5 hashes are populated as
  Komga analyzes each book. KOReader on Boox/phone can pull and push
  progress for any Calibre EPUB the same way it does for magazines.

## Surprising facts

### 1. PDF + EPUB of the same issue = two separate books

Komga does NOT auto-group `<basename>.pdf` and `<basename>.epub` into one
"multi-format book". They appear as two separate cards in the same
year-series. By design (the user explicitly wanted both visible —
"epub is always going to be flakey").

If you ever want to hide PDFs and show only EPUBs, flip the library's
`scanPdf` to `false` — files stay on disk untouched, Komga just stops
indexing them. (And vice versa.)

### 2. Year directories become individual series

Komga inferred a series per year directory (`GAW/2024/`, `GAW/2025/`, etc.)
rather than one big "Grapegrower & Winemaker" series. So GAW has 10
year-series; WVJ has 9.

Pros: natural drill-down (publication → year → issue), and Komga's
`numberSort` works cleanly within a year-series.

Cons: no single timeline view across years. To fix, you'd either flatten
the directory tree (move every PDF to `GAW/` and `WVJ/` directly — breaks
the gwm-archiver output convention) or use Komga's `oneshotsDirectory`
config. We've stuck with the year-series layout because the operational
cost of flattening outweighs the UX gain.

### 3. PDFs have no metadata until you sync

Komga reads ZERO metadata from PDF files — no internal dict, no bookmarks,
no loose sidecar XML. The `komga-sync.service` daily timer is what makes
the library actually useful — see [komga-sync.md](./komga-sync.md).

EPUBs are different: Komga reads OPF metadata natively. The marker
post-processor (`scripts/marker-to-epub.py`) writes rich OPF, so the EPUB
flavour of each issue arrives with metadata baked in.

### 4. PDFs show blank thumbnails until Komga generates them

`analyzeDimensions=true` at library-create time doesn't trigger page-1
thumbnail rendering. PDFs look like blank cards in the library grid until
Komga reads each one once (either by a user opening it, or by hitting
`POST /api/v1/books/{id}/analyze` per book). EPUBs use their embedded
cover. **Workaround:** open each PDF once in the Komga reader, or write a
batch hit-`/analyze` script if it bothers you.

### 5. Komga lowercases all tags and genres

Tags `"AWRI"` become `"awri"` in storage. The `komga-sync` script
normalises before comparing to avoid spurious PATCHes.

## Sandbox — narrow `/mnt` visibility

The upstream module gives Komga `ProtectSystem=full` but leaves `/mnt`
fully visible. Our module wraps the unit in:

```nix
TemporaryFileSystem = "/mnt";
BindReadOnlyPaths = libraryRoots;     # magazines + Calibre Library
BindPaths = [ cfg.dataDir ];          # /mnt/virtio/komga, rw
```

`libraryRoots` is a list assembled in the module's `let` block.
Adding a new library root is a one-line append. Paths containing
whitespace must be double-quoted (handled by `quotePathIfSpaced`).

Per the [Sandbox patterns rule](../nixos-service-modules.md):

* `BindReadOnlyPaths` is **fail-loud** (`status=226/NAMESPACE`) on stale
  NFS, surfaced via the `Failed at step NAMESPACE` errorPattern alert
* `BindPaths` (writable) is required for `cfg.dataDir` because the
  `TemporaryFileSystem` masks all of `/mnt/virtio/`. Caught during initial
  deploy: Komga's logback + sqlite-jdbc both failed to open files under
  the masked stateDir. 13 crash-loops before I figured it out.

## Monitoring

| Layer | What | Alert |
|---|---|---|
| Shallow | Kuma checks `https://magazines.ablz.au/actuator/health` every 60 s | DOWN after 10 consecutive failures (~10 min) |
| errorPattern | `OutOfMemoryError\|java.lang.OutOfMemoryError` | critical, threshold=0 (single-shot) |
| errorPattern | `(?i)(library scan for .* failed\|error scanning\|book analysis failed)` | warning, default threshold |
| errorPattern | `Failed at step NAMESPACE` | critical, threshold=0 (bind-mount failure on stale NFS) |

No `deepProbe` — justified inline in the module: Komga is read-only against
the archive, there's no user-driven write path that could rot silently the
way Immich's `asset_edit_audit` did (#250). If a future feature changes
this (e.g. ComicInfo writes back into the library), add one.

## Deployment runbook (just-in-case)

```bash
# Edit the module
$EDITOR modules/nixos/services/komga.nix

# Build locally to eval
nix build .#nixosConfigurations.doc2.config.system.build.toplevel --dry-run

# Ship it
git add ... && git commit && git push
ssh doc2 sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh

# Tail logs after deploy
ssh doc2 journalctl -fu komga

# REST API quick sanity
KEY="$(sops -d secrets/hosts/doc2/komga-sync.env | grep KOMGA_API_KEY | cut -d= -f2-)"
curl -sS -H "X-API-Key: $KEY" https://magazines.ablz.au/api/v1/libraries
```

## API key rotation

The current key was minted via the Komga UI on 2026-05-23 and committed to
sops at `secrets/hosts/doc2/komga-sync.env`. It was also pasted in chat
during bootstrap → **rotate it** at convenience:

1. Komga UI → Account → Manage API keys → revoke `komga-sync` (or whatever
   you named it) → create a new one.
2. `cd secrets && sops hosts/doc2/komga-sync.env` (your `dc` alias) and
   replace the `KOMGA_API_KEY=` line.
3. `git push && ssh doc2 sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh`
   so the new secret lands.
4. Next `komga-sync.service` fire uses the new key. No service restart needed.

## See also

* [magazines.md](./magazines.md) — overview hub
* [komga-sync.md](./komga-sync.md) — metadata sync via REST (also auto-enables `hashKoreader` on every library)
* [koreader-sync.md](./koreader-sync.md) — cross-device read-position sync via Komga's `/koreader` endpoint
* [magazine-epub-pipeline.md](./magazine-epub-pipeline.md) — why we make EPUBs
* Komga official docs: https://komga.org/docs/
* Komga OpenAPI: https://komga.org/docs/openapi/
