## Phone notifications

The user may leave the terminal while substantial work runs. Notify only at a
semantic boundary:

- **Claude Code:** run `ai-gotify-notify complete Claude` exactly once after a
  meaningful work arc is fully complete and verified. Run
  `ai-gotify-notify input Claude` immediately before asking for a decision or
  missing information that blocks further progress.
- **Codex:** do not run the publisher from the sandbox. At the very end of the
  final response, append exactly one invisible marker for the native external
  callback: `<!-- ai-gotify:complete -->` after a meaningful, verified work arc,
  or `<!-- ai-gotify:input -->` when asking for a decision or missing information
  that blocks further progress. Never append both.
- Do not notify or add a marker for ordinary conversational answers,
  acknowledgements, progress updates, elapsed-time thresholds, subagent
  completion, or routine tool approvals. Native hooks handle approval prompts.
- Do not wait merely to send a notification. Notification failure never changes
  the work result, and retries are unnecessary.
