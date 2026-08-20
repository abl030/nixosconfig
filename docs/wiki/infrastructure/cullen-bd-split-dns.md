# Cullen LAN access to `bd.ablz.au`

**Status:** deployed through WSL boundary
**Canonical service:** `bdday.service` on doc1 (`192.168.1.29`)

## Intentional topology

`bdday` is stateless but has one canonical deployment on doc1. Cullen clients do
not run a second copy and do not receive a route into the home LAN.

```text
Cullen client
  → internal work DNS: bd.ablz.au = 192.168.100.128 (Windows laptop)
  → Windows :443 portproxy
  → WSL nginx (TLS for bd.ablz.au)
  → doc1 nginx / bdday (192.168.1.29:443)
```

The ordinary/public DNS record remains owned by doc1. The internal work-DNS
override is intentionally the only DNS change for Cullen clients.

## WSL proxy requirements

The WSL vhost connects to the numeric doc1 address, rather than resolving
`bd.ablz.au`, so the internal override cannot form a recursive proxy loop. It
preserves `Host: bd.ablz.au`, verifies the upstream certificate, and explicitly
sets TLS SNI to `bd.ablz.au`.

The proxy trusts the public ISRG Root X1 anchor at
`hosts/wsl/isrg-root-x1.pem` (official SHA-256 fingerprint
`96:BC:EC:06:26:49:76:F3:74:60:77:9A:CF:28:C5:A7:CF:E8:A3:C0:AA:E1:1A:8F:FC:EE:05:C0:BD:DF:08:C6`,
valid through 2035). WSL's generated CA bundle did not contain that root while
doc1 served the current YE2 chain. This trusts the issuing public CA rather
than pinning a rotating doc1 leaf certificate.

Do **not** put this hostname in `homelab.localProxy.hosts` on WSL: that module's
DNS synchroniser would claim the public Cloudflare A record and take it away
from doc1. The vhost instead declares its own DNS-01 ACME certificate; WSL
already has the Cloudflare credential required for this.

`cullen.ablz.au` remains its independent WSL local-proxy vhost and is not
replaced or redirected by this route.

## Cullen-side DNS and firewall

The work-DNS operator creates the split-horizon record:

```text
bd.ablz.au.  A  192.168.100.128
```

Keep the initial TTL short (300 seconds) during rollout. The dedicated Windows
firewall rule `Cullen WSL HTTPS (TCP 443)` permits TCP 443 only from the
intended Cullen client range (`192.168.100.0/24`) to the
Windows Cullen-LAN address (`192.168.100.128`); do not use this path to expose a
new general inbound route.
The existing Windows `:443` portproxy remains responsible for following the
changing WSL NAT address.

## Verify

From a Cullen client:

```bash
# must resolve to the Windows laptop
getent ahostsv4 bd.ablz.au

# must present a valid bd.ablz.au certificate and the calendar dashboard
curl -fsS https://bd.ablz.au/healthz
```

On WSL, confirm the proxy's upstream stays doc1 and validates TLS:

```bash
curl --resolve bd.ablz.au:443:192.168.1.29 https://bd.ablz.au/healthz
```

Also browse `https://cullen.ablz.au` after rollout. It must retain its existing
dashboard redirect and certificate.

## Rollback

Remove the internal A record first (or restore its previous value), then remove
the WSL `bd.ablz.au` virtual host in a normal deployment. Do not remove the
Windows :443 portproxy or the `cullen.ablz.au` vhost as part of this rollback.
