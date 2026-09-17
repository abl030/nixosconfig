# Physical audio CD ingestion

**Status:** operational runbook
**Last verified:** 2026-09-17
**Scope:** identify and de-duplicate → correct upstream metadata → secure FLAC rip → CrateDigger import and verification

The durable result is the exact release described correctly upstream and the
verified FLAC album imported through CrateDigger. Scans, rip logs, checksums,
browser handoffs, and receipts are working material, not a second permanent
archive. Keep them only until the final library result is verified.

## Invariants

- Physical-CD intent is lossless FLAC unless the user explicitly asks otherwise.
- De-duplicate before contributing: MusicBrainz release and Disc ID, Cover Art
  Archive, LRCLIB, AccurateRip/CTDB, the Beets library, and active CrateDigger
  requests.
- A matching TOC identifies audio layout, not necessarily the pressing. Confirm
  barcode, catalogue number, label, country/date, packaging, and matrix text where
  available.
- Correct upstream gaps instead of creating duplicate releases, art, lyrics, or
  CTDB entries.
- CrateDigger owns the Beets import and provenance. Never use ad-hoc `beet import`.
- Do not use `pipeline-cli replace` to swap a library copy for this pressing. Use
  exact guarded deletion followed by the physical release's own request/import.
- Preserve unknown facts as unknown. Never infer a barcode, date, or pressing
  identity from silence.

## 1. Identify and audit

Capture or fetch enough package evidence to identify the pressing and fill real
upstream gaps: front, back, disc face and hub, full track list, booklet, lyrics,
and all credits, catalogue, barcode, and copyright panels. When the evidence is
in Paperless or Immich, fetch the exact original read-only rather than a preview,
thumbnail, or screenshot.

Keep every source file unchanged. Put upload derivatives in a separate directory
and prepare them losslessly: apply the correct page rotation, deskew against the
printed page or artwork edge, and crop tightly to that edge. Do not treat PDF or
EXIF orientation metadata as proof that the pixels are upright. Render and inspect
every derivative at useful resolution before handoff, checking readable text,
page order, all four crop edges, and that no scanner bed, adjacent page, or jewel
case remains unless it is intentionally part of the image. Do not open the CAA
upload handoff until that visual review passes.

Do not rescan a long booklet when the existing Cover Art Archive booklet matches
the physical copy. Download the existing CAA original, compare its cover,
catalogue number, track list, credits, and page count with the package, and scan
only missing or materially better panels. A PDF can contain two printed pages per
PDF page, so compare the rendered content rather than assuming the page count is
wrong.

Check the existing Beets album and CrateDigger request, then audit public
MusicBrainz separately by title and Disc ID. The local MusicBrainz mirror is
normally up to 24 hours behind public MusicBrainz, so public is authoritative for
edits made during the session.

Inspect the disc without mounting it and read its TOC:

```bash
lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN,HOTPLUG
udevadm info --query=all --name=/dev/sr0

nix shell --impure --expr \
  'with import <nixpkgs> {}; python3.withPackages (ps: [ ps.discid ])' \
  --command python - <<'PY'
import discid
d = discid.read('/dev/sr0')
print('MusicBrainz Disc ID:', d.id)
print('TOC:', d.toc_string)
print('Attach URL:', d.submission_url)
PY
```

Check both lookup paths; a 404 Disc ID can still belong to an existing release:

```bash
curl -fsS -A 'nixosconfig-disc-archive/1.0 (https://git.ablz.au/abl030/nixosconfig)' \
  "https://musicbrainz.org/ws/2/discid/<DISC_ID>?inc=artists+recordings+release-groups&fmt=json"

curl -fsS -A 'nixosconfig-disc-archive/1.0 (https://git.ablz.au/abl030/nixosconfig)' \
  --get 'https://musicbrainz.org/ws/2/release/' \
  --data-urlencode 'query=release:"<TITLE>" AND tracks:<COUNT>' --data 'fmt=json'
```

Once the exact pressing is confirmed, ask whether it should replace the current
library copy. A yes authorises the guarded replacement sequence in section 5,
after an independent staging copy exists and verifies.

## 2. Secure-rip to temporary working space

Verify the drive and AccurateRip offset. The known offset for
`HL-DT-ST DVDRAM GP65NB60` is `+6`; do not reuse it for another model without
checking.

```bash
nix shell nixpkgs#whipper --command whipper drive list
nix shell nixpkgs#whipper --command whipper drive analyze -d /dev/sr0
```

Keep the active session under `~/Downloads`, not `/var/tmp`, so it is visible to
the operator. It is temporary working state:

```bash
install -d -m 0700 "$HOME/Downloads/cd-archive-<slug>/output" \
  "$HOME/Downloads/cd-archive-<slug>/work"
nix shell nixpkgs#whipper --command whipper cd rip \
  --unknown --offset <OFFSET> --max-retries 20 --keep-going \
  --output-directory "$HOME/Downloads/cd-archive-<slug>/output" \
  --working-directory "$HOME/Downloads/cd-archive-<slug>/work" \
  --track-template '<Title>/%t - Track %t' \
  --disc-template '<Title>/<Title>'
```

Review every track in the log for test/copy agreement, read errors, offset, cache
behaviour, and AccurateRip/CTDB results. Then run `flac -t` on every output file.
Do not import a suspicious rip. Keep the log and cue only until CrateDigger has
verified the imported album.

## 3. Correct MusicBrainz, artwork, and lyrics

### MusicBrainz

If the exact release exists, attach the Disc ID to its matching CD medium. If it
does not, build a release spec from physical evidence and use the repository
helper:

```bash
python3 scripts/musicbrainz-release-seed.py /path/to/release.json \
  "$HOME/Downloads/cd-archive-<slug>/<slug>-musicbrainz.html"
```

Use `.claude/skills/physical-cd-archive/references/release-spec.example.json` as
the schema. The TOC belongs in `mediums.0.toc`. In the editor, every release and
track artist must resolve green to the correct entity; never choose a namesake or
Various Artists merely to satisfy validation.

An ordinary existing-release `/edit` link seeds nothing and will submit “no
changes.” A handoff may POST safe release-level fields such as `events.0.*` and
`edit_note` to `/release/<MBID>/edit`. Do not POST a partial `mediums.*` array to
change one track because it replaces the loaded tracklist; edit isolated track
titles in the loaded editor instead.

Votable edits are non-gating. Record the intended values and continue. Both
CrateDigger request creation and import can use public MusicBrainz without waiting
for the local mirror:

```bash
sudo -n bash -c '
  set -a
  source /run/secrets/cratedigger-pgpass
  set +a
  /path/to/nixosconfig/scripts/cratedigger-add-upstream-musicbrainz.sh <RELEASE_MBID>
'
```

Use `--upstream-musicbrainz` on the later `import-local` job. Never change the
service-wide metadata source for one fresh release.

If pending MusicBrainz data gives the exact imported album a wrong fallback value
(for example the release-group year), correct only the evidenced fields after the
strict import. Keep the exact release/recording MBIDs and do not use
`pipeline-cli replace`:

```bash
beet modify -a -m -y year=<YYYY> month=<MM> day=<DD> \
  original_year=<YYYY> original_month=<MM> original_day=<DD> id:<BEETS_ALBUM_ID>
beet modify -m -y 'title=<EVIDENCED_PENDING_TITLE>' \
  album_id:<BEETS_ALBUM_ID> track:<TRACK_NUMBER>
```

Re-read the files afterward to confirm the corrected values and retained MBIDs,
lyrics, artwork, and FLAC integrity.

### Cover Art Archive

Audit both the release and release-group inventories before uploading. Upload only
missing or materially better images from this exact physical package, with
accurate types (`Front`, `Back`, `Booklet`, `Medium`, `Spine`). Do not attach one
pressing's artwork to another release merely because their audio layout matches,
and do not duplicate a good front or a complete matching booklet.

For every upload, retain the unmodified source, the visually reviewed derivative,
its checksum, and the resulting CAA URL or response together until final library
verification. Pending approval is non-gating, but a file that has not passed the
orientation, deskew, crop, and pressing-identity checks is not ready to upload.

### Lyrics

Lyrics are part of the normal ingestion flow. Search local and public LRCLIB by
exact artist, album, title, and duration. If missing and public contribution is
authorised, transcribe from the booklet, proofread against the rendered page and
audio, and publish with the repository helper. For multilingual layouts, publish
only the words actually sung; do not interleave printed translations.

```bash
python3 scripts/lrclib-publish.py /path/to/lyrics-manifest.json /path/to/receipts
python3 scripts/lrclib-publish.py /path/to/lyrics-manifest.json /path/to/receipts --publish
```

Publish to the local LRCLIB instance as well when Beets needs the lyrics in the
same session. HTTP 201 is the accepted-write result; immediate `/api/get` or
search visibility may be stale, so do not republish solely because read-after-
write misses. Embed the reviewed `LYRICS` text in the staging FLACs so the import
does not depend on LRCLIB freshness.

## 4. AccurateRip and CTDB

Query CTDB before trying to contribute. An existing matching entry is verification
evidence and must not receive a duplicate submission. CTDB confidence is
independent accepted corroboration; a second local read does not increase it.

CrateDigger verifies imported PCM against CTDB but does not submit. Whipper also
does not submit to CTDB. For a genuinely absent entry, use CUERipper in Secure or
Paranoid mode. Upstream CUETools 2.2.6's WinForms GUI calls `CTDB.Submit`; its
console frontend does not, so a zero-error console log is not a contribution.
Treat submission as successful only when the response reports success and a fresh
lookup returns the rip CRC. Never force an ineligible image or invent confidence.

## 5. Import through CrateDigger

Tag an independent copy of the FLACs with useful basic identity and reviewed
lyrics. Copy that album—not the Beets library or CrateDigger processing tree—to:

```text
/mnt/virtio/cd-import/<slug>/
```

Confirm the staging copy still has every FLAC and passes `flac -t`. Create or
resume the exact request, set lossless intent, and enqueue the local source:

```bash
pipeline-cli add <RELEASE_MBID>
pipeline-cli set-intent <REQUEST_ID> lossless
pipeline-cli import-local <REQUEST_ID> /mnt/virtio/cd-import/<slug> \
  --upstream-musicbrainz
```

Follow the existing job rather than enqueueing another:

```bash
pipeline-cli show <REQUEST_ID>
pipeline-cli import-jobs --limit 10
pipeline-cli quality <REQUEST_ID>
journalctl -u cratedigger-import-preview-worker -u cratedigger-importer \
  --since '15 minutes ago' --no-pager
```

### Guarded replacement of an existing copy

After the user has said yes, resolve the old album by Beets album ID and release
MBID—not by title text. Verify the independent staging copy before deletion:

```bash
pipeline-cli library-delete <OLD_BEETS_ALBUM_ID> --confirm DELETE \
  --release-id <OLD_RELEASE_MBID>

test ! -e /mnt/virtio/Music/Beets/<old-path>
find /mnt/virtio/cd-import/<slug> -type f -iname '*.flac' | wc -l
pipeline-cli set <REQUEST_ID> wanted
pipeline-cli set-intent <REQUEST_ID> lossless
pipeline-cli import-local <REQUEST_ID> /mnt/virtio/cd-import/<slug> \
  --upstream-musicbrainz
```

Add `--pipeline-id <OLD_REQUEST_ID>` to `library-delete` only when the old Beets
album has an owning pipeline row. This workflow deliberately does not use
`pipeline-cli replace`, which changes request identity rather than replacing the
on-disk library copy with the already identified physical release.

## 6. Completion and cleanup

The job is complete when:

- the upstream MusicBrainz release/Disc ID and package metadata describe the
  physical pressing, with pending votable corrections accounted for;
- missing CAA art and authorised lyrics were contributed without duplicates;
- the exact CrateDigger request is `imported` and points to one unique Beets album;
- every expected library file is FLAC and passes `flac -t`;
- every file carries the exact release MBID, reviewed lyrics, and intended date;
- `pipeline-cli quality` reports the real AccurateRip/CTDB provenance and lossless
  result; and
- media refresh completed or has a recorded retryable warning.

Once those checks pass, remove the disposable `/mnt/virtio/cd-import/<slug>` copy
and the corresponding `~/Downloads/cd-archive-<slug>` working directory. Do not
create or maintain a second `/mnt/virtio/Music/Preservation` copy.

## Failure handling

- Wrong MusicBrainz data: correct the same release; do not create a duplicate.
- Wrong CAA upload: request correction/removal and upload only to the exact release.
- Wrong LRCLIB text: publish a reviewed revision rather than duplicating the entry.
- Suspicious or mismatched rip: clean/inspect and rerip; do not import it.
- CTDB says insufficient quality: stop; do not bypass the gate.
- CrateDigger rejects identity: correct metadata/tags and retry the guarded workflow;
  never call Beets directly for the import.
- Ambiguous import outcome: inspect the request, job, and logs before retrying.
