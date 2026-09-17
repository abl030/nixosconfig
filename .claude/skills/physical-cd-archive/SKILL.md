---
name: physical-cd-archive
description: Preserve a physical audio CD as a secure FLAC rip, add or attach its MusicBrainz disc/release metadata through a pre-filled browser edit, submit an eligible rip to CUETools Database (CTDB), and ingest it through CrateDigger's local-import lane into Beets. Use for "archive this CD", "rip this disc", MusicBrainz CD submission, CTDB contribution, or physical-CD CrateDigger imports.
---

# Physical CD preservation

Read [the physical-CD runbook](../../../docs/wiki/services/physical-cd-preservation.md) before acting. It contains the fleet paths, browser handoff, CTDB boundary, and CrateDigger commands. Use [the release-spec example](references/release-spec.example.json) and [artist-spec example](references/artist-spec.example.json) as the JSON shapes for the MusicBrainz helpers; replace every illustrative value with physical evidence.

The completed outcome is one evidence chain, not merely some FLAC files:

1. capture photographs/liner notes and the physical TOC;
2. check the exact MusicBrainz Disc ID and search the release separately;
3. secure-rip with the drive's verified AccurateRip read offset, retaining the cue sheet and extraction log;
4. create or attach the MusicBrainz release using `scripts/musicbrainz-release-seed.py`, with `mediums.0.toc` so the disc ID is preserved;
5. submit to CTDB only through software that records a qualifying secure-rip result; upstream CUETools 2.2.6's GUI calls `CTDB.Submit`, but its console frontend does not, so a zero-error console log alone is not an upload; never invent a confidence or call a single local reread independent corroboration;
6. tag the preserved FLACs with the resulting MusicBrainz release identity and copy the album into a dedicated directory under `/mnt/virtio` on doc2;
7. create/resume the exact CrateDigger MusicBrainz request, set its intent to `lossless`, enqueue `pipeline-cli import-local`, and verify the terminal request, Beets rows/files, provenance display, and logs. If public MusicBrainz has the release but the mirror is stale, use the per-job `--upstream-musicbrainz` flag; do not reconfigure the whole service.

Keep the original rip, `.cue`, secure-rip log, photographs, TOC/Disc IDs, checksums, and database submission evidence until the Beets/CrateDigger copy and backup are verified. Never point `import-local` at the Beets library, CrateDigger processing tree, download tree, or Beets DB directory; those are explicitly refused ownership boundaries.

In the MusicBrainz editor, do not proceed until every album/track artist field is green. Resolve seeded names with the magnifying glass; use **Add a new artist** only after ruling out a real existing match, and never use a namesake or Various Artists as a validation workaround.

MusicBrainz and CTDB are external shared databases. The user's request to archive and contribute the disc authorizes preparation and the described contribution, but the MusicBrainz web editor still requires the logged-in user to review and enter the edit. Stop if packaging evidence and seeded metadata materially disagree or if CTDB reports insufficient rip quality.
