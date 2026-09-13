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
0700/0600 permissions were checked live. `codexAgentsWrapperCheck` covers 11
routing and startup-failure cases; Nix lint, `nix flake check`, and the doc1
system build passed.

Revisit when upstream supports package-manager-owned daemon executables without
the standalone installer requirement. Verify plain dashboard startup, explicit
remote passthrough, and ordinary CLI commands before removing the wrapper.
