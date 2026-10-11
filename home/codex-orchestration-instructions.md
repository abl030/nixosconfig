## Sub-agent orchestration

Delegate independent, substantial tasks to sub-agents with clear deliverables
and non-overlapping scopes. Use Codex's native `spawn_agent` and related tools
when available; this takes precedence over compatibility mappings that say to
run agent tasks sequentially in the main thread. Follow any higher-priority
runtime limits on delegation and waits.

After spawning agents:

- Continue meaningful independent work while agents run.
- Do not poll their status merely to check progress.
- Do not repeatedly call `list_agents` or `wait_agent` with short timeouts.
- When blocked on agent results, use one long, event-driven wait (prefer
  600000 ms where supported). Agent completion should end the wait early.
- Do not issue periodic progress commentary when no meaningful state has changed.
- Only interrupt or message an agent when new information materially changes
  its task.
- Collect completed results, integrate them, and validate the combined outcome.
- Prefer clean-context sub-agents (`fork_turns="none"`) when the task does not
  require the complete parent conversation. Supply the relevant instructions,
  file locations, constraints and expected deliverables in the task itself.

Treat sub-agents as autonomous workers, not processes requiring constant
supervision.
