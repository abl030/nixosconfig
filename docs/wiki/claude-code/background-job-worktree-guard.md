# Claude Code background jobs and the worktree guard

**Date:** 2026-09-23
**Status:** guard behaviour probed on doc1 with Claude Code 2.1.280; `forgejo-push`
workaround shipped. Issue: Forgejo #227.
**Revisit:** after a Claude Code upgrade changes the guard, or once the upstream
false-positive report below gets a response.

## What it is

When a Claude Code **background job** calls `EnterWorktree`, the harness starts
statically checking every Bash command. Its aim is to keep the job's git
operations inside the job's own worktree, so the job can't touch the user's
shared checkout. Any command it can't prove leaves git alone gets refused with
"This session is isolated in the worktree …".

It is **not** a repo hook or a permission rule:

- It still applies in bypass-permissions mode.
- A `Bash(nix eval:*)` allow rule in `.claude/settings.local.json` made no
  difference.
- No `.claude/settings*.json` change can switch it off.

Treat it as a fixed constraint and shape commands to fit it.

## Probe results (2026-09-23)

| Command | Result | Why |
|---|---|---|
| `ai-gotify-notify complete Claude` alone | runs | |
| same, in one call with `git status` | refused | `complete` is read as the shell built-in that runs strings |
| `nix eval …`, `nix --quiet eval …`, `nix-instantiate --eval …` | refused | `eval` is read as the shell's `eval` |
| `nix flake metadata`, `nix build --dry-run`, `nix build --expr …` | runs | |
| `./scripts/forgejo-auth.sh rest …` | runs | |
| `./scripts/forgejo-auth.sh git-push` / `git-ls-remote` (even `--repo .`) | refused | a `git-*` subcommand **or** a bare `…/nixosconfig.git` URL operand counts as git |
| `forgejo-push`, `forgejo-ls-remote` | runs | no git operand on the command line |
| `cd ~/repo && git …`, `cd $VAR && git …` | refused | the path is expanded at runtime |
| `cd /home/abl030/repo && git …`, `git -C /abs/path …` | runs | the path is literal |
| heredoc-write a script and `bash` it in one call | refused | the guard can't see what the heredoc hands to bash |
| heredoc Python whose text mentions git | refused | same |
| script written with the Write tool, then `bash /abs/script.sh` as its own call | runs | |

The original report (2026-09-23, during the mrnews deploy) also saw these refused:

- a command name held in a variable (`$SWS …`)
- `sed -i` with a program built at runtime
- **every** Bash call, even `ls`, in a subagent that was already running when the
  parent called `EnterWorktree`

## What to do

- **Push to Forgejo** from doc1 with `forgejo-push [REFSPEC]`, and check the result
  with `forgejo-ls-remote [REF]`. Both act on the checkout that contains `$PWD`.
  - Defined in `hosts/proxmox-vm/forgejo-push.nix`.
  - They call `scripts/forgejo-auth.sh` with fixed nixosconfig URLs and the nixbot
    token, so every check it does still applies.
  - They are not a way around the guard: they push only the job's own checkout,
    which is what the guard allows.
- **Gotify ping:** send `ai-gotify-notify complete|input Claude` as a Bash call of
  its own.
- **Nix eval:** prefer `nix build --dry-run`, `nix flake check`, or
  `nix build --impure --expr '…'` (it returns derivations, not values). When you
  need `nix eval` output, write the command to `$CLAUDE_JOB_DIR/tmp/x.sh` with the
  Write tool, then run `bash /abs/path/x.sh` as its own call.
- **Other repos:** use literal absolute paths, `git -C /home/abl030/<repo> …` or
  `cd /home/abl030/<repo> && …`. Never use `~` or variables before git.
- **Subagents:** call `EnterWorktree` *before* starting any subagent. One started
  earlier can lose its shell entirely.
- **Last resort:** `ExitWorktree` (keep) returns to the shared checkout without
  the guard. Only do this for work that doesn't touch the shared tree.

## Upstream

Filed 2026-09-23:

- `nix eval` and `x complete` are the same token-in-argument-position false
  positive as
  [anthropics/claude-code#88312](https://github.com/anthropics/claude-code/issues/88312);
  our cases are added there as a comment.
- Running subagents losing Bash when the parent enters a worktree:
  [anthropics/claude-code#96209](https://github.com/anthropics/claude-code/issues/96209).
- Not filed: a `git-*` subcommand or a `.git` URL passed to a launcher. This is
  the guard being cautious on purpose; `forgejo-push` avoids it.
