# Clean rc-free bash for Claude Code's Bash tool (`claude-agents`)

**Date:** 2026-06-28 · **Status:** working · **Host:** fleet-wide (HM `base.nix`)

## Problem

Claude Code's Bash tool does not run a pristine shell. At session startup the CLI
builds a **shell snapshot**: it runs the user's login shell (`$SHELL`) and dumps
its entire state — every alias and function — into
`~/.claude/shell-snapshots/snapshot-<shell>-<ts>-<rand>.sh`. That file is then
`source`d on **every** Bash tool invocation for the life of the session.

On this fleet `$SHELL` is zsh, so the snapshot drags in:

- `alias ls='lsd -A -F -l …'` (and ~19 others) — so `ls` output is `lsd`, not the
  plain binary the agent expects.
- zoxide's `__zoxide_z` / `__zoxide_hook` (this is the long-standing
  `cd … → exit 127` failure noted in MEMORY.md).
- atuin (`bash-preexec`) and starship init.

The snapshot is a verbatim state dump (it literally starts with `unalias -a` then
re-`declare`s the functions and re-adds the aliases), and it captures **zsh**
function bodies (`chpwd_functions[(Ie)…]`, `EPOCHREALTIME` arithmetic) that then
*misbehave* when the agent's bash sources them. Net: the agent wastes tokens
fighting the user's interactive config.

## Mechanism / lever

The snapshot is generated from whatever `$SHELL` points at, **once**, at process
start (it cannot be re-generated mid-session — a running session is stuck with the
shell it launched under). So the fix is to launch `claude` with `$SHELL` pointed at
a bash that reads **no** rc files:

```
bash --norc --noprofile
```

`$SHELL` must be a bare executable path (no args), so this needs a 2-line wrapper.
Generated from that wrapper, the snapshot dump comes out empty → the agent gets a
vanilla bash. (The only non-stock functions that remain are Claude Code's *own*
bundled `find`→bfs / `grep`→ugrep wrappers, injected by the `claude` binary itself
— prefix `command` to bypass them.)

Verified: under the wrapper, `alias` is empty, `ls` → `/run/current-system/sw/bin/ls`,
`z`/`__zoxide_z` → not found, and PATH (the Nix entries) is intact.

## Implementation (declarative)

`modules/home-manager/profiles/base.nix` (the shared HM profile) does two things:

**1. `SHELL` in `settings.json` `.env` (the load-bearing fix).** The `claudeConfig`
home-activation merges `"SHELL": "…/claude-clean-bash"` into
`~/.claude/settings.json`'s `.env` block (next to the `DISABLE_*` opt-outs). Claude
applies `.env` to its own process env, and — critically — that env **propagates to
the background `claude daemon` and every session it forks**. Proof: the daemon and
background sessions already carry the `DISABLE_*` vars, which come *only* from this
block. So every session snapshots clean bash regardless of how it was launched:
foreground, Agent View, `claude --bg`, and the systemd `claude -p` diagnosis runs.
This is the same argv-independent, daemon-proof pattern used for plugins/MCP (see
[plugins-in-agent-view.md](plugins-in-agent-view.md)).

**2. Two `writeShellScriptBin`s in `home.packages`:**

- **`claude-clean-bash`** — `exec bashInteractive --norc --noprofile "$@"` (the
  rc-free shell `$SHELL` points at).
- **`claude-agents`** — exports `SHELL=…/claude-clean-bash`, then
  `exec claude --verbose agents --dangerously-skip-permissions "$@"`. The everyday
  entrypoint (opens the Agent View). Its `export SHELL` is now belt-and-suspenders
  for the **foreground only** — see the gotcha below.

## Why the launcher's `export SHELL` alone wasn't enough (the daemon)

The Bash-tool shells in Agent-View / `--bg` sessions are **not** children of the
foreground `claude-agents` process. They are forked by a long-lived
`claude-unwrapped daemon run --origin transient` supervisor:

    daemon run (SHELL=zsh) → --bg-pty-host → --bg-spare → zsh -c 'source <snapshot-zsh>'

That daemon is spawned lazily by the *first* `claude` invocation and then **reused**
across launches. A plain `claude` (`SHELL=zsh`) typically wins that race, so the
daemon — and every worker it forks — inherits `SHELL=zsh`, no matter that a later
`claude-agents` exported `SHELL=clean-bash` on its own foreground process.
`export SHELL` in the wrapper cannot reach a daemon it didn't spawn. Same class of
gotcha as plugins/MCP: foreground/argv tricks don't reach daemon-respawned workers
— only on-disk config (`settings.json`) does. Hence fix #1 above.

**Caveat when deploying the fix:** a stale `SHELL=zsh` daemon already running will
persist and keep serving zsh snapshots to *new* sessions until it is killed. After
activation, kill it once — `pkill -f 'claude-unwrapped daemon run'` — then relaunch
`claude-agents`; the fresh daemon inherits `SHELL=clean-bash` from `settings.json`
`.env`. Killing the daemon drops active Agent-View background sessions, so wait for
them to finish first.

## Confirming it took

In a session started via `claude-agents` (after the stale daemon was killed):

- the Bash tool's snapshot is `snapshot-claude-clean-bash-*.sh` (not `snapshot-zsh-*`),
- `type ls` → `/run/current-system/sw/bin/ls` (not the `lsd` alias), and
- the daemon proves it:
  `tr '\0' '\n' < /proc/$(pgrep -f 'daemon run')/environ | grep '^SHELL='` →
  `…/claude-clean-bash`.

## Why not just `SHELL=bash`?

The aliases/zoxide live in `~/.bashrc` too, so a plain bash snapshot would re-dump
them. Only `--norc --noprofile` guarantees an empty capture without touching the
user's real dotfiles.
