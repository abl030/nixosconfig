# Memory

## Shell Environment Quirk
- zoxide hook (`__zoxide_z`) causes `cd` commands to fail with exit 127 in Bash tool
- Workaround: use `git -C /path/to/repo` instead of `cd /path && git`

## Critical "Never Do" Rules
- NEVER run `npm install` manually in a Nix-managed Claude Code installation (breaks the store irreparably)
## Key Decisions (see beads for rationale)
- Custom Claude Code HM module stays over official `programs.claude-code` (bead nixosconfig-d7u)
- Episodic-memory plugin disabled (bead nixosconfig-d7u)
- Heavy MCPs (pfsense, unifi, HA) moved to subagent-only in .claude/agents/ to reduce context bloat
