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

`modules/home-manager/profiles/base.nix` (the shared HM profile) builds two
`writeShellScriptBin`s and puts them in `home.packages`:

- **`claude-clean-bash`** — `exec bashInteractive --norc --noprofile "$@"`.
- **`claude-agents`** — exports `SHELL=…/claude-clean-bash`, then
  `exec claude --verbose agents --dangerously-skip-permissions "$@"`.

`claude-agents` is the everyday entrypoint (opens the Agent View — `claude agents`
manages background sessions). It does **not** wrap the `claude` binary: base.nix
deliberately keeps `claude` unwrapped so Agent View / `claude --bg` supervisors
respawn workers with a fixed argv and still load plugins+MCP from on-disk config
(see [plugins-in-agent-view.md](plugins-in-agent-view.md)). A separate launcher
sidesteps that entirely.

## Confirming it took

In a session started via `claude-agents`:

- a new `~/.claude/shell-snapshots/snapshot-claude-clean-bash-*.sh` appears
  (instead of `snapshot-zsh-*`), and
- `type ls` → `/run/current-system/sw/bin/ls` (not the `lsd` alias).

## Why not just `SHELL=bash`?

The aliases/zoxide live in `~/.bashrc` too, so a plain bash snapshot would re-dump
them. Only `--norc --noprofile` guarantees an empty capture without touching the
user's real dotfiles.
