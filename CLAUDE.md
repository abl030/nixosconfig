# NixOS Configuration Agent Guide

This file is the shared project instruction source for Claude Code and Codex.
`AGENTS.md` must remain a symlink to it. Keep this guide concise; put procedures
in skills and put rationale or changing operational knowledge in `docs/wiki/`.

## Session Start

Before doing anything else, silently run `hostname` and `date`. Then read
`.claude/memory/MEMORY.md` unless the client already injected it. This establishes
the current machine, time, and shared cross-agent memory.

Before any `nixos-rebuild switch`, run `hostname` again and use the actual host in
`--flake .#<actual-hostname>`. Never assume or hardcode the rebuild target.

## Non-Negotiable Safety

### Source, Signing, and Deployment

- Forgejo (`git.ablz.au/abl030/nixosconfig`) is the write and verified-deploy
  root. GitHub is a read-only mirror/fallback; never push to it or deploy its
  `github:` flake in normal operations.
- Fleet deployment accepts only commits descending from the running revision and
  SSH-signed by a key trusted in `hosts.nix`. Verify a new commit with
  `git log -1 --format=%G?` and require `G` before pushing.
- Never use `--target-host`. It moves local/uncommitted state over SSH and bypasses
  the verified local-build path.
- From doc1, deploy a full NixOS sibling with `fleet-deploy <host>`; it starts the
  remote verified update asynchronously through a forced-command key. Verify the
  resulting revision, freshness, and service health afterward.
- Deploy doc1 locally with `sudo fleet-update`.
- Do not deploy roaming workstations `epimetheus` or `framework`; their owner
  deploys interactively or they use the nightly update.
- Local-tree rebuilds are break-glass only. First fetch Forgejo and confirm the
  checkout is not behind origin; an old checkout downgrades the fleet and misses
  the warm cache.
- Full deployment model and recovery commands:
  `docs/wiki/infrastructure/fleet-deploy-and-sibling-lockdown.md` and
  `docs/wiki/infrastructure/signed-fleet-deploys.md`.

On doc1, Forgejo push authentication uses the `abl030`-owned 0400 nixbot token as an
HTTP header, never in argv or the remote URL:

```bash
export GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0="http.https://git.ablz.au.extraHeader" \
  GIT_CONFIG_VALUE_0="Authorization: token $(cat /run/secrets/forgejo/nixbot-token)"
git push origin HEAD:master
```

Dev boxes (`epimetheus`, `framework`) intentionally hold no Forgejo push token.
Never install one to fix a failed push. Land their work from doc1 with the
`relay-push` skill, which fetches over SSH, verifies signatures, rebases, presents
each diff for human review, and pushes only after the user says `go`. See
`docs/wiki/infrastructure/dev-box-gated-push.md`.

### Host Privilege Model

- `homelab.fleetDeploy.role` defaults to `locked`; doc1 is the only `bastion`.
- Locked-role defaults have passworded sudo plus a narrow read-only/container
  recovery allowlist. `fleetBastionRoleCheck` enforces exactly one bastion.
- doc2 and servarr deliberately override the locked-role default with full
  passwordless sudo for `abl030`. igpu and wsl remain narrowly locked. Read the
  target host config before assuming its sudo posture.
- Do not grant a second bastion role. A host-specific exception uses an explicit
  `security.sudo.extraRules = lib.mkAfter [...]` override with documented blast
  radius and rollback.

### WSL

When `hostname` is `wsl`, never run `nix build` for another host. It downloads a
large unused closure over a slow link. Use eval-only `nix flake check`, or push
and let the target host build through the verified deploy path. WSL break-glass
root is `wsl -u root` from Windows, not remote passwordless sudo.

### Least Privilege

Audit every touched module, script, config, and deployment step against both an
external probe and post-compromise lateral movement. Explicitly review auth,
secrets, image trust, network exposure, file ownership, shared resources, and
root command surfaces. Bound the blast radius of a single failure. The canonical
patterns and checklist are in `docs/wiki/nixos-service-modules.md`; outstanding
fleet work is tracked in Forgejo issue #232.

## Working Style

- Compound Engineering skills are explicit-invocation only. Do not load, invoke,
  or route to `ce-*`, `compound-engineering:*`, or `lfg` because a description
  happens to match. Handle ordinary planning, implementation, debugging, review,
  brainstorming, commits, and PR work with the native agent. Use CE only when the
  user explicitly names or invokes it.
- Do not use structured question UI. Ask in plain chat. When several decisions
  are needed, ask one at a time unless they are tiny and tightly coupled.
- Complete every related item in the requested scope. Do not manufacture sibling
  issues to defer awkward work; name a genuine blocker on the original issue.
- For a real data or service migration, perform the migration in-session unless
  the user explicitly asks for staging. Use preflight checks, backups,
  verification, and a rollback command rather than permanent deferral machinery.
- If asked, send a Gotify ping before requesting human input.

## Repository Architecture

This flake manages NixOS and Home Manager for the homelab. `hosts.nix` is the
single source of truth for host identity, SSH trust, and commit-signing trust.

- `nix/lib.nix`: `mkNixosSystem` and `mkHomeConfiguration` factories.
- `hosts/<name>/`: host-specific NixOS and Home Manager configuration.
- `modules/nixos/profiles/base.nix`: fleet-wide NixOS baseline.
- `modules/nixos/services/`: service modules under `homelab.*`.
- `modules/home-manager/`: shared user environment.
- `modules/nixos/lib/mk-pg-container.nix`: isolated per-service PostgreSQL.
- `modules/nixos/services/tailscale-share.nix`: scoped cross-tailnet sharing.

Prefer the established hierarchy: upstream NixOS module, then a custom module,
then an OCI container only when necessary. Remaining OCI services use
`virtualisation.oci-containers` plus `homelab.podman` isolation, auto-update, and
autoheal. The retired rootless compose model is documented in
`docs/wiki/services/retired-container-stacks.md`.

## Secrets

Secrets use sops-nix with Age. A secret in `secrets/hosts/<host>/` must be
decryptable only by that host plus the editor and cold break-glass recipients.
Shared secrets require an explicit multi-host rule; the fallback deploys nowhere.
Run `sops updatekeys` from inside `secrets/` so `.sops.yaml` is discovered.
`sopsRecipientScopeCheck` enforces the model. See
`docs/wiki/infrastructure/sops-break-glass-recovery.md`.

## Shared AI Surfaces

One authored source exists for each concept; client-specific formats are adapters:

- Instructions: `CLAUDE.md`; `AGENTS.md` is its symlink.
- Skills: `.claude/skills/`; `.agents/skills` is the Codex discovery symlink.
- Specialist agents: `.claude/agents/*.md`; `.codex/agents/*.toml` is generated.
- Project MCP: `.mcp.json`; `.codex/config.toml` is generated.
- Durable learning: `.claude/memory/`, `docs/wiki/`, and Forgejo issues.

After editing an agent or `.mcp.json`, run:

```bash
python3 scripts/generate-ai-adapters.py
python3 scripts/generate-ai-adapters.py --check
```

Never edit generated `.codex/agents/*.toml` or `.codex/config.toml` directly.
Author skills in the common `SKILL.md` format and keep platform-specific tool
names out of workflows where a normal shell/read/edit instruction suffices.

Claude auto-memory and Codex native memory are client-local recall caches, not
project truth. Promote durable discoveries to the shared Markdown/wiki/issue
surfaces. Keep `.claude/memory/MEMORY.md` at 15 lines or fewer as an index; do not
duplicate rationale there. Codex native memory is enabled as personal local
recall, with tasks that used external MCP/web/tool-search context excluded from
generation; it never replaces the shared surfaces.

### Specialist Agents and MCP

The generated Codex agents mirror the Claude agent bodies and scoped MCP servers.
Use the matching specialist for pfSense, UniFi, Home Assistant, mail search,
Audiobookshelf, browser testing, tower, and the arr stack. Control credentials for
pfSense, UniFi, Home Assistant, and mail search exist only on doc1 under
`/run/secrets/mcp/`; do not widen them fleet-wide. Live state overrides snapshots
in agent documentation, and an agent that changes infrastructure must update its
source definition when the snapshot changes.

`mcp-nixos` provides current package and option data. Use it rather than guessing
renamed options or package availability.

## Knowledge and Issue Tracking

- Active issues live on Forgejo. GitHub issues and `docs/beads-archive.md` are
  historical only; do not use `gh issue` for this repository.
- Use the Forgejo REST API for issue reads/writes. The doc1-only scoped issue token
  is documented in `.claude/memory/forgejo-issue-token-doc1.md`.
- Lightweight TODOs live in `docs/todo/`.
- `docs/wiki/` is the long-form knowledge base written by agents for agents.
  Update it as research or operational understanding changes. Include date,
  status, issue links, what was tried, what works, and when to revisit.
- Add short code comments pointing to relevant wiki pages where future agents
  need the rationale. Do not duplicate the full explanation in code or memory.
- External service agents should start with `docs/wiki/agent-operations.md`.

## Fleet Orientation

The eight Nix-managed hosts in `hosts.nix` are `epimetheus`, `framework`, `wsl`,
`proxmox-vm` (doc1), `doc2`, `igpu`, `servarr`, and `caddy`. `prom` is the Proxmox
hypervisor and `tower` is Unraid; neither is a NixOS flake host.

- doc1 is the bastion, Forgejo writer, binary cache, and control-plane host.
- doc2 hosts most services and the LGTM stack. It is dual-homed on
  `192.168.1.35` and `.36`; outbound LAN traffic may use `.36`.
- igpu is the media-transcoding LXC.
- servarr hosts the arr applications; qBittorrent is isolated separately.
- caddy is the legacy appliance-edge reverse proxy.
- tower is managed through the `tower` agent over native key-only SSH from doc1.
- pfSense is bare metal at `192.168.1.1` and tailnet address `100.123.61.111`.
  It is the fleet DNS resolver; ntopng also runs there, not on doc2.

Logs, metrics, and traces live on doc2. Query Loki at
`https://loki.ablz.au/loki/api/v1/query_range`; use RFC3339 or nanosecond times.
Important host labels include `doc2`, `igpu`, `proxmox-vm`, `framework`,
`epimetheus`, `wsl`, `tower`, `pfsense`, and `prom`. Container logs use the
`container` label. The old `loki-mcp` is retired; use HTTP or Grafana Explore.
See `docs/wiki/services/lgtm-stack.md`.

Network troubleshooting starts from observed topology. In particular, when a
public destination works globally but not from the LAN, test from pfSense before
blaming the ISP; pfBlockerNG has previously blocked CDN anycast addresses. DNS
architecture and incident notes live under `docs/wiki/infrastructure/`.

## Coding and Validation

- Format Nix with Alejandra; use `nix fmt` or the repo formatter.
- Run deadnix and statix for touched Nix code.
- Address shellcheck findings for shell scripts.
- Avoid import-order dependencies; use `lib.mkOrder` where list order matters.
- Isolate generated assets/config sources with `builtins.path` or
  `writeTextFile` to avoid unrelated flake-source churn.
- Validation is primarily `nix flake check`. The known upstream
  `proxmox.qemuConf.diskSize` rename warning is safe to ignore.
- Before changing nginx or Cloudflare behavior, verify upstream with `--resolve`.
- Standard Kuma health conventions are documented in
  `modules/nixos/services/uptime-kuma.nix` and service modules.

Two common Nix failures:

- `failed to insert entry: invalid object specified`: clear `~/.cache/nix/` and retry.
- A locked input path registered in the store but missing on disk: run
  `sudo NIX_REMOTE= nix-store --verify --repair`, then `sudo fleet-update`.
  `fleet-update` also performs this self-heal on retry.

## Completion

Use Conventional Commit subjects such as `fix(pve): ...`. Commit only explicit
pathspecs so unrelated staged work is never swept in, and verify the resulting
commit diff. When work is committed, push it to Forgejo; do not leave local
commits stranded. Include operational impact and deployment notes in PR text.
