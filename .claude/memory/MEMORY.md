# Memory

## Shell Environment Quirk
- zoxide hook (`__zoxide_z`) causes `cd` commands to fail with exit 127 in Bash tool
- Workaround: use `git -C /path/to/repo` instead of `cd /path && git`
- Tree often has pre-staged WIP; bare `git commit` sweeps the whole index. Commit
  by pathspec (`git commit <file>`) + verify `git show --stat HEAD` before push:
  [feedback-commit-pathspec-staged-wip.md](feedback-commit-pathspec-staged-wip.md)

## Critical "Never Do" Rules
- NEVER run `npm install` manually in a Nix-managed Claude Code installation (breaks the store irreparably)
- NEVER flush pfSense firewall states after rule changes — see [feedback_pfsense_no_state_flush.md](feedback_pfsense_no_state_flush.md)
- Source of truth is FORGEJO (`git.ablz.au/abl030/nixosconfig`); push dev commits
  there (origin repointed on doc1). GitHub is a FROZEN ancestor-only fallback —
  NEVER deploy from `github:abl030/nixosconfig` (stale) and never `git push` to it.
  Push from doc1 needs the nixbot token header: [forgejo-push-from-doc1.md](forgejo-push-from-doc1.md).
- DEV BOXES (epi, framework) HOLD NO PUSH TOKEN by design — doc1 is the sole
  writer. A token on a dev box = one popped box → signed, auto-deployed FLEET
  takeover (signing is on the same box, so it's no defence). To land a dev box's
  commits: on doc1 run the **relay-push** skill (SSH-fetch → verify sigs → rebase →
  security-review → push only on "go"). Do NOT install a token on a "can't push"
  dev box. wsl is a grandfathered token exception (USB FIDO can't enter WSL).
  Endgame = carried FIDO key, touch-per-push. Full model:
  `docs/wiki/infrastructure/dev-box-gated-push.md`. (wsl's old extraHeader stance:
  [feedback-devbox-forgejo-creds.md](feedback-devbox-forgejo-creds.md).)
- File/edit Forgejo ISSUES from doc1 via a scoped nixbot `write:issue` token,
  sops-encrypted doc1-only: [forgejo-issue-token-doc1.md](forgejo-issue-token-doc1.md).
- NEVER pin container images / never add a `:latest` CI gate — auto-updates on
  everything is a hard user line. Harden runtime instead. [feedback-no-image-pinning.md](feedback-no-image-pinning.md).
- NEVER push an UNSIGNED commit to master — signed deploys are ENFORCED fleet-wide
  (#235, 2026-06-10). An unsigned/unverifiable commit in a host's deploy range
  loud-fails its nightly `nixos-upgrade`. Commits must be SSH-signed by a key in
  `hosts.nix`; dev machines sign by default. Full model:
  `docs/wiki/infrastructure/signed-fleet-deploys.md`.

## Fleet SSH topology (#270, 2026-06-08) + sibling lockdown (forgejo#2, 2026-06-19)
- doc1 is the SSH **bastion** — ONLY host holding the fleet key; all siblings keyless.
- sibling→sibling SSH is DENIED by design; reach siblings via doc1 (stepping-stone).
- **ONE knob: `homelab.fleetDeploy.role` ("locked"|"bastion", default "locked").**
  doc1 = the only "bastion" (passwordless + deploy key + `fleet-deploy` wrapper +
  diag tools). EVERY other host = "locked": NO passwordless sudo, GTFOBins gated
  off, accepts the deploy trigger. The old sudoPasswordless / acceptTrigger /
  siblingLockdown / bastion knobs are GONE (folded in). `fleetBastionRoleCheck`
  asserts exactly one "bastion". (refactor 2026-06-19, commits d8c182b3+f3116d05.)
- **Deploy LOCKED siblings (doc2, igpu, hermes, wsl) from doc1 with
  `fleet-deploy <host>`** (forced-command → nixos-upgrade, polkit). `ssh <host>
  "sudo fleet-update"` FAILS on ALL of them now — nothing is passwordless except
  doc1 (which uses local `sudo fleet-update`). wsl is a fleet-deploy target too
  (reached at the Windows port-forward; needed a widened triggerFrom for the WSL
  bridge `172.16/12`); break-glass `wsl -u root`. hermes break-glass = prom console.
  epi + framework are LOCKED workstations — the agent does NOT deploy them (roam/
  off); owner deploys interactively / via nightly.
- On doc2/igpu only these sudo work: read-only `podman` (ps/inspect/logs/top/…),
  `systemctl stop nixos-rebuild-switch-to-configuration.service`, `systemctl
  restart podman-*`. NO `sudo journalctl/cat/rm/systemctl-restart-other` — use
  **Loki** for logs. doc2 abl030 has NO password (console = break-glass).
- Full models: `ssh-bastion-model.md` + `fleet-deploy-and-sibling-lockdown.md`.
- **tower (Unraid) joined the fleet SSH model 2026-06-22**: native OpenSSH, key-only root,
  fleet key from doc1 (`ssh root@tower`); Tailscale plugin `--ssh` DISABLED. The old
  "tower = Tailscale SSH / gated" assumption is STALE. Config lives on the Unraid flash (not
  Nix). [tower-unraid-fleet-ssh.md](tower-unraid-fleet-ssh.md).

## Secrets model (#234, 2026-06-08)
- Per-host sops scoping + cold break-glass (Bitwarden+paper) + warm doc1 editor key;
  "master" recipient retired (it was the fleet SSH key in age form). Re-key with
  `sops updatekeys` from **inside `secrets/`**. See [sops-recipient-model.md](sops-recipient-model.md).

## Key Decisions
- ⚠️ Dad's raspberrypi (Pi Zero W, dad's house, tailnet-only access) is **MID
  bullseye→bookworm upgrade & currently OFF the tailnet** (2026-06-21, likely OOM'd
  tailscaled). Resume steps + access/breakglass model:
  [raspberrypi-dad-pizero.md](../../docs/wiki/infrastructure/raspberrypi-dad-pizero.md).
- Tailscale ACL (#239): **FLIPPED to default-deny 2026-06-21** — 5-tag `grants` policy live
  (server/client/share/edge/cullen), all nodes tagged, allow-all removed. Apply/revert via
  gitops-pusher on doc1. See [tailscale-acl-state.md](tailscale-acl-state.md).
- Plex CONTAINED 2026-06-24 (#277): moved off tower `--net=host` onto its own **VLAN 30
  MEDIA_DMZ** (`192.168.30.2`), pfSense default-denies it to all RFC1918, WAN egress only,
  WAN:11338 Oceania-gated; media RO, hardened, autoupdate intact. Casting preserved. Caddy
  `plex.ablz.au`→`.30.2`. [plex-media-dmz-containment.md](plex-media-dmz-containment.md).
- SendMessage (resume a spawned subagent w/ context) WORKS in claude-code 2.1.x;
  gated by `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, which `base.nix:82` deliberately
  strips. Verified 2026-06-21: [claude-code-sendmessage-agent-teams.md](claude-code-sendmessage-agent-teams.md)
- Hermes agent → **full-operator** build (TUI=full prod creds via ssh-agent fwd, Telegram=read-only by construction). See [hermes-full-operator-posture.md](hermes-full-operator-posture.md).
- Operational/infra automation → write a Claude Code SKILL that discovers live
  state (`qm list`, etc.), NOT a hardcoded script (VMIDs/MACs/PCI drift → stale in
  a day). [feedback-skill-over-script-ops.md](feedback-skill-over-script-ops.md)
- Apollo gaming VMs: clone template `WindowsGamingTemplate` (one per game, single
  GPU = one runs at a time, shared MAC `BC:24:11:5E:E5:00`→.111 carries pfSense
  VPN/isolation). Skill: `gaming-vm`; doc: `docs/wiki/services/apollo-gaming-vm.md`.
  ⚠️ WIP 2026-06-25: Windows-MCP GUI-automation + VB-CABLE installed on VM 120;
  audio crackle fix UNCONFIRMED (deploy rtprio + ear-test next); plan to rebuild a
  fresh template with both baked. Resume: [gaming-vm-mcp-audio-wip.md](gaming-vm-mcp-audio-wip.md).
- Custom Claude Code HM module stays over official `programs.claude-code`
- Episodic-memory plugin disabled (npm-install breaks the Nix store)
- Heavy MCPs (pfsense, unifi, HA) moved to subagent-only in .claude/agents/ to reduce context bloat
- Task tracking: NEW issues → Forgejo (`git.ablz.au`, REST API; doc1 agent has a scoped
  write:issue token — see [forgejo-issue-token-doc1.md](forgejo-issue-token-doc1.md)). Legacy
  issues still on GitHub (`gh`), NOT migrated. (beads removed 2026-04-14 — see `docs/beads-archive.md`)
- Gotify pings the phone when an agent finishes a LONG task and is waiting (silent in
  live chat). Wired as $HOME hooks on doc1, not behavior — knob + how to extend:
  [feedback-gotify-long-task-notifier.md](feedback-gotify-long-task-notifier.md)
