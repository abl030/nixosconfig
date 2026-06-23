# Mail-archive search (notmuch + embeddings + read-only MCP)

**Status:** implemented, NOT yet deployed (2026-06-23). First-cut from
`docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md`; runtime behaviour
needs verification on the first doc2 deploy (see "Deploy-time checklist").

**What it is:** local hybrid search over the mailarchive Maildir on doc2.
A notmuch (Xapian) keyword index and a nomic-embed / sqlite-vec semantic index
feed two surfaces: a terminal client for human keyword search, and a read-only
MCP tool (`search_mail` + `get_message`) for the agents driven on doc1.
Everything runs locally on doc2; the corpus never leaves the fleet.

Module: `modules/nixos/services/mailsearch.nix`. Enabled on doc2
(`hosts/doc2/configuration.nix`).

## Architecture

- **Maildir** (read-only source): `/mnt/data/Life/Andy/Email/{gmail,work}` — a
  `hard` NFS mount from tower. The legacy `Mailstore/` + `export-staging/` trees
  are excluded via notmuch `new.ignore` (they are being deleted with the
  MailStore VM).
- **Indexes** (on virtiofs, `/mnt/virtio/mailsearch`): the Xapian DB
  (`xapian/`), the sqlite-vec store (`vectors.db`), the embedding model cache
  (`models/`), and `index.heartbeat` / `embed.heartbeat`. **Never on the NFS
  mount** — Xapian's flintlock is unreliable over NFS and a hard mount hangs.
- **`mailsearch-index`** (oneshot, every 5 min): `notmuch new` → touch
  `index.heartbeat` → `mailsearch-indexer` (embed the delta). Runs `Nice`/idle.
- **`mailsearch-embed`** (resident): `llama-server --embeddings --pooling mean`
  serving `nomic-embed-text-v1.5` on `127.0.0.1:8181`, CPU only (`-ngl 0`).
- **`mailsearch-mcp`** (SSH forced-command): the read-only MCP server, run as
  `mailsearch-ro` when doc1 connects.
- **`mailsearch-health`** (resident): 200/503 on heartbeat freshness → Kuma.

## Query surfaces

- **Human (keyword), over SSH to doc2:** `mailsearch-tui` (alot) or
  `mailsearch search <query>` (a notmuch wrapper). The login user must be in the
  `mailsearch` group (`tuiUser = "abl030"` does this).
- **Agents (hybrid), from doc1 only:** the `mailsearch` subagent
  (`.claude/agents/mailsearch.md`) launches `scripts/mcp-mailsearch.sh`, which
  `ssh`es `mailsearch-ro@doc2` over the fleet key. doc2's `mailsearch-ro`
  authorized key is a **forced command** (`mailsearch-mcp`, `restrict`,
  tailnet/LAN `from=`) — so the key can run nothing but the read-only MCP.
  `search_mail` returns ranked metadata + snippet (no bodies); `get_message`
  gates the full body. No write tools exist. **hermes and every other host have
  no access.**

## Least-privilege / blast radius

- The index **is** the corpus in searchable form — same secrecy class as the
  mail. Owned `mailsearch-index:mailsearch`, mode `0750`, group-readable by the
  read-only query user. Not world-readable.
- Indexes are **not** in the offsite backup (`kopia-mum`) — they are rebuildable
  from the Maildir, so a restore re-runs the bootstrap embed rather than shipping
  a second searchable copy of the mail offsite.
- The indexer/MCP **never write the Maildir** (`maildir.synchronize_flags=false`
  + `ReadOnlyPaths`).
- **Query strings are never logged** — the indexer and MCP log only counts /
  Message-IDs / timings to stderr. doc2 ships the journal to Loki (fleet-
  readable); a logged query would leak intent.
- `llama-server`, the health server, and the index are loopback / local only;
  the agent path is SSH stdio (no network listener).

## Bootstrap (first deploy)

1. Deploy doc2 (`fleet-deploy doc2` from doc1, or `sudo fleet-update` once
   signed + pushed).
2. The first `mailsearch-index` run does the full `notmuch new` (~minutes) then
   the **one-time embed** of ~98k messages on CPU (a few hours; run off-peak —
   the unit is already `Nice 15` / idle IO). Watch progress in the journal:
   `mailsearch-indexer: embedded=… new=…`.
3. Verify: `mailsearch search barrel repair` returns hits; from doc1 the
   `mailsearch` agent can `search_mail`.

## Recovery

Indexes are derived artifacts. To rebuild from scratch:
`systemctl stop mailsearch-index.timer && rm -rf /mnt/virtio/mailsearch/{xapian,vectors.db} && systemctl start mailsearch-index.service`
(then wait out the re-embed). Nothing in the Maildir is touched.

## Deploy-time checklist (NOT verifiable by `nix flake check`)

- [ ] **Maildir read access.** The live `gmail/`/`work/` Maildirs are mode
      `0700`. Confirm `mailsearch-index` (in `users`) can actually read them; if
      not, `chmod -R g+rX` the tree, add a `mailsearch` ACL, or run the index
      service as `mailarchive`.
- [ ] **mail-parser-reply hash.** `nix/pkgs/mailsearch-indexer.nix` ships
      `lib.fakeHash`. Run `nix build` of the doc2 closure, paste the real hash
      from the error.
- [ ] **Embedding model spec.** Confirm `embedModelSpec`
      (`nomic-ai/nomic-embed-text-v1.5-GGUF:F16`) downloads via `llama-server -hf`
      and that `--pooling mean` + the `search_document:`/`search_query:` prefixes
      give sane similarities (smoke-test a known pair).
- [ ] **Fleet key match.** Confirm `fleetPubKey` in the module equals hosts.nix
      `fleetIdentity`, and that `ssh mailsearch-ro@doc2` from doc1 lands on the
      forced command (any other command is refused).
- [ ] **notmuch JSON shapes / sqlite-vec apsw API.** Confirm the indexer and MCP
      parse `notmuch show --format=json` and run the sqlite-vec KNN correctly
      (the first `search_mail` is the test).
- [ ] **Loki check.** Confirm no query strings or message bodies appear in
      `{host="doc2"}` logs for the new units.

## References

- Plan: `docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md`
- Brainstorm: `docs/brainstorms/2026-06-23-mailarchive-search-requirements.md`
- Templates mirrored: `modules/nixos/services/whisper-server.nix` (llama-server),
  `modules/nixos/services/mailarchive.nix` (oneshot/timer/heartbeat/health),
  `modules/nixos/services/hermes-operator-deploy.nix` (forced-command key).
