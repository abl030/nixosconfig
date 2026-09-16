# Storyteller readaloud trial

Date: 2026-09-16. Status: live; first full-book alignment running.
Related: [book platform evaluation](book-platform-exploration.md).

Storyteller pairs a DRM-free EPUB with its audiobook and creates a readaloud
EPUB with synchronized narration. Upstream documentation:
<https://storyteller-platform.dev/docs/installation/self-hosting/> and
<https://storyteller-platform.dev/docs/managing/adding/>.

## Deployment

- Host: doc2; URL: <https://storyteller.ablz.au>.
- Official image: `registry.gitlab.com/storyteller-platform/storyteller:latest`,
  under the fleet auto-update policy. Initial tested version: 2.14.21.
- Private state: `/mnt/virtio/storyteller`, UID/GID 2026, SQLite in that directory.
- Loopback-only port 8001, service-isolated Podman network, nginx TLS/DNS.
- Local CPU alignment: whisper.cpp `base.en`, four threads, one transcription
  and one transcode at a time, half-hour maximum tracks. Container limits:
  four CPUs, 8 GiB RAM, 10 GiB combined RAM/swap, 512 processes.
  Set `whisperThreads = 1`: upstream 2.14.21 expands this setting to one
  processor and four threads (a value of four creates four processors and
  sixteen threads, oversubscribing this container).
- Fleet monitors check HTTPS health (including Readium and DB), storage writes
  as the application UID, SQLite integrity and write locking. SQLite corruption,
  disk-full, read-only errors and asynchronous alignment failures are alerted.

The image briefly starts as root to remap its internal user and caches, then
execs the application as UID 2026. Capabilities are dropped except the five
needed for that initialization; no-new-privileges remains enabled. No control
socket, host devices, shared media mounts, downloader credentials, or other
service secrets are available to this container. Runtime processes were checked
to exclude host UID 1000. The instance key is supplied through a doc2-only SOPS
environment file; the bootstrap recovery record stays root-only on doc2.

Administrator: `abl030`. Retrieve the initial password from doc1 with:

```sh
ssh doc2 "sudo jq -r .password /run/secrets/storyteller/bootstrap"
```

Changing the password in Storyteller does not update this recovery record.
The bootstrap account was created while the instance was loopback-only.

## First synchronization test

The selected title is **Children of Ruin: Children of Time Book 2** by Adrian
Tchaikovsky. ReadMeABook request `25aa4ee9-a4a4-4a0b-8c2b-c4cdf10339aa`,
ASIN `B0DPG5C952`, supplies the audiobook and automatic companion EPUB request
`ac0ec54d-6ee3-4311-b4ab-7a4de875b38a`. Both requests reached `downloaded`, 100%,
with no error.

Verified inputs in the ReadMeABook folder
`Adrian Tchaikovsky/Children of Ruin Children of Time Book 2 B0DPG5C952`:

- MP3: 666,995,996 bytes, 55,537.711 seconds (15h 25m 38s).
- EPUB: 2,580,132 bytes, valid EPUB 3 ZIP/CRC, English, correct title and author.
- EPUB SHA-256: `c3525394e946827ae109498a57546017e9085582d85e57d579e2788b8d374a54`.
- MP3 SHA-256: `ca101bf2e15f09d71dd928f3e0c525ccb4063e776a71def5e47072089e54434e`.

Use independent copies in Storyteller's private storage for this trial.
Upstream reference imports can write metadata back into input files, so do not
mount the ABS/Komga source library writable. Import the EPUB and audio as a pair,
then explicitly start alignment. General automatic ingestion is not enabled.

The copies now live under `/mnt/virtio/storyteller/assets/Children of Ruin`.
Storyteller book UUID: `110ea8c3-7f10-48c1-80cc-10ca5cd28126`. Alignment began
at 15:51 AWST, completed audio splitting, downloaded `base.en`, and entered
transcription. This verifies job execution; it is not yet proof of completed
alignment or narration accuracy. Source hashes were rechecked after import and
remain unchanged. The source manifest is in Storyteller's private data directory.
The first half-hour transcription produced a 917,307-byte JSON result. Processing
was paused through the API after that checkpoint to deploy the corrected worker
thread count, then resumed with cached work preserved.

### Smoke-test defects and narrow workarounds

1. **ReadMeABook 1.2.3 / qBittorrent path mismatch.** ReadMeABook configures its
   category but sends neither `savepath` nor `autoTMM` when adding a torrent.
   qBittorrent's existing manual-management settings ignore category paths.
   Both downloads initially completed under `/downloads`, outside the app's
   category-only mount. Enabling automatic management for just the two torrents
   moved them into `/downloads/readmeabook`; retrying their imports succeeded.
   The originals remain complete and seeding. Global qBittorrent settings were
   preserved. Future torrent requests can still encounter this upstream defect;
   do not expose the whole download root to work around it.
2. **Companion search subtitle.** The automatic EPUB request used the full
   Audible title and did not inherit the parent request's custom search terms.
   Set its supported per-request search override to `Children of Ruin`; the app
   then automatically selected and acquired the matching EPUB. No broad search
   or ranking configuration was changed.
3. **Storyteller 2.14.21 paired server import.** Importing an EPUB plus audio in
   a nested `audio/` directory through `POST /api/v2/books` created the ebook,
   then hit `UNIQUE constraint failed: book.uuid` for the audio. The endpoint
   returned a partial book despite the error. Importing the audio separately,
   then using `POST /api/v2/books/merge`, produced one book with both formats.
   Always check the returned ebook AND audiobook objects before starting work.

Torrent hashes: audiobook `42f254543d9080d80875f73d273cbe77f01178cd`; EPUB
`0d90e4c71193b5690a33ad623b98769f5002072c`. To undo the torrent-specific change,
disable auto management for these hashes with `/api/v2/torrents/setAutoManagement`
(`enable=false`); use `/api/v2/torrents/setLocation` only if deliberately restoring
their old save location. Imported copies are unaffected. The search override can
be cleared through the ReadMeABook request's admin `search-terms` endpoint.

ReadMeABook logs can contain credential-bearing indexer URLs. Redact query
credentials before displaying or sharing those logs.

## Verification and rollback

Preflight verified health, login, anonymous API rejection, application-UID file
writes, SQLite integrity and write transaction acquisition. The source library
and existing ABS/Komga integrations are unchanged by Storyteller itself.

The initial signed deployment was `1784ea3c21680d0e6d12c634bb32a0bc180f7075`.
doc2 reported that exact running and verified revision after `fleet-deploy`.
Public DNS resolves to doc2, Let's Encrypt issued the certificate, authenticated
HTTPS API calls succeed, unauthenticated book access returns 401, and the deployed
deep probe passes. Flake evaluation, doc2 toplevel build, Alejandra, deadnix,
statix, and the network, host-bind, unit-hardening, secret-argv, SOPS-recipient and
error-pattern audit checks passed.

Browser verification also passed: login as `abl030`, one paired book visible,
the direct `/books/110ea8c3-7f10-48c1-80cc-10ca5cd28126/read` route renders the
ebook, and both download endpoints return HTTP 200 plus HTTP 206 for byte-range
requests. The reader reports no synchronized track until alignment finishes;
an initial reading-position 404 represents an unset progress record. No synced
reading/listening result is claimed yet.

Rollback: set `homelab.services.storyteller.enable = false` on doc2, land the
signed change and run `fleet-deploy doc2` from doc1. This removes the service and
its managed proxy/DNS/monitor declarations while retaining private data for
recovery. Do not delete `/mnt/virtio/storyteller` as part of rollback.

Revisit GPU acceleration only after observing this bounded CPU test. Recheck the
upstream import semantics before enabling ongoing library ingestion.
