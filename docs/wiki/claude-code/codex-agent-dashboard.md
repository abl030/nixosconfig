# Codex agent dashboard on NixOS

Date: 2026-09-13. Status: declarative local app-server integration.

Codex 0.154.0's plain `codex agents` automatically starts a daemon that requires
`~/.codex/packages/standalone/current/codex`. The Nix package does not have that
installer-managed layout. An explicitly selected app-server works with the Nix
binary; installing a second self-updating copy is unnecessary.

`home/utils/codex-agents.nix` keeps the upstream package and wraps its `codex`
entry point. Plain `codex agents` starts `codex-app-server.service` through the
systemd user manager, waits for its socket, and connects automatically. The
service starts on demand and survives closing the dashboard. Home Manager
restarts an active instance when its unit or package changes.

The server reads the user's existing `~/.codex` configuration, authentication,
plugins and history. It runs from the home directory so the first project's
configuration does not become a server-wide default. The wrapper preserves
explicit `--remote`, help, alternate `CODEX_HOME`, and all other commands. It
recognizes the usual `codex agents [options]` form; leading global flags are
passed directly to upstream.

The shared server and dashboard launcher use the user's requested YOLO defaults:
`approval_policy=never` and `sandbox_mode=danger-full-access`. New dashboard
tasks therefore run without Codex's filesystem/network sandbox or approval
prompts. Both sides need these defaults: Codex 0.154.0's dashboard explicitly
sends its client permission settings when creating a task, overriding the
server's defaults. The launcher puts defaults before caller arguments so an
explicit `-c` override still wins. Existing threads retain their saved
permissions, and explicit caller settings still win. The shared global defaults described below also cover ordinary CLI sessions.

The dashboard manages tasks created on this shared server. Existing ordinary
CLI sessions use their own servers, so their live status is not shared with the
dashboard. To deliberately share an interactive chat, use:

```sh
codex --remote "unix://$XDG_RUNTIME_DIR/codex-app-server/control.sock"
```

The socket lives inside the user's runtime directory in `codex-app-server/`,
mode 0700, with umask 0077. There is no TCP listener, proxy, remote-control
enrollment or new credential. The process has the same user authority as Codex
in a terminal, including existing sudo access; it must execute authorized
developer tools, so `NoNewPrivileges` cannot be enabled. A compromise retains
that user's existing blast radius. Executables come from the Nix store and
updates remain controlled by signed fleet deployments.

Inspect and restart it with:

```sh
systemctl --user status codex-app-server
journalctl --user -u codex-app-server -n 50
systemctl --user restart codex-app-server
```

Restarting the service interrupts tasks running on it. To stop it without
changing configuration, close its tasks and run
`systemctl --user stop codex-app-server`; the next `codex agents` starts it again.
Rollback is a signed revert of this integration followed by the normal verified
fleet deployment. The user's Codex configuration and history are not replaced.

Validation on doc1: the wrapped dashboard created a task on the systemd user
server, ran a shell command successfully, found `git` and `uvx` on PATH, and
used the launching repository as its working directory. Socket ownership and
0700/0600 permissions were checked live. `codexAgentsWrapperCheck` covers 12
routing and startup-failure cases; Nix lint, `nix flake check`, and the doc1
system build passed.

Revisit when upstream supports package-manager-owned daemon executables without
the standalone installer requirement. Verify plain dashboard startup, explicit
remote passthrough, and ordinary CLI commands before removing the wrapper.


## Global defaults and restart/resume recovery (2026-10-11)

Status: defaults applied and verified with Codex 0.162.1; explicit client
permission overrides remain authoritative.

A family-history conversation initially had unrestricted permissions. At
07:44:17 Perth time the separately installed daemon updater selected 0.162.1;
it forcibly stopped the active daemon after 60 seconds and launched its
replacement at 07:45:17. The client resumed the thread at 07:45:18 with the
`:workspace` permission profile. The sandbox then overlaid the NAS and `.git`
as read-only although the underlying NFS/ext4 filesystems were writable.
Evidence is the local `~/.codex/app-server-daemon/daemon-updater.stderr.log`
and the 2026-10-11 session rollout. This establishes the restart/resume trigger,
but does not identify whether saved-setting recovery or the reconnecting client
introduced the workspace profile.

The dashboard wrapper's command-line flags do not configure every other client.
`home/utils/common.nix` now merges `approval_policy = "never"` and
`sandbox_mode = "danger-full-access"` into mutable user-level config on hosts
that import it. This is the user's requested unrestricted execution policy;
it grants Codex the launching user's filesystem/network authority, including
that user's existing sudo access. No host sudo, remote listener, credential or
system sandbox policy changes are involved. Client requests and persisted
thread profiles can still override these defaults: repairing a restricted
thread requires explicitly selecting Full access in the client, rather than
editing NAS permissions. Do not rewrite historical rollout files.

The same managed merge installs the requested model settings:
`model = "gpt-6.1-sol"`, `model_context_window = 872000`, and
`model_auto_compact_token_limit = 697600`. The installed model catalogue
advertises a maximum of 872000; isolated real turns reported an effective
context window of **828400** (95%). This verifies this account/build at the
listed date, not every client or future catalogue. Fresh sessions pick up the
new defaults; an already loaded thread can retain its previous settings.

Multi-agent configuration enables both `features.multi_agent` and
`features.multi_agent_v2.enabled`. The V2 table enables `wait_agent_enabled`,
with minimum/default/maximum waits of 300000/600000/1200000 ms. The original
example omitted V2's `enabled = true`, which is required in this build.
The handler uses the configured default when omitted, raises requests below
minimum, rejects requests above maximum, and returns early on mailbox activity.
Higher-priority runtime limits can still constrain waits.

`home/codex-orchestration-instructions.md` is installed as a managed block in
`~/.codex/AGENTS.md`, preserving plugin and notification blocks. It directs
independent delegation, meaningful work while agents run, long event-driven
waits, minimal supervision, and clean-context children when appropriate. Its
native-tool rule overrides the old compatibility map's sequential dispatch.

Verification used an isolated app-server and a temporary copy of the live
configuration; the active daemon was not restarted. Strict configuration
loading and both feature flags passed. A new unrestricted thread stayed
unrestricted after server restart/resume. A persisted workspace thread could
be repaired by an explicit unrestricted resume after unloading it, and retained
the repair across another restart. Resuming an already loaded thread returns
its current settings, so it is not a valid test of saved-setting recovery.
The automatic updater was left unchanged. Nix formatting, deadnix, statix,
merge self-tests and adapter checks passed. The Nix-generated managed JSON
was built and reapplied idempotently to the live config. Full flake evaluation
was attempted twice on current master (including without the evaluation cache),
but doc2 hit an unrelated missing `homelab-grafana-dashboards` store path;
this is not reported as a passing full-flake check.

Configuration fields are documented in the [official configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
Version-specific wait and resume behavior was checked against OpenAI's
[rust-v0.162.1 sources](https://github.com/openai/codex/tree/rust-v0.162.1).
Rollback: signed revert of the Nix change, normal verified deployment, then
explicitly restore any runtime preferences if needed. Pre-change local config
and global instructions were backed up under `~/.codex/config-backups/`.
