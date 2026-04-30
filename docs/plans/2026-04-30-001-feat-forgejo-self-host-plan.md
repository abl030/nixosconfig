---
title: "feat: Self-host Forgejo on doc2 and migrate nixosconfig flake to it"
type: feat
status: superseded
date: 2026-04-30
origin: https://github.com/abl030/nixosconfig/issues/223
superseded_by: docs/brainstorms/2026-04-30-forgejo-v0-requirements.md
superseded_on: 2026-04-30
---

> **SUPERSEDED 2026-04-30.** Scope was pulled back to a much smaller v0
> after a brainstorm pass — see
> `docs/brainstorms/2026-04-30-forgejo-v0-requirements.md`. The module
> shape changed (no sops, no declarative admin, HTTPS-only git, port 3023,
> `git.ablz.au` not `forge.ablz.au`, dumps to NFS). U4 (GitHub
> pull-mirror), U5 (Forgejo Actions runner), U6 (flake-URL cutover),
> U7 (mirror inversion), and U8 (agent migration / `tea` / CLAUDE.md
> updates) are deferred indefinitely until v0 has soaked. Keep this file
> as historical context only.

# feat: Self-host Forgejo on doc2 and migrate nixosconfig flake to it

## Overview

Stand up Forgejo on doc2 as our primary git forge, then phase-migrate `nixosconfig` itself onto it so flake refs, remote rebuilds, CI runners, and issue tracking move off GitHub. Keep GitHub as a downstream push mirror for the public-safe subset. Private agent-definition repos live only on `forge.ablz.au`.

The module shape is the easy part — the hard part is the cutover. Forgejo runs *on* doc2, and doc2 itself rebuilds nightly from a flake URL — so a naive "flip the URL" change creates a chicken-and-egg failure mode where Forgejo being down stops doc2 from healing itself. This plan phases the cutover (one host → fleet → invert mirror direction) and keeps GitHub hot as a fallback flake source until we trust the new path.

---

## Problem Frame

Issue #223 picked Forgejo over Gitea/GitLab CE based on governance (non-profit Codeberg e.V.), footprint (~150–250 MB RAM), and NixOS module quality (`services.forgejo.*` is first-class with LTS package, `LoadCredential` secrets, integrated dump backups). The remaining work is implementation — concretely: how do we wire it into our `homelab.*` infra, where does the data live, how do we mirror to GitHub, and how do we re-route the entire fleet's flake without bricking ourselves.

Constraints:
- Must follow `.claude/rules/nixos-service-modules.md` (upstream module > custom > OCI; no hardcoded LAN IPs; restartTriggers if it gets a DB container; standard infra wiring).
- Must run on doc2 (CLAUDE.md fleet overview: doc2 already hosts immich, paperless, mealie, kopia, uptime-kuma, etc.; light footprint expected).
- Cannot break the rebuild path during cutover (every host nightly hits `system.autoUpgrade.flake`).
- Issue tracking moves with the forge — we use issues for everything (per memory and CLAUDE.md "Issue Tracking with GitHub Issues" section).

---

## Requirements Trace

- R1. Forgejo reachable at `https://forge.ablz.au` with valid ACME cert and Cloudflare DNS, monitored by Uptime Kuma. (issue #223 checklist)
- R2. NixOS module under `modules/nixos/services/forgejo.nix` following the established pattern; enabled in `hosts/doc2/configuration.nix`. (rules.md)
- R3. State persisted on virtiofs (`/mnt/virtio/forgejo`) for portability between hosts, surviving doc2 rebuilds. (rules.md "Host Assignment")
- R4. Secrets handled via sops-nix using `services.forgejo.secrets` (LoadCredential) and `homelab.secrets.sopsFile` for derived files (admin password, GitHub PAT for mirror, runner registration token).
- R5. `nixosconfig` mirrored on Forgejo with bidirectional sync to GitHub during the validation window; primary direction inverts at the end of cutover.
- R6. Every host's `system.autoUpgrade.flake` cleanly switches to `git+https://forge.ablz.au/abl030/nixosconfig` with a documented one-line rollback to GitHub.
- R7. Forgejo Actions runner replaces the existing `services.github-runners.proxmox-bastion` workflow runner — or the GitHub-side runner keeps working off the GitHub mirror, whichever is cheaper. (decision in U5)
- R8. CLAUDE.md and any `gh`-based agent tooling updated so future agent sessions reach for the right forge.
- R9. Private repos for agent definitions exist on Forgejo and are not mirrored to GitHub.

---

## Scope Boundaries

In scope:
- Forgejo + module + infra wiring + cutover for `nixosconfig`.
- One Forgejo Actions runner (or decision to keep using GitHub Actions).
- Documentation update (CLAUDE.md, wiki entry).
- Agent-tooling adaptation (a `tea` CLI or scripted equivalent for the `gh issue` workflows).

Explicit non-goals:
- Migrating *issue history* from GitHub (we accept a clean break — link from new issues if needed).
- Migrating PR review history.
- Federating with Codeberg or other Forgejo instances (experimental upstream).
- Forgejo container registry, Pages, or LFS in v1 (enable later if needed).
- Replacing `gh` everywhere — keep it for GitHub-mirror-side ops; introduce `tea` only where Forgejo-side issue access is needed.

### Deferred to Follow-Up Work

- Postgres (via `mk-pg-container`, hostNum=8) — start on SQLite. Migrate later if performance or backup story demands it. Forgejo dump format is engine-agnostic so the door stays open. (separate issue)
- LFS — wire in once we have a repo that actually needs it.
- Forgejo federation — track upstream maturity; revisit when it lands stable.
- Backup integration with Kopia — covered by the existing virtiofs/Kopia path on doc2; no module changes expected. Verify after cutover. (separate issue)

---

## Context & Research

### Relevant Code and Patterns

- `modules/nixos/services/paperless.nix` — canonical service-with-DB pattern (mk-pg-container, restartTriggers, sops env, localProxy + monitoring + nfsWatchdog).
- `modules/nixos/services/uptime-kuma.nix` — service-without-DB pattern with static user, virtiofs `dataDir`, `DynamicUser=mkForce false` to own external storage. Closest shape to a SQLite-backed Forgejo.
- `modules/nixos/services/local_proxy.nix` — the FQDN→nginx→Cloudflare-A pattern; `forge.ablz.au` plugs straight in.
- `modules/nixos/services/monitoring_sync.nix` — declarative monitor + maintenance-window sync into Uptime Kuma.
- `modules/nixos/lib/mk-pg-container.nix` — Postgres-via-nspawn (held in reserve; existing hostNums 1–7, next free is 8).
- `modules/nixos/ci/rolling-flake-update.nix` — nightly `nix flake update && push` on doc1 (`proxmox-vm`) at 22:15 AWST. Push target is implicit (origin) — needs to be repointable.
- `modules/nixos/ci/github-runner.nix` — wraps upstream `services.github-runners.<name>`. Currently `proxmox-bastion` on doc1 against `https://github.com/abl030/nixosconfig`. Forgejo Actions runner has the same shape via `services.gitea-actions-runner` (Forgejo + Gitea share the runner module).
- `modules/nixos/autoupdate/update.nix:235` — `system.autoUpgrade.flake = "github:abl030/nixosconfig#${config.networking.hostName}"`. **The single line that controls every host's rebuild source.** Cutover hinges on this.
- `modules/nixos/homelab/podman.nix` — rootful podman with autoupdate + autoheal, the path Forgejo Actions runner takes if we choose OCI over the upstream module.

### Cutover Surface (every reference to `github:abl030/nixosconfig` or `abl030/nixosconfig`)

- `modules/nixos/autoupdate/update.nix` — `system.autoUpgrade.flake` (every host).
- `modules/nixos/ci/github-runner.nix` — `repoUrl` default; consumed by `hosts/proxmox-vm/configuration.nix`.
- `modules/nixos/ci/rolling-flake-update.nix` — `cfg.repoDir` is local; the script's `git push` target is whatever `origin` resolves to in that working tree.
- `modules/nixos/services/mcp.nix` — possibly references the repo URL (verify in U6).
- `modules/home-manager/services/beets.nix`, `modules/home-manager/shell/aliases.nix` — convenience clones / aliases (cosmetic; update at leisure).
- `CLAUDE.md` — the "NEVER DEPLOY REMOTELY" runbook references `github:abl030/nixosconfig#<hostname>` explicitly. Must update.
- `hosts/proxmox-vm/configuration.nix` — runner repoUrl override.
- `scripts/rolling_flake_update.sh` — verify it's `origin`-relative, not URL-hardcoded.

### Institutional Learnings

- `restartTriggers` foot-gun if Forgejo ever moves to a DB container later: pin `config.systemd.units."container@<svc>-db.service".unit`, **not** `config.containers.<svc>-db.config.system.build.toplevel`. (rules.md, lesson from 2026-04-13 outage.)
- DNS-first networking: never embed `192.168.1.35` in module code — always `forge.ablz.au`. (rules.md.)
- Maintenance windows are defined once on the host that runs Uptime Kuma (doc2) — adding a Forgejo monitor doesn't need a new window.

### External References

- Issue #223 — top-3 comparison and recommendation.
- NixOS Wiki: Forgejo (https://wiki.nixos.org/wiki/Forgejo) — verified in #223 research as current.
- Forgejo docs — repo push-mirror UI (HTTPS+PAT, no SSH push mirror).
- `services.forgejo.*` upstream module — supports `settings`, `database`, `lfs`, `dump`, `secrets` (LoadCredential), `package = forgejo-lts` default on stable channels.

---

## Key Technical Decisions

- **Database: SQLite for v0.** Single user, low write rate, identical NixOS module surface. Postgres via `mk-pg-container` (hostNum=8) is the documented escape hatch and added if/when needed. Keeps the v0 module thin and avoids the restartTriggers/cascade pitfalls until we've actually got the service stable.
- **Storage: `/mnt/virtio/forgejo`** (virtiofs, same convention as every other doc2 service). Subdirs: `data/` (Forgejo's `STATE_DIR` content — repos, attachments, LFS later), `dump/` (nightly dumps emitted by `services.forgejo.dump`).
- **Module shape: wrap upstream `services.forgejo`.** This is preference-1 per rules.md (upstream module > custom > OCI). The upstream module is mature enough that our wrapper is mostly: options, sops wiring, infra wiring, virtiofs paths.
- **FQDN: `forge.ablz.au`** via `homelab.localProxy` — identical pattern to every other LAN-only service on doc2.
- **Secrets via `services.forgejo.secrets`** (LoadCredential): `SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`. These get rotated once and never again. Admin password and the GitHub mirror PAT use the existing sops-dotenv pattern (`config.homelab.secrets.sopsFile`).
- **Push-mirror to GitHub: configured per-repo via the Forgejo API**, not via NixOS. Push-mirror config is repo-state, not host-state — it lives in Forgejo's DB, gets backed up by `services.forgejo.dump`, and would be awkward to encode declaratively. We accept that and document the API call in the module README/wiki.
- **CI runner: `services.gitea-actions-runner` as OCI container on doc1** (preserves the doc1-runs-CI pattern). Forgejo Actions uses the same runner binary as Gitea Actions; the module is shared. Decommission `services.github-runners.proxmox-bastion` *after* the cutover proves out, not during.
- **Rebuild flake URL: phased cutover.** epimetheus first (workstation, can be hand-fixed if it breaks); soak for a week; then doc2/doc1/igpu/dev/wsl/framework/caddy in two batches. The flag lives in `update.nix` as a per-host option override so we can flip individuals without rebuilding the whole fleet.
- **GitHub stays as a hot fallback** for at least 30 days post-cutover. Forgejo push-mirrors to GitHub continuously, so swapping the autoUpgrade URL back is a one-line change with no data loss.
- **Issue migration: clean break.** Existing GitHub issues stay on GitHub (mirror remains read-accessible). New issues open on Forgejo. CLAUDE.md updated to point future agents at `tea` (Forgejo CLI) for issue ops; a thin `gh issue`-compatible wrapper script keeps muscle memory working if needed.

---

## Open Questions

### Resolved During Planning

- **Postgres or SQLite?** SQLite for v0 — see Key Technical Decisions.
- **OCI runner or upstream `services.gitea-actions-runner`?** Upstream module — same code, declarative, fits the module hierarchy preference.
- **Where does the runner live?** doc1, replacing the current GitHub runner role. doc2 already has plenty going on.
- **Does the existing GitHub Actions workflow need rewriting?** It runs on the GitHub side against the GitHub mirror, so during cutover we keep both runners alive. After cutover, we either keep the GitHub-side workflow (running off the mirror) or migrate it. Defer.

### Deferred to Implementation

- **Exact Forgejo `app.ini` settings** beyond defaults (mailer config, default visibility, sign-up policy, allowed repo size limits). Picked when we configure the running instance, not in the module.
- **Whether to enable Forgejo's built-in package registry** for the few private NPM/Docker artefacts we currently shove on tower. Evaluate after v0 lands.
- **Inter-tailnet share via `homelab.tailscaleShare`?** Not needed for v0 (LAN-only is fine for a single-user homelab forge). Add later if we ever want to share a repo with someone outside the tailnet.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification.*

```
┌────────────────────────────────────────────────────────────────────┐
│ doc2 (192.168.1.35)                                                │
│                                                                    │
│  /mnt/virtio/forgejo/data  ← repos, attachments, LFS later         │
│  /mnt/virtio/forgejo/dump  ← nightly services.forgejo.dump         │
│                                                                    │
│  ┌────────────────────────┐    ┌──────────────────────────────┐    │
│  │ services.forgejo       │    │ nginx (homelab.localProxy)   │    │
│  │   port 3030 (HTTP)     │◄───┤ forge.ablz.au :443  ACME     │    │
│  │   port 2222 (SSH git)  │    │ → 127.0.0.1:3030             │    │
│  │   SQLite v0            │    └──────────────────────────────┘    │
│  └─────────┬──────────────┘                                        │
│            │ push-mirror (HTTPS + GH PAT)                          │
└────────────┼───────────────────────────────────────────────────────┘
             ▼
       ┌──────────────────────────┐
       │ github.com/abl030/...    │  ← public-safe subset only
       │ (read-only mirror;       │     hot fallback for autoUpgrade
       │  becomes secondary       │     during 30-day soak)
       │  after cutover)          │
       └──────────────────────────┘

Cutover sequencing (R6):
  Week 0:  Forgejo up. nixosconfig pull-mirrored from GitHub. No host changes.
  Week 1:  epimetheus.system.autoUpgrade.flake → forge.ablz.au. Soak.
  Week 2:  doc2 + doc1 + igpu flip. Soak.
  Week 3:  remaining hosts flip. Invert mirror direction (push GitHub from Forgejo).
  Week 7:  retire GitHub-side runner if Forgejo Actions has carried CI cleanly.

Rollback (any week, any host): revert the autoUpgrade.flake override → GitHub.
```

---

## Output Structure

    modules/nixos/services/
      forgejo.nix              # NEW — wraps services.forgejo

    secrets/hosts/doc2/
      forgejo.env              # NEW — GH_MIRROR_PAT, optional admin pw env
      forgejo-secrets/         # NEW — SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET, LFS_JWT_SECRET (sops dir)
      forgejo-runner-token     # NEW — runner registration token (on doc1, see U5)

    docs/wiki/services/
      forgejo.md               # NEW — operations runbook + push-mirror API recipe + cutover/rollback

    hosts/doc2/configuration.nix       # MODIFY — homelab.services.forgejo.enable = true
    hosts/proxmox-vm/configuration.nix # MODIFY (U5) — gitea-actions-runner config
    modules/nixos/services/default.nix # MODIFY — import forgejo.nix
    modules/nixos/autoupdate/update.nix# MODIFY (U6) — option to override flake URL per-host
    CLAUDE.md                          # MODIFY (U8) — rebuild commands, issue workflow

---

## Implementation Units

- U1. **Forgejo NixOS module skeleton**

**Goal:** Stand up `modules/nixos/services/forgejo.nix` wrapping `services.forgejo` with our standard option/wiring shape. No custom DB, SQLite only, no infra wiring yet.

**Requirements:** R2, R3.

**Dependencies:** None.

**Files:**
- Create: `modules/nixos/services/forgejo.nix`
- Modify: `modules/nixos/services/default.nix` (add to imports)

**Approach:**
- Options: `homelab.services.forgejo.{enable, dataDir, fqdn, httpPort, sshPort}`. Defaults: `dataDir = "/mnt/virtio/forgejo"`, `fqdn = "forge.ablz.au"`, `httpPort = 3030`, `sshPort = 2222`.
- Use `services.forgejo.enable = true` with `package = pkgs.forgejo-lts`.
- `stateDir = "${cfg.dataDir}/data"`; `dump.{enable=true, interval="daily", backupDir="${cfg.dataDir}/dump"}`.
- Database: `services.forgejo.database.type = "sqlite3";`.
- LFS off in v0 (deferred).
- Static `forgejo` user owning `cfg.dataDir` so virtiofs ownership is stable across rebuilds (mirror the uptime-kuma pattern: `DynamicUser = mkForce false; User = "forgejo"; Group = "forgejo"; ReadWritePaths = [cfg.dataDir];`).
- `tmpfiles.rules` to ensure `${cfg.dataDir}/{data,dump}` exist with correct ownership before the unit starts.

**Patterns to follow:**
- `modules/nixos/services/uptime-kuma.nix` (static user + virtiofs + DynamicUser override).
- `modules/nixos/services/paperless.nix` (option shape, `homelab.services.<name>` namespace).

**Test scenarios:**
- Happy path: `nix build .#nixosConfigurations.doc2.config.system.build.toplevel` succeeds with the new module imported but `enable = false` (default-off doesn't break eval).
- Happy path: with `enable = true`, evaluation produces a `forgejo.service` unit with the expected `User=forgejo` and `STATE_DIR=/mnt/virtio/forgejo/data`.
- Edge case: changing `httpPort` propagates to the unit's `app.ini` rendering (verified by checking the rendered config in the store).

**Verification:**
- Module evaluates cleanly with `enable = false` and `enable = true` (without yet enabling on a host).

---

- U2. **Wire infrastructure (proxy, monitoring, secrets)**

**Goal:** Add `homelab.localProxy`, `homelab.monitoring`, `homelab.nfsWatchdog`, and sops secrets to the module so Forgejo plugs into the standard fleet plumbing.

**Requirements:** R1, R4.

**Dependencies:** U1.

**Files:**
- Modify: `modules/nixos/services/forgejo.nix`
- Create: `secrets/hosts/doc2/forgejo.env` (sops, dotenv: `GH_MIRROR_PAT=...`)
- Create: `secrets/hosts/doc2/forgejo-secrets/{SECRET_KEY,INTERNAL_TOKEN,JWT_SECRET,LFS_JWT_SECRET}` (one sops file per secret, raw text)

**Approach:**
- `homelab.localProxy.hosts = [{ host = cfg.fqdn; port = cfg.httpPort; websocket = true; maxBodySize = "1G"; }]` (websocket for live activity feed; 1G for git push over HTTPS).
- `homelab.monitoring.monitors = [{ name = "Forgejo"; url = "https://${cfg.fqdn}/api/healthz"; }]` — Forgejo exposes `/api/healthz`.
- `homelab.nfsWatchdog.forgejo.path = cfg.dataDir;` only if `cfg.dataDir` is on NFS — for virtiofs it's not needed. Make this conditional on a `cfg.dataDirOnNfs` boolean (default `false`).
- Sops:
  - `services.forgejo.secrets.security.SECRET_KEY = config.sops.secrets."forgejo/SECRET_KEY".path;` (and same shape for `INTERNAL_TOKEN`, `JWT_SECRET`, `LFS_JWT_SECRET`). `services.forgejo.secrets` is the LoadCredential pathway — files are not in /nix/store.
  - `sops.secrets."forgejo/env" = { sopsFile = config.homelab.secrets.sopsFile "forgejo.env"; format = "dotenv"; owner = "forgejo"; mode = "0400"; };` for the GitHub mirror PAT (used by U4 manual API calls; not consumed by the service itself).

**Patterns to follow:**
- `modules/nixos/services/paperless.nix` (sops dotenv pattern + monitoring + localProxy).
- `modules/nixos/services/uptime-kuma.nix` (single monitor + websocket localProxy).

**Test scenarios:**
- Happy path: `homelab.localProxy.hosts` materializes a `forge.ablz.au` nginx vhost with ACME cert and `proxy_pass http://127.0.0.1:3030`.
- Happy path: `monitoring_sync` picks up the new monitor and posts it to Uptime Kuma on next deploy.
- Edge case: missing sops secret file produces a clear error at activation time, not at runtime.

**Verification:**
- `nix build .#nixosConfigurations.doc2.config.system.build.toplevel` still succeeds.
- `nginx -t` (in the built closure) accepts the new vhost.

---

- U3. **Enable on doc2 + first-run admin bootstrap**

**Goal:** Deploy v0 to doc2, create the admin user, confirm the UI loads at `https://forge.ablz.au` with a valid cert.

**Requirements:** R1, R2, R3.

**Dependencies:** U1, U2.

**Files:**
- Modify: `hosts/doc2/configuration.nix` (add `homelab.services.forgejo.enable = true;`)
- Create: `secrets/hosts/doc2/forgejo-admin-password` (sops binary file, used once)

**Approach:**
- Generate the four `forgejo-secrets/*` values (32-byte random hex; rotated only manually thereafter — they are not key material, just app secrets).
- Encrypt all secrets with sops using the doc2 host key (per `secrets/.sops.yaml`).
- Per the deploy runbook in CLAUDE.md: `git push`, then `ssh doc2 "sudo nixos-rebuild switch --flake github:abl030/nixosconfig#doc2 --refresh"`.
- First-run admin: use `services.forgejo.cliCmd` / `forgejo admin user create` via a one-shot `systemd.services.forgejo-create-admin` activation that reads the admin password file and runs only when no admin exists. Alternative: do it manually once, document in wiki — simpler, lower-blast-radius. Pick the manual approach for v0.

**Patterns to follow:**
- Service-deploy skill / CLAUDE.md remote rebuild runbook.

**Test scenarios:**
- Integration: `https://forge.ablz.au` loads the Forgejo signup page over TLS with no cert warnings.
- Integration: `curl -fsS https://forge.ablz.au/api/healthz` returns 200 within 60s of unit start.
- Integration: Uptime Kuma shows the Forgejo monitor as UP after the next sync.
- Edge case: stop the service and confirm the monitor goes DOWN within `maxretries × interval` (~10 min) — sanity-check the alert path.

**Verification:**
- Admin login at `https://forge.ablz.au/user/login` succeeds; user namespace `abl030` exists.

---

- U4. **Pull-mirror nixosconfig from GitHub (validation phase)**

**Goal:** Mirror `github.com/abl030/nixosconfig` into Forgejo as `abl030/nixosconfig` with continuous pull-mirror, so the Forgejo URL serves the identical content while we leave GitHub as the source of truth.

**Requirements:** R5.

**Dependencies:** U3.

**Files:** None — Forgejo repo-level setting, lives in the Forgejo DB and its dump.

**Approach:**
- Create the `abl030/nixosconfig` repo on Forgejo via the API (or UI), with "Mirror from URL" set to `https://github.com/abl030/nixosconfig.git` and a 10-minute pull interval.
- Add a few smaller private repos as native (non-mirror) repos to validate the workflow shape: an agent-definitions repo lives only here from day one.
- Document the API recipe in `docs/wiki/services/forgejo.md` (Curl-based `POST /api/v1/repos/migrate`, with the GH PAT loaded from `secrets/hosts/doc2/forgejo.env`).

**Test scenarios:**
- Integration: `git clone https://forge.ablz.au/abl030/nixosconfig.git /tmp/clonetest` succeeds and `git log -1` matches the GitHub HEAD within the mirror interval.
- Integration: Push to GitHub from a workstation; within 10 min, the Forgejo mirror sees the new commit.

**Verification:**
- `nix flake metadata git+https://forge.ablz.au/abl030/nixosconfig` succeeds and reports the same `lastModified` and `revCount` as the GitHub source.

---

- U5. **Forgejo Actions runner on doc1**

**Goal:** Stand up a Forgejo Actions runner on doc1 (alongside the existing GitHub runner during cutover) so we have CI on the Forgejo side before retiring the GitHub workflows.

**Requirements:** R7.

**Dependencies:** U3.

**Files:**
- Create: `modules/nixos/ci/forgejo-runner.nix` (mirror the shape of `github-runner.nix`, but wraps `services.gitea-actions-runner` since the runner module is shared).
- Modify: `hosts/proxmox-vm/configuration.nix` (enable the new runner alongside the old one).
- Create: `secrets/hosts/proxmox-vm/forgejo-runner-token` (sops binary; one-time registration token from Forgejo admin → Runners).

**Approach:**
- Use upstream `services.gitea-actions-runner` with `instances.forgejo.url = "https://forge.ablz.au"`, `tokenFile = config.sops.secrets."forgejo-runner/token".path`, `name = "doc1-forgejo"`, `labels = ["nix" "doc1"]`.
- Run alongside the GitHub Actions runner — no conflict, different unit names.
- One sample workflow file checked in so we can prove the runner picks up jobs end-to-end (e.g. `nix flake check`).

**Patterns to follow:**
- `modules/nixos/ci/github-runner.nix` (option shape, group-trust pattern, `nix.settings.trusted-users`).

**Test scenarios:**
- Integration: After deploy, the runner shows up as Online in Forgejo admin → Runners.
- Integration: A push that triggers a workflow on the Forgejo side completes successfully (end-to-end runner registration + job execution + artifact retrieval).

**Verification:**
- One Forgejo Actions workflow run succeeds.

---

- U6. **Phased flake-URL cutover**

**Goal:** Switch `system.autoUpgrade.flake` from GitHub to Forgejo, one host at a time, with a documented one-line rollback. Stop short of removing the GitHub URL entirely.

**Requirements:** R6.

**Dependencies:** U4.

**Files:**
- Modify: `modules/nixos/autoupdate/update.nix` — extract the hardcoded `github:abl030/nixosconfig` into `homelab.update.flakeRef` (option, default `"git+https://forge.ablz.au/abl030/nixosconfig"` *after* the cutover phase finishes; default stays GitHub during the cutover, with per-host overrides flipping individuals).
- Modify: `modules/nixos/services/mcp.nix` — verify and update if it references the repo URL.
- Modify: `modules/home-manager/services/beets.nix`, `modules/home-manager/shell/aliases.nix` — update clone URLs / aliases.
- Modify: `hosts/<host>/configuration.nix` — set `homelab.update.flakeRef` per host as we flip them.
- Verify: `scripts/rolling_flake_update.sh` is `git push origin`-relative (does not hardcode a URL); update doc1's repo `origin` to `forge.ablz.au` once we trust the path.

**Approach:**
- Convert `update.nix:235` from a hardcoded string to an option:
  ```
  options.homelab.update.flakeRef = mkOption {
    type = types.str;
    default = "github:abl030/nixosconfig";
    description = "Flake reference autoUpgrade rebuilds from. Override per-host during cutover.";
  };
  config.system.autoUpgrade.flake = "${cfg.flakeRef}#${config.networking.hostName}";
  ```
- Phase 1 (Week 1): set `homelab.update.flakeRef = "git+https://forge.ablz.au/abl030/nixosconfig"` on **epimetheus only**. Watch the next two nightly auto-updates. If they succeed and the system activates correctly, proceed.
- Phase 2 (Week 2): doc2, doc1 (`proxmox-vm`), igpu. doc2 is special because Forgejo runs on it — the failure mode is that doc2 can't fetch its own flake if Forgejo is down. Mitigation: the autoUpgrade unit fails cleanly and the *current* system keeps running; CLAUDE.md gets a "if doc2 won't rebuild, flip the URL back" note.
- Phase 3 (Week 3): wsl, framework, dev, caddy. Then change the *default* in `update.nix` to the Forgejo URL and remove the per-host overrides.
- Phase 4 (Week 3 also): repoint `origin` in `/home/abl030/nixosconfig` on doc1 to Forgejo, so `rolling-flake-update` pushes there. Configure Forgejo→GitHub push mirror on the `nixosconfig` repo so the public mirror stays current without another systemd job.

**Execution note:** Land the `flakeRef` option (and its GitHub default) in one PR. Ship it — verify nothing broke. Flip hosts one PR per phase so each phase is its own bisectable revert.

**Patterns to follow:**
- Existing `homelab.update.*` option pattern in `modules/nixos/autoupdate/update.nix`.

**Test scenarios:**
- Happy path: `nixos-rebuild build --flake git+https://forge.ablz.au/abl030/nixosconfig#epimetheus` produces a closure identical to the GitHub-sourced build (compare with `nvd diff`).
- Happy path: nightly autoUpgrade on the flipped host completes successfully two nights running.
- Error path: simulate Forgejo down (stop the unit on doc2); `nixos-upgrade.service` on a flipped host fails cleanly with a clear nix fetch error and the system continues running on the prior generation.
- Edge case: doc2 itself with its own Forgejo down — same as above; documented manual recovery: flip `homelab.update.flakeRef` back to GitHub on doc2 only, rebuild from current laptop session.

**Verification:**
- All eight hosts have flipped, the GitHub URL is gone from `update.nix`'s default, and 7 consecutive nights of autoUpgrade across the fleet show no flake-fetch failures.

---

- U7. **Invert the mirror direction (Forgejo → GitHub)**

**Goal:** Once the fleet rebuilds reliably from Forgejo, switch `nixosconfig` to push-mirror from Forgejo to GitHub so the GitHub mirror stays current as a fallback without us having to think about it.

**Requirements:** R5.

**Dependencies:** U6 (must be fully landed and soaked).

**Files:** None — Forgejo repo settings + Forgejo dump.

**Approach:**
- Disable the Forgejo pull-mirror on `nixosconfig`.
- Add a push-mirror to `https://github.com/abl030/nixosconfig.git` using a fine-scoped GH PAT (the same secret already in `forgejo.env`), 10-minute push interval.
- On doc1, repoint the `origin` remote in the working tree to `forge.ablz.au` (one-time `git remote set-url origin ...`). `rolling-flake-update`'s `git push` now lands on Forgejo, which mirrors out to GitHub on its own cadence.

**Test scenarios:**
- Integration: a commit pushed to Forgejo from doc1 appears on `github.com/abl030/nixosconfig` within 15 minutes.
- Integration: `rolling-flake-update.service` succeeds end-to-end on its next 22:15 firing.

**Verification:**
- `git ls-remote git+https://forge.ablz.au/abl030/nixosconfig HEAD` and `git ls-remote https://github.com/abl030/nixosconfig HEAD` show the same SHA after a pushed commit.

---

- U8. **Move agent definitions, update CLAUDE.md, add `tea` for issues**

**Goal:** Migrate private agent-definition repos and the issue-tracking workflow to Forgejo. Update agent-facing docs so future sessions reach for the right forge.

**Requirements:** R8, R9.

**Files:**
- Modify: `CLAUDE.md` — replace `nixos-rebuild` runbook URLs with Forgejo, update "Issue Tracking" section to reference both `gh` (GitHub mirror) and `tea` (Forgejo native), update "Landing the Plane" push instructions.
- Modify: `modules/home-manager/shell/aliases.nix` — add `tea` aliases mirroring the `gh issue` workflow.
- Add: `tea` to `home.packages` for `abl030@*` (or wherever the existing CLI stack lives).
- Create: `docs/wiki/services/forgejo.md` — operations runbook (push-mirror API recipe, runner registration, dump/restore, rollback procedure for U6).
- Create: an `agents` repo on Forgejo (private, no GitHub mirror); copy `.claude/agents/*` into it as the source of truth going forward — or leave them in `nixosconfig` and accept that "private agents" means "not in the publicly-mirrored subset" via repo-level `.gitignore` patterns. **Decision:** keep them in `nixosconfig` for now (they need to be deployed alongside the host), but mark `nixosconfig` as private on Forgejo and put public-safe carve-outs in the GitHub mirror via a `mirror-public.yaml` Forgejo Actions job that pushes a filtered branch. **Or** simpler: stop mirroring `nixosconfig` to GitHub entirely once we've done U7's verification of the rollback path. Decide post-U7.

**Approach:**
- This unit is mostly docs and a small CLI install. The repo-organization decision (carve out vs. private-everything) happens at the end once we've felt the pain of the alternatives.

**Test scenarios:**
- Happy path: a fresh agent session, given only CLAUDE.md, attempts a rebuild and uses the Forgejo URL.
- Happy path: `tea issues create --title "test" --repo abl030/nixosconfig` succeeds against Forgejo.

**Verification:**
- CLAUDE.md no longer references `github:abl030/nixosconfig` as a default flake URL (only as a documented fallback).

---

## System-Wide Impact

- **Interaction graph:** every host's `nixos-upgrade.service` reaches the new flake URL nightly; the doc1 `rolling-flake-update.service` pushes to it; the new Forgejo Actions runner pulls jobs from it; CLAUDE.md-driven agents read/write issues against it. Forgejo itself runs *on* the host that hosts most other services (doc2), so a Forgejo outage does not cascade — but a doc2 outage takes Forgejo with it.
- **Error propagation:** Forgejo down → autoUpgrade fails on each host → current generation keeps running → Uptime Kuma pages within ~10 min → manual rollback by flipping `homelab.update.flakeRef` per host (or fleet-wide) back to GitHub. No data loss in any failure mode because the GitHub mirror is hot.
- **State lifecycle risks:** Forgejo's repo + issue + PR state lives in `/mnt/virtio/forgejo/data` (virtiofs). `services.forgejo.dump` writes nightly tarballs to `/mnt/virtio/forgejo/dump`, picked up by Kopia. Verify Kopia is actually backing this path post-cutover (separate issue).
- **API surface parity:** `gh` keeps working against the GitHub mirror; `tea` is the new tool for native Forgejo ops. Agent skills that use `gh issue *` need updating in U8.
- **Integration coverage:** the cutover phases in U6 are themselves integration tests — each phase intentionally lands a small change so a regression is bisectable to a single host.
- **Unchanged invariants:** the rebuild *protocol* per CLAUDE.md (git push → ssh remote nixos-rebuild from the GitHub-style URL with `--refresh`) doesn't change, only the URL. The localProxy / monitoring / sops contracts don't change.

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| Forgejo down → fleet can't auto-rebuild | GitHub mirror stays hot for 30+ days post-cutover; per-host `homelab.update.flakeRef` override is a one-line revert; rollback runbook in `docs/wiki/services/forgejo.md`. |
| doc2 specifically can't rebuild itself when its own Forgejo is down | Same mitigation; CLAUDE.md gains a "doc2 emergency rebuild" note pointing to the GitHub URL fallback. |
| sops secret rotation footgun for `services.forgejo.secrets.security.SECRET_KEY` | Generated once, never rotated; documented in the wiki. Forgejo rejects reading existing data with a different SECRET_KEY → loud, not silent. |
| Push-mirror PAT leak | Fine-scoped PAT (single repo, push-only, no admin); rotate on any suspicion; sops-encrypted, never on disk in plaintext. |
| `nix flake metadata` over `git+https://` is slower than `github:` (no API, just `git ls-remote`) | Acceptable — adds <2s to autoUpgrade. If it ever matters, run a local nix-binary cache (cache.ablz.au already exists). |
| Forgejo upstream rename / breaking change | LTS package (`pkgs.forgejo-lts`) is the default in stable channels — gives a long upgrade runway. Minor releases land via nightly autoUpgrade; major upgrades batched manually. |
| Loss of GitHub issue history during agent context swap | Accepted — clean break per Scope Boundaries. GitHub issues remain readable on the mirror; new work tracks in Forgejo. |

---

## Documentation / Operational Notes

- New wiki page: `docs/wiki/services/forgejo.md` — first version lands in U3 with operations basics, expands in U6 with cutover/rollback runbook and in U8 with `tea` usage.
- CLAUDE.md updates touch: rebuild runbook (top-of-file CRITICAL block), "Issue Tracking with GitHub Issues" → "Issue Tracking" with both forges noted, "Landing the Plane" push step, AI Tool Integration section.
- Module-level comment pointers from `modules/nixos/services/forgejo.nix` and `modules/nixos/autoupdate/update.nix` to the wiki page.
- Single `gh issue` → cutover communication: open a parent epic-style issue on **both** GitHub and Forgejo describing the move, so future searches from either side land on it.

---

## Sources & References

- **Origin issue:** https://github.com/abl030/nixosconfig/issues/223
- **Module rules:** `.claude/rules/nixos-service-modules.md`
- **CLAUDE.md** (rebuild runbook, fleet overview, issue tracking sections)
- **Reference modules:** `modules/nixos/services/{paperless.nix,uptime-kuma.nix,local_proxy.nix}`, `modules/nixos/ci/{github-runner.nix,rolling-flake-update.nix}`, `modules/nixos/autoupdate/update.nix`
- **NixOS Wiki: Forgejo** — https://wiki.nixos.org/wiki/Forgejo
- **Forgejo docs: Repo mirror** — https://forgejo.org/docs/latest/user/repo-mirror/
