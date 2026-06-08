---
name: sops-recipient-model
description: "Post-#234 sops secret model — per-host scoping, break-glass + editor keys, master retired"
metadata: 
  node_type: memory
  type: project
  originSessionId: 50946a58-6570-4833-96f2-140e7d93a90d
---

As of #234 (2026-06-08) `secrets/.sops.yaml` is **per-host scoped**: a file under
`secrets/hosts/<H>/` decrypts only on host `<H>`, plus two universal keys —
**break-glass** (cold, recovery-only, on **no host**: Bitwarden secure note +
printed paper; pub `age1y6na…`) and **editor** (warm, doc1
`~/.config/sops/age/keys.txt`, drives all re-keys/edits; pub `age17uw7…`).
Multi-host rules: acme→{doc1,doc2,igpu,wsl}, uptime-kuma→{doc1,doc2,igpu};
fleet-wide (nix-netrc/atuin-*/gotify)→all 7 live hosts; **fail-closed `.*`
fallback** (editor+break-glass only). `sopsRecipientScopeCheck` in `flake.nix`
enforces it. `ssh_key_abl030`, the MCP creds, and the pfSense *control* token are
doc1-only; doc2's exporter has a separate read-only pfSense key.

**There is no "master" recipient anymore** — the old "Master Fleet Identity" was
`ssh-to-age(ssh_key_abl030)` (the fleet SSH key in age form), retired in #234.
Don't go looking for a master key.

**Why:** a popped sibling could `sops -d` every secret (incl. the fleet key),
undermining the [[fleet-ssh-topology]] bastion at the secret layer; and there was
no real off-box break-glass.

**How to apply:** to re-key after a `.sops.yaml` change, run `sops updatekeys`
from **inside `secrets/`** (config discovery uses CWD, not the file path) — doc1's
editor key decrypts everything. Full model, recovery, rollback, and editor-key
reconstruction: `docs/wiki/infrastructure/sops-break-glass-recovery.md`. dev +
sandbox hosts were decommissioned in the same work.
