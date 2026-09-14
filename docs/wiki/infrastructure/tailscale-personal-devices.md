# Personal Tailscale devices and access levels

- Date: 2026-09-15
- Status: all four current clients user-owned; direct NAS access verified on Cullen, Epimetheus and Framework
- Source: `tailscale/acl.hujson`, applied by doc1's `tailscale-acl-apply.service`
- Related: [tailnet policy](tailscale-acl.md), [Dad NAS](../services/dadnas.md),
  [Cullen SSH](wsl-tailscale-ssh.md)

## Identity and access

Personal devices use `abl030@gmail.com` to consume Dad's incoming machine share.
Their network permissions come from explicit IP sets. Infrastructure retains its
service tags. There is no account-wide network grant.

| Device | Set | IPv4 | IPv6 |
|---|---|---|---|
| Framework | `ipset:trusted-clients` | `100.78.17.73` | `fd7a:115c:a1e0::2101:114e` |
| Epimetheus | `ipset:trusted-clients` | `100.115.114.53` | `fd7a:115c:a1e0::e633:7235` |
| Epimetheus VM | `ipset:trusted-clients` | `100.127.127.81` | `fd7a:115c:a1e0::4033:7f51` |
| Galaxy A55 | `ipset:trusted-clients` | `100.102.60.123` | `fd7a:115c:a1e0::5301:3c7b` |
| Cullen Windows/WSL | `ipset:cullen` | `100.75.246.114` | `fd7a:115c:a1e0::1a33:f672` |

Both addresses belong in each set. The old client and Cullen tags grant no
network access; their definitions remain during reauthentication. All source and
destination role references, including incoming Syncthing and Cullen management,
use the sets. Existing exact IPv4-only exceptions remain IPv4-only.

Trusted clients retain their fleet access, home/Dad/Mum subnet access, exit-node
use, and the existing three Cullen HTTPS destinations. Cullen retains its exact
DNS, SSH, HTTPS, Gotify, NFS, Syncthing, and streaming exceptions. Both sets gain
Dad NAS TCP 5000 and 5252 over IPv4 and IPv6, without NAS file-service access.

New devices get no role until explicitly added. Reauthentication should retain
addresses; verify both afterward. Do not delete/recreate nodes to change ownership.
If Cullen's addresses change, its Windows OpenSSH/firewall/portproxy bindings also
need updating before remote access can work.

## Ownership migration

Deploy the IP-set policy first: it works with both tagged and user-owned devices.
Framework and Epimetheus were offline at preflight. The old Epimetheus VM was last
seen 2025-12-05; its existing membership is preserved pending a retirement decision.

Tailscale requires a user login to replace a tagged identity. Removing the last
tag through the API is unsupported. Even an admin OAuth client cannot mint an
untagged user key: the API returned `tailnet-owned auth key must have tags set`.
Use interactive login or a one-use untagged auth key created by Andrew himself.

On CLI devices, use `tailscale up --advertise-tags= --force-reauth` with the
existing non-default settings and log in as `abl030@gmail.com`. Do not log out
first or reset preferences. Android requires reauthentication through its app.
Verify the resulting owner, absence of tags, and addresses in live status.
On Android, open the account switcher from the profile/avatar and select
**Reauthenticate**, then use `abl030@gmail.com`; do not delete the device.

Framework came online at 19:53 AWST with its original addresses and legacy tag.
Its live sudo policy requires a password for Tailscale administration; unprivileged
reauthentication returned `checkprefs access denied`. Run the login locally with
`sudo tailscale up --advertise-tags= --force-reauth --accept-routes --netfilter-mode=on`
and authenticate as Andrew. Unlike Epimetheus, Framework already accepts subnet
routes; preserve that preference. No sudo or operator permissions were widened.

Cullen advertises `192.168.100.0/24` and exit routes; only `192.168.100.0/24` is
approved. Preserve that exact approved list. `autoApprovers` cannot use IP sets,
so manually approve the work route on node `n6aoy39Erd11CNTRL` after reauthentication.
Do not substitute an account-wide auto-approver or approve its default routes.
Verify the existing solar dashboard and water-meter paths afterward.

## Features outside network grants

OpenSSH continues to use the network rules and host SSH keys. Tailscale SSH also
requires a TCP 22 network grant, so its existing own-device check rule does not
give Cullen general access to personal devices. Cullen and the personal NixOS
hosts use ordinary OpenSSH.

Taildrop was enabled at preflight. It permits file transfers between devices
owned by the same user even when network ACLs deny connections. This migration
does not change that separate setting; do not describe the network restrictions
as preventing same-owner Taildrop. Tailnet-wide disabling is a separate decision.

Dad's port 5252 is the Tailscale web interface. The existing user-owned proxy
received `canManageNode:false`: sharing does not transfer management rights.
DSM on port 5000 still requires a NAS login.

## Verification and recovery

Signed policy commit `d2e6c3c9` was deployed through doc1's verified fleet update.
All 72 control-plane policy tests and `nix flake check` passed, and the live
policy matched the deployed source. On 2026-09-14, Cullen reauthenticated as
`abl030@gmail.com`, with no tags and both original addresses retained.

Windows and WSL both fetched NAS IPv4 ports 5000 and 5252 successfully (HTTP 200);
Windows also fetched port 5252 over IPv6. Initial IPv4 requests after reauthentication
timed out, then repeated direct requests succeeded without a policy change or
service restart. The exact cause of that transient delay was not established.
Cullen's peer map uses source `100.86.248.7` when talking to Dad's NAS
(`SelfNodeV4MasqAddrForThisPeer`); its normal tailnet address remains unchanged.

Windows/WSL SSH, Cullen-to-doc1 SSH, doc2 Syncthing, DNS, Dad NAS HTTPS and Shelfarr
HTTPS all passed. Cullen-to-doc2 HTTPS and Cullen-to-phone SSH remained denied.
Only the work subnet was approved after login; neither exit route was approved.
Both solar inverters and the water meter were reachable through that route.
At the Cullen verification, the phone still had `tag:client`; Framework and
Epimetheus were offline and tagged. At 14:14 AWST, the phone's reauthentication
was verified: no tags, Andrew's user identity, and both original addresses.
Termux SSH refused connections, so a NAS fetch from the phone itself was not
verified remotely. Epimetheus was subsequently woken at the user's request and
its user-login flow started over LAN SSH, preserving its existing preferences.
At that point, Framework and the old Epimetheus VM were still offline and tagged.

Epimetheus completed reauthentication at 14:17 AWST, retaining its node ID and
both addresses. Its owner is `abl030@gmail.com`, with no tags. DNS, doc1 SSH,
Syncthing in both directions, and Cullen's IPv4 SSH connection passed. Its
existing preferences were preserved, including `accept-routes=false` and
`netfilter-mode=on`. Cullen's IPv6 port-22 connection timed out; its existing
Windows portproxy is bound to IPv4, so this was not changed by the migration.

Dad NAS initially answered only over IPv6 from Epimetheus. IPv4 SYNs left its
Tailscale interface without replies. Restarting Epimetheus's `tailscaled` over
the independent LAN SSH connection cleared the failure immediately. Both NAS
ports (5000 and 5252) then repeatedly returned HTTP 200 over IPv4 and IPv6, with
the DSM and Tailscale page titles verified. No ACL or NAS-side change was made.
The local reconnect is a useful recovery step for this post-reauthentication
symptom; the exact cause of the stale IPv4 path was not established.

At 19:56 AWST Framework's user login was verified: Andrew's identity, no tags,
original IPv4/IPv6 addresses, and `accept-routes=true` retained. SSH, Syncthing
in both directions (including inbound IPv6), DNS, Cullen IPv4 SSH, Dad NAS HTTPS
and Shelfarr HTTPS passed. Both NAS ports returned their correct pages over IPv6;
direct NAS IPv4 requests showed the same post-reauthentication timeout as Epi.
Framework's passworded sudo required the user to run
`sudo systemctl restart tailscaled` locally. On 2026-09-15, after that restart,
both NAS ports returned HTTP 200 over IPv4 and IPv6 with the correct DSM and
Tailscale titles. SSH, Syncthing in both directions (including inbound IPv6),
DNS, Cullen IPv4 SSH, Dad NAS HTTPS and Shelfarr HTTPS passed again. Framework's
identity, addresses and preferences remained unchanged. The live policy still
matched the repository source, and Cullen retained only its approved work route.
All four current clients are now user-owned and untagged; the phone's direct HTTP
check remains unverified because Termux SSH was unavailable. The old offline
Epimetheus VM is the only device still using the legacy client tag; its existing
role membership is preserved.

Policy tests cover each role member's IPv4 and IPv6, incoming client access,
Cullen isolation, Shelfarr IPv6, NAS web ports, and unlisted addresses. Match
source and destination address families. The API can return HTTP 200 with failed
tests; require an empty validation result.

Live checks must cover Windows SSH/WSL SSH, Cullen DNS/HTTPS, denied connections,
approved work routes, and the actual NAS page at `http://100.103.36.101:5252/`
after user authentication. The existing `https://dadnas.ablz.au/` relay remains.

Preflight policy, ETag and device inventory are root-only under
`/var/backups/tailscale-personal-20260914/`. Restore access through a signed policy
correction. Reverting to the old tag-only policy after untagging devices would
remove their permissions; retain the IP-set grants or re-tag before rollback.

Sources: [tags](https://tailscale.com/docs/features/tags),
[IP sets](https://tailscale.com/docs/features/tailnet-policy-file/ip-sets),
[route approval, SSH and Taildrop](https://tailscale.com/docs/reference/syntax/policy-file).
