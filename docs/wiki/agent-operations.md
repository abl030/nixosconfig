# Agent operations primer

**Audience:** AI agents from `git.ablz.au/abl030/agents` (paperless triage, accounting/beancount, etc.) that need to read or modify the NixOS service modules powering the services they call into.

**Goal:** answer "where is `<setting>` configured for `<service>`?" in 1-2 file reads, without grep-walking the tree.

This file is a **map**, not documentation of the modules themselves. The modules are short — read them once you know which one to open.

---

## Service map

Each row: enable site -> module file -> what it owns. All current services run on **doc2**.

| Service | Enabled in | Module | Notes |
|---|---|---|---|
| paperless-ngx | `hosts/doc2/configuration.nix` (`homelab.services.paperless`) | `modules/nixos/services/paperless.nix` | Wraps upstream `services.paperless`. NFS-backed media/consume dirs symlinked through `/var/lib/paperless-{media,consume}`. Postgres in nspawn container (`paperless-db`). |
| beancount + Fava | `hosts/doc2/configuration.nix` (`homelab.services.beancount`) | `modules/nixos/services/beancount.nix` | Custom module: clones `git.ablz.au/abl030/books`, runs `fava` directly. **No Fava config file** — see Fava section below. |
| books-repo auto-pull | (same as beancount) | `modules/nixos/services/beancount.nix` | `beancount-clone.service` (oneshot, first run) + `beancount-pull.timer` (every 5 min, `git fetch` + `git reset --hard origin/master`). User: `fava`. |

Find any other `homelab.services.<name>` enable site fast:
```bash
grep -rn "homelab\.services\.<name>" hosts/
```

---

## Fava: the `fiscal_year_end` case (and Fava-only options in general)

**There is no separate Fava config file in this repo.** `modules/nixos/services/beancount.nix` starts Fava with:

```
fava --host 127.0.0.1 --port 5023 <books>/main.beancount
```

Fava reads its options out of the **journal itself**, via `custom "fava-option"` directives:

```beancount
2010-01-01 custom "fava-option" "fiscal-year-end" "06-30"
```

So:

- **`option "fiscal_year_end" "06-30"`** in the journal -> rejected by `bean-check` (it's not a Beancount core option).
- **`custom "fava-option" "fiscal-year-end" "06-30"`** in the journal -> accepted by `bean-check`, honoured by Fava.
- **Editing the NixOS module to set it** -> wrong place; the module has no Fava config surface.

To answer "is `fiscal_year_end` set on doc2?":
1. The journal repo is `git.ablz.au/abl030/books`, cloned to `/mnt/virtio/beancount/books` on doc2 by `beancount-clone.service`.
2. `grep -rn "fava-option" main.beancount` (or wherever the option directive lives) in that repo. If it's not there, it's not set.

To **add** Fava config surface to the module (e.g. expose options via Nix), edit `modules/nixos/services/beancount.nix` and pass flags or a config file to the `fava` ExecStart. Today there is no such option.

---

## Config surface per module

Pick the file from the table, then:

- Options live under `options.homelab.services.<name>` at the top of the module.
- Override sites for those options live in `hosts/doc2/configuration.nix`.

Quick greps:
```bash
# Where's a setting defined?
grep -nE "fiscal|consumer|polling|port" modules/nixos/services/beancount.nix
grep -nE "PAPERLESS_|consume|media|port" modules/nixos/services/paperless.nix

# What does doc2 actually set?
sed -n '/homelab.services.paperless/,/^      [a-z]/p' hosts/doc2/configuration.nix
```

For paperless application settings (PAPERLESS_*), the source of truth is the `settings = { ... }` attrset in `paperless.nix`. Anything not listed there is at upstream nixpkgs default.

---

## Edit -> validate -> deploy

This repo has **no PR workflow for agents**: edits land on `master`, doc2 pulls from GitHub.

### Validate locally (any host with the repo checkout)

```bash
nix flake check                              # eval all hosts; cheap & broad
nix build .#nixosConfigurations.doc2.config.system.build.toplevel   # full closure build for doc2
nix run .#fmt-nix -- --check                 # formatting (alejandra)
nix run .#lint-nix                           # deadnix + statix
```

A successful `nix flake check` is the bar before pushing.

### Deploy to doc2

**Always pull-from-GitHub. Never `--target-host`.** (See top of `CLAUDE.md`.)

```bash
git push
ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"
```

`--refresh` forces Nix to re-resolve the flake ref — without it doc2 may use a cached older revision and silently no-op.

For other hosts, substitute the hostname (`#doc2` -> `#proxmox-vm`, `#igpu`, etc.). The flake URI hostname must match the **target machine's** hostname, not the agent's caller.

### Auto-deploy

`rolling-flake-update.service` on doc1 (`proxmox-vm`) bumps flake inputs and rebuilds nightly at 22:15 AWST. doc2 has its own auto-update. Neither auto-deploys agent-driven module edits — those still need the explicit `nixos-rebuild switch` above.

---

## Secrets (sops-nix)

All secrets are sops-encrypted under `secrets/`. The repo uses a fallback resolver: `config.homelab.secrets.sopsFile "<name>"` searches in order:

1. `secrets/hosts/<hostname>/<name>`
2. `secrets/users/<user>/<name>`
3. `secrets/<name>`

Implementation: `modules/nixos/common/secrets.nix`.

### Service -> secret map

| Service | sops entry | File on disk (encrypted) | Decrypted to |
|---|---|---|---|
| paperless | `paperless/env` | `secrets/paperless.env` | `/run/secrets/paperless/env` (mode 0400, owner `paperless`) |
| paperless | `paperless/password` | `secrets/hosts/doc2/paperless-admin-password` | first-run admin password only |
| beancount | `beancount/deploy-key` | `secrets/hosts/doc2/beancount-deploy-key` | SSH key Fava uses to clone+pull `abl030/books` from Forgejo |

### What's PII vs safe to print

- **PII / never print:** decrypted contents of any `/run/secrets/*` path on the live host. Document IDs / paperless metadata about real people. Journal entries (the books repo is private).
- **Safe to print:** the *names* of secrets, sopsFile paths in this repo, the encrypted blobs themselves.
- The `.sops.yaml` Age public keys at `secrets/.sops.yaml` are public by design.

To edit a secret: use the `sops-decrypt` skill (it handles the keyring + sops binary). Direct `sops` invocations also work if the agent's host is in `.sops.yaml`.

---

## Cross-reference

- Agents repo: `git.ablz.au/abl030/agents` — agent definitions (paperless triage, accounting, etc.) that consume the services this primer maps.
- This repo's `CLAUDE.md` -> "AI Tool Integration" section: where MCP servers are wired in.
- `.claude/rules/nixos-service-modules.md` — module-authoring rules; read this before *adding* a service, not before tweaking one.
- `docs/wiki/services/lgtm-stack.md` — log/metric query paths if you need to debug a service after deploy.

---

**Last updated:** 2026-05-01.
**When to revise:** if Fava grows a config-file surface, if paperless moves off doc2, or if a new agent-touched service is added to this repo. Update the service map first, the deploy section last (it changes least often).
