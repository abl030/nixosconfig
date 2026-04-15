# Memory

## Shell Environment Quirk
- zoxide hook (`__zoxide_z`) causes `cd` commands to fail with exit 127 in Bash tool
- Workaround: use `git -C /path/to/repo` instead of `cd /path && git`

## Critical "Never Do" Rules
- NEVER run `npm install` manually in a Nix-managed Claude Code installation (breaks the store irreparably)
- NEVER flush pfSense firewall states after rule changes — see [feedback_pfsense_no_state_flush.md](feedback_pfsense_no_state_flush.md)

## Key Decisions
- Custom Claude Code HM module stays over official `programs.claude-code`
- Episodic-memory plugin disabled (npm-install breaks the Nix store)
- Heavy MCPs (pfsense, unifi, HA) moved to subagent-only in .claude/agents/ to reduce context bloat
- Task tracking lives in GitHub issues (beads removed 2026-04-14 — see `docs/beads-archive.md`)
