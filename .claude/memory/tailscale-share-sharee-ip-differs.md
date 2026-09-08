---
name: tailscale-share-sharee-ip-differs
description: A node shared to another tailnet gets a DIFFERENT 100.x IPv4 there (IPv6 is preserved), so the share module's Cloudflare A record can be wrong for a sharee; fixed by the publishIpv6 AAAA option
metadata:
  type: project
---

Tailscale assigns a shared machine a new IPv4 in the recipient's tailnet when its home address
is already taken there (kb/1084). Seen live 2026-09-08: `overseer` is 100.70.211.51 on
tail13796 but a friend's console shows 100.70.211.50; the sidecar's `tailscale debug netmap`
lists that friend's two devices with `SelfNodeV4MasqAddrForThisPeer=100.70.211.50` (tailscaled
masquerades per peer). Other sharees (the sister's tailnet, no masq entry) still see .51, which
is why "it works for her" proved nothing. `SelfNodeV6MasqAddrForThisPeer` is empty, i.e. the
Tailscale IPv6 (`fd7a:115c:a1e0::/48`) is the same in every tailnet, and caddy answers on it.

**Why:** `modules/nixos/services/tailscale-share.nix` published only an A record
(`tailscale ip -4`), so a remapped sharee resolved the wrong address and the FQDN failed for
them alone.

**How to apply:** commit 6fde7e7e added `homelab.tailscaleShare.<name>.publishIpv6` (AAAA
from `tailscale ip -6`, deleted again when set false). Enabled on doc2 `overseerr` as a trial
on 2026-09-08 and the AAAA propagated the same day. If the remapped friend confirms the share
works, turn it on for audiobookshelf, ali-music, yoto, yotodav (doc2) and jellyfin (igpu).
Diagnose any "wrong IP in my console" report with the netmap dump before changing anything.
Wiki: `docs/wiki/services/tailscale-share.md` → "Sharee-side IPv4 remapping".
See [[tailscale-acl-state]].
