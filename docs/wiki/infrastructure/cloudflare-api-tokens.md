# Cloudflare API tokens — inventory, scope audit & decisions

- **Researched:** 2026-06-22
- **Status:** current / resolved (GitHub #240 closed)
- **Issue:** GitHub #240 (scope the CF API token), umbrella #232 (least-privilege)
- **Zone:** `ablz.au` is the **only** zone in the Cloudflare account (single-zone
  account — this matters, see below).

## TL;DR

The repo's Cloudflare token was **already minimally scoped** (single zone,
`Zone:DNS:Edit` + `Zone:Zone:Read`, nothing else). The #240 premise ("probably
broader than required") turned out false on the repo token. The real findings
were elsewhere: a **dead duplicate** of the token sitting in immich's env, and a
**separate over-scoped (All-zones) token** living *outside* this repo on the
`cad` box. We removed the dup, rotated the repo token, and narrowed/deleted the
external ones. We **did not** split into per-purpose tokens — under Cloudflare's
granularity that buys nothing here (see Decision below).

## Token inventory (as of 2026-06-22)

| CF token | Scope | Lives in | Verdict |
|---|---|---|---|
| **"Edit zone DNS"** id `d90a01e8…` | 1 zone (`ablz.au`), `DNS:Edit`+`Zone:Read` | repo: `secrets/acme-cloudflare.env` (`CLOUDFLARE_DNS_API_TOKEN`) | **keep**; rotated 2026-06-22 |
| **"Edit zone DNS"** (All zones) | **All zones**, `DNS:Edit` | `cad`:`/etc/letsencrypt/cloudflare.ini` (certbot) | **narrowed to 1 zone** by owner |
| **"Caddy2.0"** | 1 zone | nothing live (last used Jul 2025) | **deleted** by owner |

### Scope audit method (read-only, repeatable)

The token can't introspect its own *policies* via the API, but you can fingerprint
its scope by probing endpoints with it (all read-only):

```sh
TOKEN=$(env -C secrets sops -d acme-cloudflare.env | sed -n 's/^CLOUDFLARE_DNS_API_TOKEN=//p' | tr -d '\r\n')
curl -fsS -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify   # id + active
curl -fsS -H "Authorization: Bearer $TOKEN" https://api.cloudflare.com/client/v4/zones?per_page=50     # which zones visible
# probe extra perms — all should 403 for a DNS-only token:
ZID=$(curl -fsS -H "Authorization: Bearer $TOKEN" 'https://api.cloudflare.com/client/v4/zones?name=ablz.au' | jq -r '.result[0].id')
for p in settings/ssl firewall/rules pagerules workers/routes ssl/certificate_packs; do
  echo "$p -> $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "https://api.cloudflare.com/client/v4/zones/$ZID/$p")"
done
```

Result for `d90a01e8…`: `dns_records` 200, `zone` details 200, **everything else
403**, and `zones` returns only `ablz.au`. → exactly `Zone:DNS:Edit` +
`Zone:Zone:Read`, single zone. Minimal.

> **Caveat:** a single-zone account can't distinguish an *All-zones* token from a
> *1-zone* token via `GET /zones` (both return just `ablz.au`). Use the **token id**
> from `/user/tokens/verify` to match it against a row in the CF dashboard, and
> read the **Resources** column there for the true zone scope. The dashboard's
> "Last used" column is the other forensic lever (it's how we traced the All-zones
> token to `cad`'s certbot renewals).

## Who consumes the repo token (`d90a01e8`)

Declared by `nginx.nix` as `sops.secrets."acme/cloudflare"` (owner `acme`), plus a
standalone declaration in `hosts/hermes/configuration.nix` (hermes runs no nginx).
sops recipients: **doc1, doc2, igpu, wsl, hermes** + editor + break-glass.

| Host | Consumers | Reads token how |
|---|---|---|
| doc1 | nginx ACME (DNS-01), `homelab-dns-sync` (localProxy A records) | `acme` env file; root `cat`s file per run |
| doc2 | nginx ACME, ts-share dns-sync, caddy sidecars (overseerr, abs) | acme; root per run; **caddy via `environmentFiles`** |
| igpu | nginx ACME (jelly LAN), ts-share dns-sync, caddy sidecar (jellyfin) | same |
| wsl | nginx ACME (cullen-dashboard) | acme |
| hermes | ts-share dns-sync, caddy sidecar (hermes-dashboard) | root per run; caddy via `environmentFiles` |

**All four use cases need the identical permission** — `Zone:DNS:Edit` on
`ablz.au`. ACME (TXT `_acme-challenge`), localProxy A-record sync, and ts-share
A-record sync all require it. There is no narrower CF permission (no per-record,
no per-type/TXT-only, no edit-without-delete).

## Decision: we did **not** split into per-purpose tokens

#240 proposed `cloudflare/dns-sync` + `cloudflare/acme` + `cloudflare/share`.
We rejected that, because:

1. **CF's granularity floor.** Every one of our consumers needs full
   `Zone:DNS:Edit` on the one zone. So *any* token we mint — per-purpose or
   per-host — can repoint/delete **all** of `*.ablz.au`. Splitting does **not**
   shrink the blast radius of a stolen credential.
2. **Single-zone account.** "All zones" ≈ "1 zone" in effective reach today, so
   even the zone axis offers no real narrowing.
3. **Per-purpose is *worse* than per-host under #234.** Purposes span hosts (an
   `acme` token would live on doc1+doc2+igpu+wsl), re-creating the cross-host
   sharing the per-host secrets model exists to avoid.

What splitting *would* buy is only **revoke-without-collateral** + **audit
attribution** — marginal for a single-operator homelab, at the cost of N tokens
of perpetual manual rotation. Not worth it. If that calculus ever changes (e.g.
a second zone is added, or the caddy sidecars — the only *listening* consumers —
warrant an independently-revocable credential), revisit with a 2-token
**infra vs sidecar** split, not the 3-way per-purpose one.

The one thing that *would* genuinely cut blast radius is **CNAME-delegating
`_acme-challenge` to a throwaway zone** so the ACME path can't touch `ablz.au`.
Rejected as overkill: a second domain + a CNAME per cert + a new external
dependency, and the A-record-sync consumers still need full `ablz.au` edit anyway.

## What we actually changed (2026-06-22)

1. **Removed the dead duplicate.** `secrets/hosts/doc2/immich.env` carried
   `CLOUDFLARE_API_TOKEN=<same value>` — a fossil from immich's old
   docker-compose `.env` (not a real immich variable). immich never reads it, but
   `immich.nix` loads the whole env file into immich-server's environment, so a
   large internet-adjacent app was sitting on a live DNS-edit token. Deleted the
   line. (commit `3a535f21`)
2. **Rotated** `d90a01e8` via CF dashboard **"Roll"** (keeps the same id, name and
   scope; mints a new secret string; invalidates the old one immediately).
3. **Narrowed/deleted the external tokens** (owner, in CF dashboard): the
   All-zones certbot token on `cad` → scoped down to 1 zone in place; the dead
   "Caddy2.0" token → deleted.

## Rotation runbook (for next time)

1. CF dashboard → API Tokens → the token → **Roll** → copy new value.
2. Update the secret **in place** (preserves recipients — do *not* re-encrypt from
   a path outside `secrets/`, or the creation-rule match changes):
   `cd secrets && SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops acme-cloudflare.env`
3. Verify: decrypt → `curl …/user/tokens/verify` (status active).
4. `nix build .#checks.x86_64-linux.sopsRecipientScopeCheck` (recipients intact).
5. Commit (signed) + push to Forgejo; deploy all five consumers
   (`sudo fleet-update` on doc1; `fleet-deploy doc2/igpu/hermes/wsl`).
6. **Restart the caddy sidecars** (`sudo systemctl restart podman-caddy-*` on
   doc2/igpu/hermes) — they cache the token in the **container env at start**, so
   they're the only consumer that needs a kick. nginx ACME (lego reads the env
   file fresh each renewal) and both dns-sync scripts (they `cat` the file each
   run) pick up the new token automatically; no restart needed. A host **reboot**
   also refreshes the sidecar for free (container starts fresh from `/run/secrets`).
7. Verify host convergence with `nixos-version --configuration-revision` (no sudo)
   and TLS with `curl -o /dev/null -w '%{ssl_verify_result}' https://<share-fqdn>`
   (`0` = valid cert).

## The `cad` box (previously undocumented CF consumer)

`cad` (sshAlias `cad`, Ubuntu 24.04, **not** managed by this nixos repo — Home
Manager only) runs **apt Caddy** as a pure reverse proxy. It does **no** DNS-01
itself; it serves a static **`*.ablz.au` wildcard cert** from
`/etc/letsencrypt/live/ablz.au/`, obtained by **`certbot` + `certbot-dns-cloudflare`**
(`certbot.timer`, creds in `/etc/letsencrypt/cloudflare.ini`). The Caddyfile is a
symlink to `~/abl030/DotFiles/Caddy/Caddyfile`. This was the home of the
All-zones token; certbot only calls Cloudflare on an actual renewal, which is why
its "Last used" lagged (last wildcard renewal). Now narrowed to a 1-zone token.

## Related caveat — nginx reload is currently broken on doc1

Surfaced again during this work: doc1's `nginx-config-reload.service` fails on
every switch with `226/NAMESPACE` — `Failed to set up mount namespacing:
/mnt/data/Media/Podcasts: Stale file handle`. nginx keeps **serving** (the
running process predates the stale mount) but cannot **reload**, so deploys
report failure and cert reloads won't apply until the mount is remounted + nginx
restarted. Unrelated to CF tokens. Tracked in **Forgejo #3**.
