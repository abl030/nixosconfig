# Physical audio CD preservation

**Status:** operational runbook
**Last verified:** 2026-09-17
**Scope:** secure FLAC rip → MusicBrainz Disc ID/release → CTDB contribution → CrateDigger local import → Beets

This is the durable workflow for a physical CD that is rare, private-label, or absent from public metadata. It preserves the audio, the physical evidence, the exact pressing identity, and CrateDigger's import/provenance trail.

## Invariants

- Treat the disc, packaging photos, TOC, rip log, cue sheet, FLACs, checksums, and external database responses as one preservation bundle.
- A MusicBrainz title search and a Disc ID lookup answer different questions. Check both. Different pressings can have different Disc IDs; a Disc ID can also collide.
- Correct the drive read offset during extraction. For `HL-DT-ST DVDRAM GP65NB60`, AccurateRip's drive table lists `+6`; verify the current drive model and table rather than copying that value to another drive.
- CTDB confidence is independent corroboration recorded by CTDB. A local secure reread proves consistency but does not let us claim a made-up confidence of two.
- CrateDigger owns the final Beets import. Do not bypass its request, validation, evidence, and audit trail with an ad-hoc `beet import`.
- Preserve unknown facts as unknown. Do not infer a release date, catalog number, or barcode from silence; `barcode=none` requires physical evidence that the package has no barcode.

## 1. Capture evidence and identify the disc

Photograph at least the front, back, disc face, full track list, and all credits/catalog/barcode/copyright panels. If the user says the latest Immich assets are the evidence, query the latest non-deleted `IMAGE` assets read-only, then inspect the originals rather than thumbnails.

Inspect the inserted medium without mounting it:

```bash
lsblk -o NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,MOUNTPOINTS,MODEL,TRAN,HOTPLUG
udevadm info --query=all --name=/dev/sr0
```

Read the MusicBrainz Disc ID and submission URL with libdiscid:

```bash
nix shell --impure --expr \
  'with import <nixpkgs> {}; python3.withPackages (ps: [ ps.discid ])' \
  --command python - <<'PY'
import discid
d = discid.read('/dev/sr0')
print('MusicBrainz Disc ID:', d.id)
print('FreeDB ID:', d.freedb_id)
print('TOC:', d.toc_string)
print('Attach URL:', d.submission_url)
PY
```

Check the exact Disc ID (404 means unattached/absent), then search by title/artist in case the release exists under another pressing:

```bash
curl -fsS -A 'nixosconfig-disc-archive/1.0 (https://git.ablz.au/abl030/nixosconfig)' \
  "https://musicbrainz.org/ws/2/discid/<DISC_ID>?inc=artists+recordings+release-groups&fmt=json"

curl -fsS -A 'nixosconfig-disc-archive/1.0 (https://git.ablz.au/abl030/nixosconfig)' \
  --get 'https://musicbrainz.org/ws/2/release/' \
  --data-urlencode 'query=release:"<TITLE>" AND tracks:<COUNT>' --data 'fmt=json'
```

Respect MusicBrainz's one-request-per-second public API limit. Prefer the local mirror for bulk work, but confirm the public site before concluding a new edit is needed.

## 2. Secure-rip to FLAC

Check the drive and its cache behaviour once:

```bash
nix shell nixpkgs#whipper --command whipper drive list
nix shell nixpkgs#whipper --command whipper drive analyze -d /dev/sr0
```

Use an explicit, private staging root with ample space. If MusicBrainz already has the exact release, pass `--release-id`. If it does not, rip with `--unknown`, simple deterministic filenames, and tag after the MusicBrainz edit exists.

```bash
install -d -m 0700 /var/tmp/cd-archive-<slug>/output /var/tmp/cd-archive-<slug>/work
nix shell nixpkgs#whipper --command whipper cd rip \
  --unknown --offset <OFFSET> --max-retries 20 --keep-going \
  --output-directory /var/tmp/cd-archive-<slug>/output \
  --working-directory /var/tmp/cd-archive-<slug>/work \
  --track-template '<Title>/%t - Track %t' \
  --disc-template '<Title>/<Title>'
```

Do not accept a merely completed command as proof. Review the log for every track, suspicious positions, cache defeat, read offset, test/copy agreement, and AccurateRip/CTDB result. Then verify FLAC integrity and write a preservation manifest:

```bash
flac -t /var/tmp/cd-archive-<slug>/output/<Title>/*.flac
sha256sum /var/tmp/cd-archive-<slug>/output/<Title>/* \
  > /var/tmp/cd-archive-<slug>/output/<Title>/SHA256SUMS
```

If the disc is absent from AccurateRip and CTDB, Whipper cannot provide third-party verification; its secure rereads and log are the local evidence. Record that honestly.

## 3. Add or attach MusicBrainz metadata

If the release exists, open the libdiscid attach URL, search by the exact release MBID, select the matching CD medium, review track count/durations, and submit the attachment edit.

If the release does not exist, create a JSON spec from the physical evidence and generate a local HTML handoff:

```bash
python3 scripts/musicbrainz-release-seed.py /path/to/release.json \
  "$HOME/Downloads/<slug>-musicbrainz.html"
```

Copy `.claude/skills/physical-cd-archive/references/release-spec.example.json` as the starting schema. Omit unknown optional fields rather than retaining example values. An artist credit takes either a verified `mbid` plus optional `credited_name`, or an `artist_name` that the editor will require the operator to resolve or create.

The script validates the TOC against the track count, derives exact disc durations, and seeds `mediums.0.toc`. Open the HTML in the browser where the user is logged into MusicBrainz, press the button, resolve any unmatched artist/label names, review all tabs, add the evidence-based edit note, and enter the edit. The HTML itself carries no MusicBrainz cookie or credential.

Every album and track artist field must resolve to a MusicBrainz entity: its background must be green. For a seeded name whose field stays uncoloured, click the magnifying glass and choose the correct match. If careful identity checking finds no existing artist, choose **Add a new artist** at the bottom of that search drop-down, create the artist from packaging evidence, and return to the release editor. Never select a same-name artist merely to satisfy validation, and never replace an evidenced track artist with Various Artists.

For several genuinely missing artists, research identity evidence first and use the separate batch helper instead of repeatedly typing MusicBrainz's artist form:

```bash
cp .claude/skills/physical-cd-archive/references/artist-spec.example.json \
  /var/tmp/<slug>-artists.json
$EDITOR /var/tmp/<slug>-artists.json
python3 scripts/musicbrainz-artist-seeds.py /var/tmp/<slug>-artists.json \
  "$HOME/Downloads/<slug>-musicbrainz-artists.html"
```

Each button opens one pre-filled artist editor in a new tab. The helper seeds the required name, person sort name, disambiguation, type, area search, evidence-based edit note, and any `external_links`. Each external link requires both its URL and the current numeric MusicBrainz artist-URL `link_type_id`; for example, official homepage is `183` and Bandcamp is `718`. Verify current IDs on MusicBrainz's relationship-type documentation instead of guessing. Evidence URLs are displayed for review but are not external artist links unless they are also listed under `external_links`. The helper does not enter the edit. Submit and close each artist tab, then use the magnifying glass in the still-open release editor to select the new entity. Keep disambiguations short and identity-specific; put fuller sourcing in the edit note. Add only facts supported by the physical package, an official artist page, or another reliable source.

Recommended evidence note shape:

```text
Entered from the physical CD and complete packaging in hand. Track titles,
credits, packaging and no-barcode status transcribed from the release. Exact
CD TOC read from /dev/sr0 with libdiscid; secure rip retained with log/cue.
```

MusicBrainz's seeding fields are documented at `Development/Seeding/Release_Editor`; the repository helper deliberately uses its POST interface rather than browser automation. The resulting release editor is still authoritative—correct anything the physical package disproves.

After submission, record the release MBID and confirm the public API returns the new release with the expected Disc ID. Public MusicBrainz and the local mirror may lag each other. For an ordinary import, wait until the configured mirror resolves the MBID. When preservation work must continue immediately, use CrateDigger's per-job live-MusicBrainz opt-in described below; do not change the service-wide mirror.

## 4. Contribute the secure rip to CTDB

CrateDigger's `CD bit-verified · CTDB confidence N` is a verifier display: it reads CTDB and compares whole-disc PCM. It does not submit library albums to CTDB.

Query CTDB before and after contribution using a zero-based TOC (subtract the first audio offset, normally 150, from every physical offset and leadout):

```text
https://db.cue.tools/lookup2.php?version=3&ctdb=1&fuzzy=1&metadata=default&toc=0:<offset2>:...:<leadout>
```

Use CUERipper in **Secure** or **Paranoid** mode for a new physical-disc submission. Burst mode is explicitly ineligible. Retain its extraction log and the CTDB response/query as evidence.

Do not assume every CUERipper frontend submits. In upstream CUETools 2.2.6 the WinForms GUI calls `cueSheet.CTDB.Submit(...)` after `cueSheet.Go()`, but `CUETools.Ripper.Console.exe` stops after writing the image, cue, and log. A console result such as `00000 errors` is strong local rip evidence but is **not** a CTDB receipt. A headless workflow must explicitly add/call the same upstream sequence after the audio has been fed into `AccurateRipVerify`:

```csharp
ctdb.DoVerify();
var response = ctdb.Submit(confidence, quality, artist, title, barcode);
```

Treat the submission as successful only when the returned response reports success and a fresh `lookup2.php` query returns an entry matching the rip CRC. Preserve both response and lookup body. If using an opt-in patched console, keep submission disabled by default and require a flag such as `--submit-ctdb`; never make an ordinary diagnostic rip mutate the public database silently.

For an already-ripped image, CUETools Verify can submit only when the image has AccurateRip confidence at least two and CTDB has no prior entry. Do not try to force an ineligible Whipper-only image into the service. Official behaviour and current settings are documented at:

- <https://cue.tools/wiki/CUETools_Database>
- <https://cue.tools/wiki/CUERipper_Settings>
- <https://cue.tools/wiki/CUETools_Advanced_Settings:_Advanced>

One accepted submission usually begins at confidence one. Confidence two requires an independent accepted contribution under CTDB's anti-duplication rules; a second read on the same machine/drive is useful local evidence but must not be described as independent CTDB confidence.

Verified example (2026-09-17): the first accepted Winesong submission returned token `blokBmSfz6482Kddw08mggWvxq4-`; the immediate public lookup returned entry `13063896`, CRC32 `af764d8f`, parity present, confidence `1`. This is the expected first-contribution result and is the pattern to preserve as a receipt.

## 5. Tag and stage for CrateDigger

Once the MusicBrainz release exists, give the staging FLACs evidence-based basic tags (`ALBUM`, `ALBUMARTIST`, `TITLE`, `ARTIST`, `TRACKNUMBER`, `TRACKTOTAL`) so CrateDigger's strict candidate comparison has useful source metadata. `metaflac` is sufficient. Do not run an ad-hoc `beet import`: CrateDigger's exact request supplies the release MBID and its importer owns the authoritative Beets tagging and library move. Picard may be used against the exact release, but is optional.

Before staging, confirm every file has the expected basic identity:

```bash
metaflac --show-tag=ALBUM --show-tag=ALBUMARTIST \
  --show-tag=TITLE --show-tag=ARTIST --show-tag=TRACKNUMBER \
  /path/to/album/*.flac
```

Copy the complete album directory to a dedicated operator-owned staging path visible to doc2, for example `/mnt/virtio/cd-import/<slug>`. Do not use `/tmp`, `/home`, the Beets library, CrateDigger processing, slskd downloads, or the Beets DB tree. Copy first, then compare manifests at both ends before importing.

The local-import folder is disposable transport, not the long-term preservation bundle. Store the physical photos, corrected upload art, MusicBrainz/CAA responses, Whipper FLAC/cue/log/TOC and pre/post-tag hashes, CUETools image/cue/log, CTDB submit receipt and post-submit lookup beneath:

```text
/mnt/virtio/Music/Preservation/<slug>--<MUSICBRAINZ_RELEASE_MBID>/
```

Use separate `evidence/`, `whipper-secure-rip/`, and `cuetools-ctdb-submit/` directories. After copying, use an `rsync -acn --delete --itemize-changes` dry run from the source to the durable path; any output means the archive is not yet byte-for-byte complete. Do not remove the local source until the durable path is covered by a completed backup.

## 6. Import through CrateDigger and verify Beets

On doc2, create or resume the exact MusicBrainz request and note its request ID:

```bash
pipeline-cli add <MUSICBRAINZ_RELEASE_MBID>
pipeline-cli list
pipeline-cli show <REQUEST_ID>
```

Set the output contract before queueing a preservation rip so CrateDigger retains FLAC rather than applying the usual V0 policy:

```bash
pipeline-cli set-intent <REQUEST_ID> lossless
```

Queue the immutable local source through the configured `/mnt/virtio` lane:

```bash
pipeline-cli import-local <REQUEST_ID> /mnt/virtio/cd-import/<slug>
```

If the release is live on public MusicBrainz but has not yet reached the local mirror, opt only this immutable job into the upstream metadata source:

```bash
pipeline-cli import-local <REQUEST_ID> /mnt/virtio/cd-import/<slug> \
  --upstream-musicbrainz
```

The flag is persisted in the local-import job and is forwarded through preview, strict pressing validation, Discogs retry, and the final Beets import. A retry therefore cannot silently change metadata authority. Requeueing the same active request with a different path or upstream mode is rejected as a conflict. Omit the flag once the mirror has caught up.

This is asynchronous. Follow the exact request/job rather than repeatedly enqueueing it:

```bash
pipeline-cli show <REQUEST_ID>
pipeline-cli import-jobs --limit 10
pipeline-cli quality <REQUEST_ID>
journalctl -u cratedigger-import-preview-worker -u cratedigger-importer \
  --since '15 minutes ago' --no-pager
```

Completion means all of the following are true:

- request terminal state is imported/done, with the local-source audit row;
- one exact Beets album row carries the intended MusicBrainz release MBID;
- every expected FLAC exists beneath `/mnt/virtio/Music/Beets` and passes `flac -t`;
- CrateDigger quality/provenance reports only evidence actually returned by AccurateRip/CTDB;
- media refresh/notification completed or has a recorded retryable failure;
- the preservation bundle and final library are covered by the normal backup path.

### Optional destructive end-to-end proof

Only when the user explicitly asks to prove the newly contributed CTDB entry through the complete pipeline, preserve and verify the independent staging source first, then delete the exact Beets album through CrateDigger's guarded command. Never remove library files with `rm`:

```bash
pipeline-cli library-delete <BEETS_ALBUM_ID> --confirm DELETE \
  --pipeline-id <REQUEST_ID> --release-id <MUSICBRAINZ_RELEASE_MBID>

test ! -e /mnt/virtio/Music/Beets/<expected-album-path>
find /mnt/virtio/cd-import/<slug> -type f -iname '*.flac' | wc -l
pipeline-cli set <REQUEST_ID> wanted
pipeline-cli set-intent <REQUEST_ID> lossless
pipeline-cli import-local <REQUEST_ID> /mnt/virtio/cd-import/<slug> \
  --upstream-musicbrainz
```

Follow the replacement job to `completed`, then run `pipeline-cli quality <REQUEST_ID>`. A successful verifier receipt names the algorithm, track count, AccurateRip ID, MusicBrainz Disc ID, whole-disc CTDB CRC, actual confidence, CTDB entry ID, normalized response TOC, provider URL, and response-body SHA-256 for both `IN` and `HAVE`. The web badge is only a summary of that receipt.

Verified Winesong result (2026-09-17): guarded deletion removed 10 tracks and 12 owned artifacts while the 10 staging FLACs survived. Replacement local-import job `61796` completed in one attempt and reported exact CD-rip bit matches for both `IN` and `HAVE`, CTDB CRC32 `af764d8f`, confidence `1`, entry `13063896`, and response SHA-256 `b422f264a57248de3561d70185b4cec38ac9e0e529ade83047853d460d064a63`.

Only after those checks may the disposable `/mnt/virtio/cd-import/<slug>` staging copy be removed. Keep the original preservation bundle until at least one backup has completed and been verified.

## Rollback and failure handling

- **MusicBrainz metadata wrong before submit:** go back in the release editor; the HTML only seeds a draft.
- **MusicBrainz metadata wrong after submit:** edit the same release and document the correction; do not create a duplicate release.
- **Rip has suspicious positions or mismatched reads:** keep the evidence, clean/inspect the disc, and rerip. Do not submit it to CTDB or import it as preserved lossless audio.
- **CTDB says insufficient quality:** retain the log and stop the contribution step; never bypass the quality gate.
- **CUERipper console says zero errors but CTDB still returns 404:** the audio read succeeded but no submission occurred. Confirm the frontend actually called `CTDB.Submit`; do not describe the rip as uploaded.
- **CrateDigger rejects identity:** inspect the Wrong Matches evidence and the seeded release/FLAC tags. Fix metadata or tags, then use the guarded CrateDigger workflow; do not call Beets directly.
- **Import outcome is ambiguous:** preserve both source and action evidence, inspect `pipeline-cli show` plus importer logs, and avoid retrying until the exact job owner/outcome is known.
