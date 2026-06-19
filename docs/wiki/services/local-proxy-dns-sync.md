# local_proxy DNS sync — record ownership & cross-host migrations

**Researched:** 2026-06-19 · **Status:** working (ownership model live) · **Issue:** [#202](https://github.com/abl030/nixosconfig/issues/202)
**Module:** `modules/nixos/services/local_proxy.nix`

## What this is

`homelab.localProxy` gives each service an `<svc>.ablz.au` FQDN: nginx vhost +
ACME cert + a Cloudflare A record pointing at the host's LAN (or tailnet) IP.
The A records are managed by the `homelab-dns-sync` oneshot, which runs on every
rebuild (activation script) and is the reason a service move is a one-deploy
change with zero consumer updates — see "DNS-First Networking" in
`docs/wiki/nixos-service-modules.md`.

Service modules contribute their FQDN via `homelab.localProxy.hosts`, merged
across every enabled service. So **doc1 and doc2 each run their own
`homelab-dns-sync`** over the union of *their* enabled services' records.

## The cache

Each host keeps `/var/lib/homelab/dns/records.json`:

```json
{ "tau.ablz.au": { "ip": "192.168.1.35", "ttl": 60, "recordId": "8e4c70…" } }
```

`records.json` is a **local, per-host** convenience cache to skip redundant
Cloudflare API calls (`ip+ttl+recordId` match → "up-to-date (cache)", no call).
`zone-id` caches the zone lookup. These are *not* authoritative — Cloudflare is.

## The race it used to cause (issue #202)

When a service migrates between hosts, both hosts briefly believe they manage
the same name. The old code's cleanup phase deleted the record by its **cached
ID**, with no check of who owns it now:

1. **doc2 deploys** (service now lives here) → finds the existing `tau` A record,
   `PUT`s it to `.35`, caches the record ID.
2. **doc1 deploys** (service removed here) → `tau` is in doc1's *stale local
   cache* but not its desired list → `DELETE`s that **same record ID** — the one
   doc2 just claimed.
3. **Result:** zero A records for `tau`. The `*.ablz.au` wildcard wins → traffic
   lands on the wrong host → **502, indefinitely** (doc2's cache still says
   "up-to-date", so it never re-creates it).

The dig-based nightly `homelab-dns-validate` (02:00) would *eventually* self-heal
this (wildcard IP ≠ expected IP → invalidate cache → re-sync), but only within
24h, and only as a backstop.

## The fix: record ownership tags

Each managed A record carries a Cloudflare **comment** stamping its owner:

```
comment = "managed-by:<hostname>"   # e.g. managed-by:doc2
```

- **On write** (`POST`/`PUT`): the host stamps its own tag, *claiming* the record.
  A migration's `PUT` atomically swaps both the content (IP) and the owner.
- **On cleanup**: instead of trusting the cached ID, the host does a **live `GET`
  by name** and only deletes the record when it is **unclaimed (empty comment)
  or still owned by us**. If another host's tag is on it, the record is left
  intact and only the stale local cache entry is dropped.

This makes cross-host deletion impossible: doc1 can no longer delete a record
doc2 has claimed.

### Why ownership tags, not "verify cache before trusting" (Option A)

The issue floated verifying each cached record against Cloudflare before
skipping. That only makes the *losing* host self-heal on a *later* run — it does
not stop the delete, so an outage window remains. Ownership tags kill the delete
at the root, so the recommended deploy order is **gap-free**, not just
eventually-consistent.

Cost: one extra `GET` per *removed* host per run (cleanup is rare). No new
Cloudflare token scope — the existing ACME `Zone.DNS edit` token already
writes/reads comments.

## Deploy order when moving a service: NEW host first

With ownership tags, **deploy the destination (new) host first, then the source
(old) host**:

1. **New host deploys** → its `PUT` takes over the existing record *in place*
   (atomic IP swap, **zero downtime**) and stamps `managed-by:<newhost>`.
2. **Old host deploys** → cleanup sees `managed-by:<newhost>` ≠ its own tag →
   leaves Cloudflare untouched, just forgets the name locally.

Old-host-first also works, but deletes-then-recreates → a brief wildcard window
between the two deploys. Prefer new-host-first.

> **Transient flip-flop caveat (out of scope for #202):** between the two
> deploys, the *old* host's still-running closure also lists the name. If its
> nightly `homelab-dns-validate` fires in that window it will re-claim the
> record back to itself. Deploy both hosts in the **same maintenance window** to
> avoid this — don't leave a half-migrated fleet overnight. A permanent
> duplicate (two hosts listing the same FQDN in committed config) is a
> misconfiguration that flip-flops every deploy; that's a separate concern.

## Legacy (comment-less) records

Records that existed before this change have no comment. That's fine:

- The **claiming** host stamps the comment during a migration `PUT` — i.e. the
  protection is created exactly when it's needed.
- A null-comment record still in *our own* cache stays deletable, so
  decommissioning a service (remove from the only host) still cleans up.
- We only **refuse** to delete when another host's tag is explicitly present.

There is no forced re-stamp pass; stable records get tagged the next time their
IP/TTL changes. No `records.json` schema change was needed.

## Backstops still in place

- **Nightly `homelab-dns-validate`** (02:00): `dig`s each cached host; on IP
  mismatch it invalidates the cache entry and triggers a re-sync. Catches
  out-of-band deletes/changes (a deleted record resolves to the wildcard IP,
  which differs from the cached IP → invalidate → re-create).

## Manual recovery (if a record is still missing)

```bash
# Authoritative check — does Cloudflare have the record?
TOKEN=$(ssh <host> "sudo grep -oP 'CLOUDFLARE_DNS_API_TOKEN=\K.*' /run/secrets/acme/cloudflare | tr -d '\r\n'")
ZONE=$(ssh <host> "sudo cat /var/lib/homelab/dns/zone-id")
curl -fsS -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/$ZONE/dns_records?type=A&name=<fqdn>" \
  | jq '.result[] | {id, name, content, comment}'

# If empty: drop the stale cache entry on the owning host and re-sync.
ssh <host> "sudo rm -f /var/lib/homelab/dns/records.json && sudo systemctl start homelab-dns-sync.service"
```

The `comment` field in the first query tells you which host owns each record.

## When to revisit

- If services start being defined fleet-wide (centralised DNS state derived from
  `hosts.nix` at eval time — issue #202 Option C), the per-host cache and this
  ownership dance can be retired entirely.
- If a genuine need for two hosts to serve the same FQDN appears (active/standby),
  add explicit conflict detection rather than relying on last-PUT-wins.
