# Public family-history site (`family.barrett-lennard.com`)

- **Built:** 2026-10-30 · **Tracking:** Forgejo [#250](https://git.ablz.au/abl030/nixosconfig/issues/250),
  phase 6 of `abl030/family-history#137` (plan: `docs/plans/public-export.md` there)
- **Status:** **live** since 2026-10-30 13:31 AWST, verified from outside. The reader
  reports email is not built yet.
- **Config:** `hosts/doc2/family-public-microvm.nix` (guest), `modules/nixos/services/family-archive.nix`
  (`publicSite`, the doc1 publish command)
- **Related:** [family-archive](family-archive.md) (the private site and LAN preview),
  [slskd-cage](slskd-cage.md) and [plex-media-dmz](plex-media-dmz.md) (the same firewall-is-the-boundary model)

## Design

```text
visitor/agent → Cloudflare edge (TLS, cache, compression, rate limit)
             → outbound tunnel, guest → 198.41.192.0/24|198.41.200.0/24 :7844
             → familypub microVM (doc2), cloudflared → nginx 127.0.0.1:8080
                 root /srv/site/live/current → releases/<UTC stamp>

doc1: family-public-publish
      cp -al preview → snapshot → fh export --check → rsync over SSH
      → pfSense pinhole doc1 → 192.168.22.2:22 → forced command (staging, activate)
```

### Why a Cloudflare Tunnel

Decided with the user on 2026-10-30. barrett-lennard.com is already on Cloudflare in the
same account as ablz.au. The tunnel means no WAN port forward and no published home IP,
so the guest's only egress is Cloudflare's tunnel edge. The edge cache carries repeat
downloads, so a crawler pulling the whole site does not keep using our uplink. TLS ends
at Cloudflare, so the guest holds no certificate and no DNS token, only the
tunnel credential. The costs are that Cloudflare sees all traffic (the site is public
anyway) and that the site depends on its free plan. The fallback, if Cloudflare ever forces
challenges on agents, is a small VPS that doc1 pushes the same tree to.

**Agents must get through.** The site exists for agents (`llms.txt`, dumps, JSON
twins). Zone settings to keep: Bot Fight Mode **off**, "Block AI bots" / AI Crawl
Control **off**, managed robots.txt **off**, security level lowest, plus a WAF skip
rule for `/api/`, `/robots.txt`, `/llms.txt` and `/sitemap.xml`. The rate limit answers 429,
never a challenge page. Verify from outside with plain `curl` and a bot user agent.

### Cloudflare objects (account `50e4b918…`, zone `3312c076…`, Free plan)

Everything was created by API on 2026-10-30; change it the same way.

- **Tunnel:** `familypub`, id `55ab03aa-d40a-479c-b897-5802edf2404a`, locally managed: the
  ingress lives in the Nix config, not the dashboard. Credentials JSON:
  `secrets/hosts/doc2/family-public-tunnel.json` (doc2-only). The guest reads it as the qemu
  credential `family-tunnel`.
- **DNS:** a proxied CNAME `family` → `<id>.cfargotunnel.com`. The apex (Cloudways) and the
  Namecheap MX/SPF records are untouched.
- **Zone settings:**
  - security level `essentially_off`, Browser Integrity Check off;
  - Bot Fight Mode, AI-bot blocking, content/crawler protection and managed robots.txt all
    off (they were already);
  - HTTPS redirect on, TLS ≥ 1.2, Brotli on.

  The security settings are zone-wide, but nothing else on the zone is proxied.
- **Cache rule** (`http_request_cache_settings`): host `family.` is cacheable, with edge and
  browser TTL taken from the origin.
- **Rate limit** (`http_ratelimit`, the Free plan's one rule): 300 requests per 10 s per IP and
  colo, block (429), 10 s timeout.
- **Tokens:**
  - `familypub-publish-purge` (id `0dd95b09…`): Cache Purge on this zone only, no expiry,
    `secrets/hosts/proxmox-vm/family-public-cf-purge` (doc1-only).
  - `familypub-setup` (id `e83c2cb5…`): tunnel, DNS, settings, cache, WAF, bots and email
    routing. It expires 2026-11-02 and was never stored in the repo. Mint a fresh scoped
    token for later changes.
  - The full-access token used to mint these was handed to the agent on 2026-10-30 and is
    to be destroyed by the user.
  - All are account-owned tokens, so verify them at `/accounts/<id>/tokens/verify`, not
    `/user/tokens/verify`.

### Containment

| Dimension | How |
|---|---|
| Network | VLAN 22 `FAMILY_DMZ` (UniFi vlan-only; pfSense `opt8`, `192.168.22.1/24`, no DHCP). The guest is `192.168.22.2`. doc2 bridges Proxmox VMID 114 `net3` (`ens21`, MAC `bc:24:11:8e:04:3c`, hot-plugged) IP-less to the guest tap. |
| pfSense, FAMILY_DMZ | Rules in order: block DoT and DoH; DNS to `.22.1:53`; UDP 123 to `CF_NTP` (time.cloudflare.com; pfSense runs no ntpd); **block RFC1918**; pass 7844 tcp/udp to `CF_TUNNEL_EDGE` through the `FAMILY_UP` limiter (20 Mbit/s upload); terminal block. Outbound NAT `.22.0/24 → WAN`. No WAN forwards. |
| pfSense, inbound | Floating rules: pass doc1 `192.168.1.29 → .22.2:22`, then block anything to `.22.0/24`, plus blocks on TORRENT_DMZ, Docker VLAN and IoT, whose catch-alls would otherwise match. |
| Host windows | **None.** `storeOnDisk` (its own erofs store, not doc2's `/nix/store`), a 20 GiB volume `/var/lib/microvms/familypub/site.img` (`nodev,nosuid,noexec`), and the tunnel credential as a qemu systemd credential (`credentialFiles`, `/run/credentials/@system/family-tunnel`). No virtiofs. That is also why it is qemu: cloud-hypervisor can't pass credentials. |
| Management | No shell login, Tailscale, fleet key or sops key, and no serial getty. sshd listens on `.22.2` for user `publish` only, whose one key is forced to `family-public-publish-command`. The journal is forwarded to the serial console, so it lands in doc2's `microvm@familypub` journal and Loki. |
| Resources | The guest has 2 vCPUs and 1.5 GiB. On doc2 the whole qemu unit is capped: `CPUQuota=100%` (one of 12 cores), `CPUWeight`/`IOWeight` 20 (yields to doc2's services), `MemoryMax=2G`, `TasksMax=256`. The volume is a 20 GiB sparse image. A compromised guest running a miner gets at most one core, and its egress (Cloudflare edge :7844 only, 20 Mbit/s) can't reach a pool. In steady state it uses about 340 MB and 8 tasks. |

The publish key's forced command allows exactly three things:

- `rsync --server …`: `rrsync -wo` into `live/staging` (write-only);
- `activate`: `cp -al staging releases/<stamp>`, an atomic `current` symlink swap, keep three releases;
- `status`: the live release, the release list, and what nginx serves on loopback.

The volume root, which holds the SSH host key, stays root's. The host key is pinned on doc1
(`publicSite.hostKey`); re-pin it if the volume is ever recreated.

### Serving

- nginx on loopback only. gzip on. Per-visitor limits are keyed on `CF-Connecting-IP`,
  because every request arrives from cloudflared: 20 r/s with a burst of 100, 16 connections,
  over-limit answers 429. Access log off; Cloudflare has analytics.
- Cache: pages `max-age=300, s-maxage=86400`; `/o/`, `/images/`, `/api/dump/`
  `max-age=86400, s-maxage=2592000`. Publishing must purge the zone cache once the
  tunnel exists, because the asset URLs carry no version.
- `/o/` keeps the private site's CSP `sandbox`, since it may hold saved third-party pages.
- The site is about 2.4 GB, of which 1.8 GB is downscaled source images (`/o/`). The API is
  51 MB, and its gzipped dumps are 7.2 MB, so an agent wanting the data costs little.

### Map imagery: deliberately not published (2026-10-30)

The user decided against aerial tiles and the basemap for now, as too bandwidth-heavy.
Revisit if the site stays up comfortably. What was settled for later:

- Only manifest layers with `private: false` may go out. On 2026-10-30 these were 1942
  and 1949 (GA/NAA, CC BY 4.0), 1.5 GB. Landgate layers never go out.
- `world.pmtiles` (534 MB, zoom 8) is location-neutral. **`detail.pmtiles` is not**: `fh basemap`
  cuts a box round every located place, private ones included, so it needs a
  public-only cut on the family-history side first.
- The public build passes `FH_BASEMAP=no-basemap` and streams OSM and ArcGIS today.

### Traffic metrics (added 2026-10-30)

- **Grafana:** dashboard **"Family site — family.barrett-lennard.com"** (uid
  `family-public-site`, `dashboards/family-public-site.json`). It shows data served, requests,
  the share of bytes served from Cloudflare's cache (bytes that never crossed our uplink),
  page visits, 429s, per-interval charts by cache status and response code, top countries,
  and exporter lag and errors.
- **Source:** `familypub-cf-exporter` on doc2 (`hosts/doc2/family-public-metrics.{nix,py}`)
  polls Cloudflare's GraphQL `httpRequestsAdaptiveGroups` (Free plan) in closed 5-minute
  windows, about 10 minutes behind. It adds each window into counters persisted in
  `/var/lib/familypub-cf-exporter/state.json`. It serves `127.0.0.1:9472/metrics`, which
  alloy (job `familypub_cf`) remote-writes to Mimir. Its first run backfills 6 hours.
- **Metrics:**
  - `familypub_edge_requests_total{cache,code}`
  - `familypub_edge_bytes_total{cache}`
  - `familypub_edge_country_requests_total{country}`
  - `familypub_edge_visits_total`
  - exporter health: `_window_end_seconds`, `_last_success_seconds`, `_errors_total`
- **Privacy:** aggregates only. No client IP or per-visitor field is requested or stored, and
  the guest's nginx access log is off. Cloudflare itself sees visitor IPs, as any proxy
  does.
- **Token:** `familypub-analytics-read` (id `d24a6da3…`), zone Analytics Read only, no
  expiry. Stored doc2-only at `secrets/hosts/doc2/family-public-cf-analytics` and passed to the
  service as a systemd credential.
- The Cloudflare dashboard (Analytics & Logs → HTTP Traffic, filtered to the host) shows
  the same numbers, with 30 days of history.

## Operations

```bash
# on doc1, after a clean export:
cd ~/family-history && bin/fh export --public --out ~/.cache/fh/public-export \
  --serve /var/lib/family-archive/public-site
family-public-publish            # leak-check the snapshot, push, make it live, purge the edge
family-public-publish status     # live release, releases kept, loopback HTTP codes
```

The command refuses to run alongside another publish (flock), and refuses a tree with no
`index.html`. A leak-check failure stops it before anything is uploaded.

**Rollback** to the previous release: there is no shell in the guest by design. Re-publish
the previous export, or temporarily add a `rollback` verb to the forced command.

**Guest logs:** `ssh doc2 'journalctl -u microvm@familypub -f'`.

## Verification

### Isolation probe

`familypub-isolation-probe` runs at boot and daily inside the guest. It TCP-probes
pfSense, doc1, both doc2 addresses, tower NFS, prom, the slskd/qbt/Plex guests,
pfSense's tailnet address, Forgejo and the open internet, all of which must fail. It
requires DNS, including the tunnel SRV record, and the Cloudflare edge on 7844 to work. A breach
fails the unit and logs `ISOLATION BREACH`.

To read the result:

```bash
ssh doc2 'journalctl -u microvm@familypub | grep -E "isolation-probe|BREACH|ISOLATION"'
```

First run, 2026-10-30 13:03: every target blocked; `region1=198.41.192.67`, SRV
`region2.v2.argotunnel.com:7844`; edge reachable; `ISOLATION OK`. Time synced from
`162.159.200.123`.

### Publish path (2026-10-30)

- **First publish:** leak check clean; 49,344 files, 2.37 GB, at about 83 MB/s; 3 min 28 s
  end to end.
- **Unchanged re-publish:** 0 bytes of literal data. `--delete` removed a stray test file.
- **The release survives a guest restart:** `status` shows loopback 200 on `/`,
  `/api/index.json` and `/robots.txt`.
- **The publish key refused everything else:** an arbitrary command ("refused"), a PTY,
  reading back through rsync (write-only rrsync), writing to `../current`, and `-L` port
  forwarding ("administratively prohibited"). Root login fails with publickey.
- **Absolute paths:** an rsync to an absolute path like `/etc/` lands inside `staging/`
  (rrsync confines it). The next publish's `--delete` removes it.

### From outside (2026-10-30, after the tunnel went live)

- The guest holds 4 registered tunnel connections, over QUIC.
- cloudflared's `api.cloudflare.com` precheck fails by design (blocked; it is only used for
  self-update).
- `/api/index.json` returns 200 JSON, with no challenge, for plain `curl`, a GPTBot user
  agent and a ClaudeBot user agent. `robots.txt` is ours.
- Pages: first request MISS, then HIT. `content-encoding: br` at the edge.
- A 400-request burst (cache-busting queries) got 115 × 200 and 285 × 429: the origin's
  nginx limit answered first, and a plain 429 is the only refusal.
- Publish then purge: the next request is a MISS.
- The isolation probe still reports `ISOLATION OK` with the tunnel running.
- Kuma monitor "Family public site" polls `/api/index.json`.

## Reader reports: `report@barrett-lennard.com`

Decided with the user on 2026-10-30 (option A of three; the others were Gmail filters
only, or Google Workspace with a Google Group). It runs entirely at Cloudflare, so nothing
of it is in the fleet.

```text
sender → Cloudflare Email Routing (MX route1-3.mx.cloudflare.net)
       → rule: to report@ → Worker family-reports (scripts/family-reports/worker.js)
           approved (KV family-reports-approved has the envelope or From address)
               → abl030+familyreports@gmail.com   Gmail filter: label "Family reports"
           anyone else
               → abl030+familystaging@gmail.com   filter: skip inbox, "Family reports/Staging"
               + one "waiting for review" reply per sender per 30 days
                 (never to Auto-Submitted, list or bounce mail; Cloudflare only
                 lets replies reach authenticated senders, so no backscatter)
```

- **Deny by default, but first contacts are kept.** Nothing is dropped. Staging is the
  triage queue. Every message, approved or not, lands only with the user, who passes
  real reports on to family-history by hand. Nothing goes to Forgejo or an agent.
- **Triage:** read the Staging label. To approve a sender, run `family-reports approve <address> [note]`
  on doc1; their later mail skips staging. To discard, delete the message. To revoke, run
  `family-reports remove <address>`. `family-reports list` shows the approved list.
- **Self-service:** a newcomer's first email is their registration, and the auto-reply
  tells them it's awaiting review. There's no confirmation link: since nothing is dropped,
  proving the address adds nothing.
- **Spoofing:** a forged From of an approved address only changes which label the mail
  gets; both labels are read by the user. No auth check is made in the Worker.
- **Other addresses** on the domain are rejected (catch-all disabled). The domain had no
  mail before this; the old Namecheap forwarding MX/SPF records were deleted. DMARC
  stays `p=none` with Cloudflare's report address.
- **Tokens:** `family-reports-approve` (id `55e2b002…`) has Workers KV Storage Write on the
  account and nothing else. It's stored doc1-only at `secrets/hosts/proxmox-vm/family-reports-kv`.
  Redeploying the Worker (`scripts/family-reports/deploy.sh <auth-header-file>`) needs a
  fresh short-lived token with Workers Scripts and KV Write.
- KV namespaces: `family-reports-approved` `8efb90cb…`, `family-reports-replies` `c974ab8a…`.

### Reports test (2026-10-30)

- **New sender:** `andy@cullenwines.com.au`, not yet approved, was staged and got the
  auto-reply (its `replied:` key is in KV). The user confirmed it arrived.
- **Approval:** `family-reports approve` round-trips in KV. The work address was approved
  for the known-sender test. A test of the approved path from it is pending the user, who
  accepted "assume working".
- **Own-Gmail test:** a send from `abl030@gmail.com` (approved) never showed up. That matches
  Gmail discarding forwarded copies of the account's own sent mail. Don't test with it.
- The Gmail filters and the footer line are tracked in family-history#163.

## `tainsh.ablz.au`: a second site, live since 2026-11-08

- **Built:** 2026-11-08. **Status:** **live** since 2026-11-08 at the user's request,
  open to anyone (no Cloudflare Access), `noindex` on every response. No LAN preview:
  `tainsh-preview.ablz.au` was removed the same day at the user's request.
- **Kept current:** every `bin/fh build` on doc1 (main checkout, master) exports the
  family into `/var/lib/family-archive/tainsh-site` and runs
  `family-public-publish --site tainsh`, right after the main public site. Nothing
  else to run.
- **What:** Rosie Tainsh's family (the user's stepmother) from the same private
  catalogue, exported on its own: `fh export … --family rosemary-tainsh-1962`.
- **Why separate:** her family must never appear on family.barrett-lennard.com, so the
  user's mum doesn't come across it while browsing. Cloudflare Access (an email
  allowlist) can still be added later; see the steps below.
- **Cloudflare objects (created 2026-11-08 by API):** proxied CNAME `tainsh` →
  `55ab03aa-….cfargotunnel.com` in ablz.au (record `4aa7184f…`); token
  `tainsh-publish-purge` (id `2d1e41c1…`), Cache Purge on ablz.au only, no expiry,
  `secrets/hosts/proxmox-vm/tainsh-cf-purge`. Minted with a short-lived account token
  the user supplied and then revoked. No cache rule: on ablz.au Cloudflare caches only
  static file extensions for this host, and every publish purges the host.

### How it is built

- **Staging tree** (doc1, `homelab.services.familyArchive.tainshSite.siteDir`,
  default `/var/lib/family-archive/tainsh-site`, abl030-writable): fh swaps its export in
  here; it is not served on the LAN. Nothing from the NAS is in it.
- **Publisher:** `family-public-publish --site tainsh [status | DIR]`. With no `--site`
  (or `--site family`) the command behaves as for the main site. If
  `homelab.services.familyArchive.tainshSite.enable` is false, `--site tainsh` prints
  `tainsh.ablz.au is not enabled (…); nothing published` and exits **3**, before any
  rsync or SSH; fh reads exit 3 as "switched off".
- **Guest** (`hosts/doc2/family-public-microvm.nix`, option
  `homelab.familyPublic.tainsh.enable`, on in `hosts/doc2/configuration.nix`).
- **Monitor:** Kuma "Family tainsh site" polls `https://tainsh.ablz.au/api/index.json`.

### First publish (2026-11-08)

- Leak check clean; 775 files, 5.7 MB; release `20261108T070826Z`; purge ok.
- From outside: `/` 200 with `x-robots-tag: noindex` for plain curl and a GPTBot user
  agent; family.barrett-lennard.com still 200 after the guest restart.

### Mechanics

- **doc1 publisher:** the same flow as the main site: `cp -al` snapshot → `fh export
  --check <snapshot> --family rosemary-tainsh-1962` → rsync → `tainsh activate` → purge.
  The default DIR is `tainshSite.siteDir`. It shares the main site's lock, so only one
  publish runs at a time.
- **Upload path:** the same SSH key and pfSense pinhole. rsync runs with
  `--rsync-path="tainsh rsync"`, and the verbs are `tainsh activate` and `tainsh status`.
  The key's forced command becomes a dispatcher that sends a leading `tainsh ` to a second
  copy of the site command, rooted at `/srv/site/tainsh/{staging,releases,current}` (on the
  same 20 GiB volume, with its own three releases). It strips the prefix so rrsync sees a
  plain `rsync --server`. Anything else still goes to the main site's command.
- **Serving:** a second nginx server on `127.0.0.1:8081`, root `/srv/site/tainsh/current`.
  It has the main site's rate limits, cache headers and `/o/` sandbox CSP, plus
  `X-Robots-Tag: noindex` on every location. The port, not the Host header, separates
  the sites.
- **Tunnel:** the same `familypub` tunnel gains the ingress `tainsh.ablz.au →
  http://127.0.0.1:8081`, ahead of the `http_status:404` catch-all.
- **Purge:** only that host, `{"hosts":["tainsh.ablz.au"]}` on the ablz.au zone
  (`6e11ebc2413104f2220565ccb9c0417e`). A separate purge-only token is needed, because
  `familypub-publish-purge` is scoped to barrett-lennard.com.

### Switching it on (done 2026-11-08; kept for reference)

1. **Cloudflare (by API, as for the main site; mint a short-lived setup token):**
   - DNS in the **ablz.au** zone: a proxied CNAME `tainsh` →
     `55ab03aa-d40a-479c-b897-5802edf2404a.cfargotunnel.com`. The tunnel is locally
     managed, so nothing changes on the tunnel object; a tunnel can serve hostnames in
     any zone of the account. localProxy's DNS sync only touches A records it owns, so
     it leaves this CNAME alone. Never also add `tainsh.ablz.au` to `homelab.localProxy`.
   - A purge-only token: Zone → Cache Purge on ablz.au only, no expiry, named
     `tainsh-publish-purge`. Store it doc1-only:
     `secrets/hosts/proxmox-vm/tainsh-cf-purge` (binary; `sops` from inside `secrets/`).
   - Zone settings on ablz.au: the main site's settings (Bot Fight Mode off, etc.) are
     per zone. ablz.au's defaults are fine for a family site behind `noindex`. Add a
     cache rule for host `tainsh.ablz.au` (cacheable, TTL from origin) if pages should be
     edge-cached. Without one, Cloudflare caches only static file extensions.
   - **Optional, Rosie's call: Cloudflare Access.** Zero Trust → Access → Applications →
     self-hosted, domain `tainsh.ablz.au`, a policy "Allow" with an Emails include list,
     and the one-time PIN login method. Nothing in the fleet changes for it. The Kuma monitor
     "Family tainsh site" would then see the Access login. Give it an Access service
     token or drop the monitor.
2. **Nix, in one commit:**
   - `hosts/proxmox-vm/configuration.nix`: `homelab.services.familyArchive.tainshSite.enable = true;`
   - `hosts/doc2/configuration.nix` (or the microVM file):
     `homelab.familyPublic.tainsh.enable = true;`
3. **Deploy:** `sudo fleet-update` on doc1, then `fleet-deploy doc2`. The guest restarts
   (a new forced command, nginx server and ingress), so the main site has a short blip.
4. **First publish:** `family-public-publish --site tainsh`, then
   `family-public-publish --site tainsh status`. From outside, check
   `curl -sI https://tainsh.ablz.au/` (noindex header, 200, or the Access redirect).

Switching it off again: set both options back to false and deploy, then delete the
CNAME. The files stay on the volume under `/srv/site/tainsh` until removed by hand from a
temporarily added verb, or the volume is recreated.

## Follow-ups

- family-history#163: the user's Gmail filters, a test from the approved work address,
  and the footer line `Spotted a mistake, or know more? Write to report@barrett-lennard.com`.
- Map imagery, if the site stays up (see above).
