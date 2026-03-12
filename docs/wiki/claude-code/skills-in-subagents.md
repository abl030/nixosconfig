# Skills Injection in Subagents

> Researched: 2026-03-12 | Claude Code v2.1.74 | Status: **Broken upstream**

## Summary

The `skills:` frontmatter field in `.claude/agents/*.md` is documented but **does not work reliably**. Two distinct bugs prevent skill content from being injected into subagents.

## Bug 1: Plugin skills never resolve

**Issue**: [#15178](https://github.com/anthropics/claude-code/issues/15178), [#25834](https://github.com/anthropics/claude-code/issues/25834)

The skill loader function (`aL`) filters by `loadedFrom === "skills"`, which excludes plugin-sourced skills. When an agent references a plugin skill by name (e.g. `home-assistant-best-practices` from the `home-assistant-skills` plugin), the resolution function finds nothing to match against because the skill was never loaded into the candidate set.

**Affects**: All spawn methods (in-process Agent tool AND team teammates).

**Tested formats** (all failed):
- `skills: [home-assistant-best-practices]` (bare name)
- `skills: [home-assistant-skills:home-assistant-best-practices]` (namespaced)
- Symlinked plugin skill into `.claude/skills/` (project-level) — also failed

## Bug 2: Team teammates never process `skills:` at all

**Issue**: [#24780](https://github.com/anthropics/claude-code/issues/24780) (primary tracker), [#29441](https://github.com/anthropics/claude-code/issues/29441) (closed as dup)

The teammate startup code path (`y_6`) reads the agent definition and builds a system prompt but **never reads `agent.skills`**. There is no skill resolution, loading, or injection code in this path at all.

**Affects**: Only team-spawned teammates (separate CLI processes). Does NOT affect in-process Agent tool spawning.

## What actually works

| Scenario | Works? |
|----------|--------|
| Project-level skill (`.claude/skills/`) + in-process Agent tool | **YES** |
| Plugin skill + in-process Agent tool | **NO** (bug 1) |
| Plugin skill + team teammate | **NO** (bugs 1+2) |
| Any skill + team teammate | **NO** (bug 2) |
| Subagent reads skill files via Glob/Read (workaround) | **YES** ([#32910](https://github.com/anthropics/claude-code/issues/32910)) |

## Source code evidence (v2.1.74)

Skill resolution in the in-process path (`lGY`):
```javascript
function lGY(A, q, K) {
  // 1. Try exact match against loaded skills
  if (LY6(A, q)) return A;
  // 2. Try prefixing with agent's plugin namespace
  let Y = K.agentType.split(":")[0];
  if (Y) { let w = `${Y}:${A}`; if (LY6(w, q)) return w; }
  // 3. Try suffix match (`:skillName`)
  let z = `:${A}`, _ = q.find((w) => w.name.endsWith(z));
  if (_) return _.name;
  return null;
}
```

The `aL` function that populates the candidate set filters to `source !== "builtin"` and `loadedFrom` in `["bundled", "skills", "commands_DEPRECATED"]`. Plugin skills have a different `loadedFrom` value and are excluded.

## Agent body size limit (discovered 2026-03-12)

Subagent `.md` files have a **silent body truncation limit**. Through testing:

- **187 lines (pfSense)**: Full context verified — all interfaces, aliases, rules, DHCP mappings visible.
- **142 lines (UniFi)**: Full context verified — all devices, SSIDs, port profiles, VLANs visible.
- **67 lines (3KB)**: Fully loaded. All content visible including best practices, system overview, automation summaries, and entity references.

**Note**: Agent body is **cached at session start**. Edits within a session require a chat restart to take effect — this caused false "truncation" results during initial testing.

**Lesson**: Keep agent bodies concise regardless. Summarise and group — don't list every entity. Tell the agent how to query for details (e.g. "use ha_search_entities to find specific entities"). Subagents also receive CLAUDE.md and MEMORY.md which consume part of the budget. The 67-line HA agent is a better pattern than exhaustive listings even if larger files technically work.

**Agent body IS cached at session start** — edits within a session won't take effect until chat restart.

## Our workaround

For the `homeassistant` subagent, we:
1. Trimmed from 497→67 lines by summarising entity groups and pointing to live queries
2. Embedded a condensed best-practices paragraph directly in the agent body
3. Pointed reference docs to the plugin cache path (`~/.claude/plugins/cache/homeassistant-ai-skills/...`)
4. Keep the plugin installed fleet-wide via Nix (flake input + `base.nix`) for main-conversation auto-triggering

The plugin still provides value in the main conversation where Claude auto-triggers it based on the skill description. It just can't be preloaded into subagents via `skills:` frontmatter.

## When to revisit

Monitor these issues for resolution:
- [#24780](https://github.com/anthropics/claude-code/issues/24780) — teammates skills (no Anthropic response as of 2026-03-12)
- [#15178](https://github.com/anthropics/claude-code/issues/15178) — plugin skills resolution

When fixed, update `.claude/agents/homeassistant.md`:
1. Remove the embedded "HA Best Practices" section from the body
2. Re-enable `skills: [home-assistant-best-practices]` in frontmatter

## Test matrix for verification

Create a canary skill and test agent:

```bash
# Canary skill
mkdir -p .claude/skills/test-canary
cat > .claude/skills/test-canary/SKILL.md << 'EOF'
---
name: test-canary
description: Test skill injection
---
CANARY_STRING_ALPHA_7742. Skill injection working.
EOF

# Test agent
cat > .claude/agents/test-skill-inject.md << 'EOF'
---
name: test-skill-inject
description: Test skill injection
skills:
  - test-canary
---
Report whether CANARY_STRING_ALPHA_7742 appears in your context without reading files.
EOF
```

Then spawn `test-skill-inject` via Agent tool. If the canary string is visible, project-level skills work. Repeat with a plugin skill name to test bug 1.

Clean up test files after verification.
