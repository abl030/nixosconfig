# NZBGet

**Last updated:** 2026-06-18
**Status:** active on **tower** (Unraid) — NZBGet 26.1
**Owner:** NOT in this repo. Runs as a Docker container on the Unraid host
(`tower`, 192.168.1.2). Has its own LAN IP **192.168.1.17** via an ipvlan on
`br0`. Public URL `https://nzbget.ablz.au` (Caddy → the container).
**Config file:** `/config/nzbget.conf` inside the container.

NZBGet is the Usenet downloader. It is **not** managed by this NixOS repo — the
only repo reference is doc2's egress allowlist (`hosts/doc2/configuration.nix`,
`192.168.1.17 # tower nzbget`). Manage it through its web UI or the JSON-RPC API.

## Controlling it via the JSON-RPC API

NZBGet exposes a full JSON-RPC API that covers **settings**, not just queue
control. Reach it directly on the LAN (fastest, no Cloudflare round-trip):

```
http://192.168.1.17:6789/jsonrpc/<method>
```

Auth is HTTP Basic. There are three credential tiers in `nzbget.conf`; only the
**Control** tier (`ControlUsername` / `ControlPassword`) can read or write
config. Restricted/Add tiers get 401 on `loadconfig`/`saveconfig`. Credentials
live in the Unraid container settings / `nzbget.conf` — **not stored here.**

Useful methods:

| Method | Purpose |
| --- | --- |
| `version` | Sanity/auth check (returns `"26.1"`). |
| `status` | Live runtime state: `DownloadRate`, `DownloadLimit` (runtime speed cap, 0 = unlimited), `*Paused`, `ThreadCount`, free disk. |
| `loadconfig` | Full config **as stored on disk** (array of `{Name,Value}`). |
| `config` | Full config **currently loaded in memory** (may differ from disk until a reload). |
| `saveconfig` | Write config to disk. Takes ONE param: the full `{Name,Value}` array. |
| `reload` | Restart internals to apply saved config (needed for server-connection changes). |
| `log` | Recent log lines — `log(idfrom, nentries)`; great for spotting errors. |

### Safe config-edit pattern (read–modify–write)

`saveconfig` rewrites the whole config from the array you send, so always pull
the full set, change only the keys you want, and write it all back — exactly
what the web UI does:

```python
cfg = call("loadconfig")                    # full array from disk
for o in cfg:
    if o["Name"] == "Server1.Connections":
        o["Value"] = "40"
call("saveconfig", [cfg])                    # note: ONE param = the whole array
call("reload")                               # server-connection changes need a reload
```

**Gotcha — disk vs. memory:** after `saveconfig`, `loadconfig` (disk) shows the
new value but `config` (memory) still shows the old one. Server connection
settings only take effect after `reload`. `reload` drops the RPC connection
briefly while NZBGet restarts (~5–8 s); it does not interrupt the queue if
nothing is actively downloading. Verify with `config` after.

## Incident 2026-06-18 — slow downloads (1–8 Mbit on a gigabit line)

**Symptom:** ~8 Mbit on a good day, 1–2 Mbit otherwise, despite a gigabit line
(client was behind the VPN at the time, but that was not the cause).

**Root cause:** `Server1.Connections = 150`, but the Eweka account
(`news.eweka.nl:563`, SSL) allows only **50 simultaneous connections**. NZBGet
opened 150; Eweka accepted ~50 and rejected the rest. The log was wall-to-wall:

```
[ERROR] Authorization for Eweka (news.eweka.nl) failed: 502 Too many connections
```

The rejected sockets were retried constantly, so the effective pool was a
churn of connect→reject→retry instead of a stable downloading set. That churn —
not a speed limit — produced the erratic, slow throughput. (`DownloadRate=0`
config and `DownloadLimit=0` runtime both confirmed there was **no** speed cap.)

**Fix:** dropped `Server1.Connections` **150 → 40** via the read-modify-write
pattern above, then `reload`. Chose 40 rather than the full 50 to leave headroom
under the cap (other devices may also hit Eweka) and to cut SSL-handshake
overhead through the VPN. `502 Too many connections` errors stopped immediately.

**Rule of thumb:** `ServerN.Connections` must stay **at or below the provider's
per-account connection limit.** Over-subscribing does not increase speed — it
causes 502 rejections and connection churn that *reduce* it.

### Secondary tuning (not yet applied — optional)

On reload NZBGet logged warnings flagging two defaults worth improving:

- `ArticleCache = 0` (disabled) — enabling a RAM article cache (e.g. a few
  hundred MB) reduces disk fragmentation and helps reassembly throughput.
- `WriteBuffer = 0` — uses the small default system buffer; setting e.g. `1024`
  (KB) is more efficient.

Both are safe `saveconfig` + `reload` changes; left as a follow-up. Sizing
depends on how much RAM the Unraid container should be allowed.

## See also

- NZBGet JSON-RPC reference: <https://nzbget.com/documentation/api/>
- VPN/DNS topology context: `docs/wiki/infrastructure/pfsense-dns-resolver.md`
