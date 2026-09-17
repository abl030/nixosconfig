---
name: physical-cd-archive
description: Preserve a physical audio CD as a secure CUERipper image and derived FLAC tracks, add or attach its MusicBrainz disc/release metadata through a pre-filled browser edit, submit an eligible rip to CUETools Database (CTDB), and ingest it through CrateDigger's local-import lane into Beets. Use for "archive this CD", "rip this disc", MusicBrainz CD submission, CTDB contribution, or physical-CD CrateDigger imports.
---

# Physical CD ingestion

Read [the physical-CD runbook](../../../docs/wiki/services/physical-cd-preservation.md)
before acting. Use [the release-spec example](references/release-spec.example.json)
and [artist-spec example](references/artist-spec.example.json) for MusicBrainz
helpers; replace every illustrative value with physical evidence.

The durable result is:

1. the exact pressing identified and de-duplicated;
2. MusicBrainz Disc ID/release metadata, CAA art, and authorised lyrics corrected
   upstream;
3. a zero-error, offset-corrected CUERipper Secure/Paranoid image and lossless
   track FLACs derived from it;
4. honest AccurateRip/CTDB verification or contribution; and
5. the exact release imported through CrateDigger with lossless intent, verified
   tags/files, and recorded provenance.

Keep scans, browser handoffs, raw rip output, cue/log files, checksums, and receipts
as temporary working state under `~/Downloads` until the final Beets album,
CrateDigger provenance, and media refresh are verified. Then remove the working
copy and `/mnt/virtio/cd-import/<slug>` transport. Do not create a second permanent
`/mnt/virtio/Music/Preservation` archive.

If the exact release already exists, attach the Disc ID rather than creating a
duplicate. If public MusicBrainz is newer than the daily local mirror, use the
per-request helper and `import-local --upstream-musicbrainz`; never reconfigure the
service globally or wait for replication.

CrateDigger owns the Beets import. Never use ad-hoc `beet import`, and never use
`pipeline-cli replace` for an already identified physical pressing. A user-approved
library swap uses exact guarded `library-delete`, verifies the independent staging
copy survived, and imports the physical release's own request.

CUERipper owns the canonical PCM and CTDB submission. One zero-error
Secure/Paranoid extraction is the normal baseline; that mode already performs
its own rereads. Repeat the whole disc only for suspicious evidence, an engine
mismatch, or when the current submission tool genuinely requires another pass.
Whipper is an optional independent diagnostic, not the production source. CTDB
confidence is independent corroboration; another read on the same drive does not
increase it. Never invent confidence or duplicate an existing checksum. Use the
runbook's agent-driven, explicitly opt-in patched console; upstream CUETools
2.2.6's GUI also submits, while its stock console does not.

Every MusicBrainz artist field must resolve to the correct entity. Never use a
namesake or Various Artists merely to satisfy validation. The logged-in user must
review and submit MusicBrainz edits. Stop if package evidence materially conflicts
with the selected pressing or if rip/CTDB quality is insufficient.
