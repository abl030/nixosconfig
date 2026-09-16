# Storyteller readaloud trial

Date: 2026-09-16. Status: deployment and first-book verification in progress.
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
- Fleet monitors check HTTPS health (including Readium and DB), storage writes
  as the application UID, SQLite integrity and write locking. SQLite corruption,
  disk-full and read-only errors are also alerted.

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
ASIN `B0DPG5C952`, supplies the audiobook and automatic companion EPUB.

Use independent copies in Storyteller's private storage for this trial.
Upstream reference imports can write metadata back into input files, so do not
mount the ABS/Komga source library writable. Import the EPUB and audio as a pair,
then explicitly start alignment. General automatic ingestion is not enabled.

## Verification and rollback

Preflight verified health, login, anonymous API rejection, application-UID file
writes, SQLite integrity and write transaction acquisition. The source library
and existing ABS/Komga integrations are unchanged by Storyteller itself.

Rollback: set `homelab.services.storyteller.enable = false` on doc2, land the
signed change and run `fleet-deploy doc2` from doc1. This removes the service and
its managed proxy/DNS/monitor declarations while retaining private data for
recovery. Do not delete `/mnt/virtio/storyteller` as part of rollback.

Revisit GPU acceleration only after observing this bounded CPU test. Recheck the
upstream import semantics before enabling ongoing library ingestion.
