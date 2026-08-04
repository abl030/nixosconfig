---
name: feedback-gotify-long-task-notifier
description: Superseded duration-based notifier; semantic Gotify policy is canonical
metadata:
  type: feedback
---

The old doc1 Claude hook that paged after any turn lasting at least 180 seconds is
superseded. It was too noisy because elapsed time is not evidence that a meaningful
work arc completed or that human input is required.

Canonical behavior is documented in
`docs/wiki/claude-code/semantic-gotify-notifications.md`:

- Notify automatically for real permission/elicitation requests.
- Notify once when an agent semantically completes a meaningful, verified work arc.
- Stay silent for ordinary conversation, progress updates, elapsed-time thresholds,
  subagent completion, and routine finished turns.
- Apply to Claude Code and Codex general configuration on doc1.

The tracked Home Manager activation removes the retired
`~/.claude/hooks/gotify-turn-ping.sh` references without deleting unrelated hooks.
