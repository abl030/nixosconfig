---
name: tailscale-acl-state
description: "Tailscale ACL (#239) — staged 5-tag policy is LIVE, the default-deny flip is still pending"
metadata: 
  node_type: memory
  type: project
  originSessionId: 70ff841b-f452-4890-844b-7d04e0ca9153
---

#239 tailscale least-privilege ACL. **FLIPPED to default-deny 2026-06-21** — the live tailnet
runs the 5-tag `grants` policy (`tailscale/acl.hujson`): tags server/client/share/edge/**cullen**,
all 20 nodes tagged, 6 stale culled, allow-all REMOVED. Verified from doc1 (server paths, DNS,
doc1→cullen:22 deploy, `ssh wsl` → wsl DNS+git+tower-NFS, static accept+deny gate, clean Loki).
**Owner still to live-verify device-to-device (Sunshine/RDP/Syncthing), overseer-from-phone,
ali@'s overseer share** — paths a server vantage can't test.

tag:cullen = laptop-btibh4ie (Cullen laptop): strictest — out = pfSense:53 DNS +
192.168.1.0/24:{443,8050} mgmt + tower NFS (192.168.1.2:2049) + Syncthing mesh; in =
doc1/framework→:22. NOT client↔client, NOT broad fleet/exit. wsl keeps NFS now; Syncthing-only
is "future us" (forgejo#4). client↔client is a blanket `tag:client→tag:client:*`.

REVERT if anything breaks: re-add `{src:["*"],dst:["*"],ip:["*"]}` to acl.hujson grants +
`gitops-pusher apply` from doc1 (reaches api.tailscale.com over the internet, not the tailnet).

**Apply path** = `gitops-pusher` on **doc1** (the bastion) with the `policy_file` OAuth cred
at `secrets/hosts/proxmox-vm/tailscale-acl-oauth.env` (module `acl-apply.nix`; daily timer +
manual). Manual run:
`cd ~/nixosconfig; set -a; eval "$(cd secrets && sops -d hosts/proxmox-vm/tailscale-acl-oauth.env)"; set +a; export TS_TAILNET=-; nix run nixpkgs#tailscale-gitops-pusher -- -policy-file=tailscale/acl.hujson apply`
**Revert** (if a flip breaks something) = re-add allow-all + apply — works from doc1 over the
internet (api.tailscale.com), NOT via the tailnet, so it survives a darked tailnet.

**Tagging** needs a SEPARATE devices-write OAuth client (ephemeral; the policy_file cred can't
tag). The throwaway one used on 2026-06-21 is to be deleted by the owner.

Full audit, complete grant set, gaps, and flip procedure:
`docs/wiki/infrastructure/tailscale-acl-flip-audit.md`. Stale-handle nuisance that fails every
deploy = forgejo#3. See also [[forgejo-issue-token-doc1]], [[forgejo-push-from-doc1]].
