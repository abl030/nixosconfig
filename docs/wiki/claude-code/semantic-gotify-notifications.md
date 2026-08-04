# Semantic Gotify notifications for Claude Code and Codex

**Date:** 2026-08-04
**Status:** configured declaratively for doc1 (`proxmox-vm`)

## Goal

Notify the phone when Claude Code or Codex either needs human input or completes
a meaningful work arc. Do not page merely because a turn ran for a fixed amount
of time, and do not page for routine conversational turns.

## Design

The implementation has two complementary paths:

1. **Automatic attention hooks**
   - Claude Code forwards the exact `PermissionRequest` and `Elicitation`
     lifecycle events plus `agent_needs_input` for background agents. It does not
     subscribe to idle or completion notifications.
   - Codex forwards `PermissionRequest` lifecycle hooks. Codex treats user hooks
     as untrusted until their exact definition is reviewed once through `/hooks`;
     until then it skips the automatic permission ping rather than executing an
     unreviewed command.
   - Claude's `idle_prompt` is deliberately excluded because it fires after
     ordinary completed turns and is equivalent to noisy per-turn notification.
2. **Semantic agent instructions**
   - A managed block is merged into `~/.claude/CLAUDE.md` and
     `~/.codex/AGENTS.md` without replacing unrelated user/plugin content.
   - Claude calls `ai-gotify-notify` at meaningful completion or before a
     genuinely blocking question.
   - Codex appends an invisible semantic marker to its final response. Its native
     top-level `notify` callback runs outside the network sandbox and publishes
     only marked turns. Routine approval prompts remain handled by native hooks.

There is no reliable native "meaningful arc" event. Claude `Stop` and an unmarked
Codex `notify` callback are turn-level events, so paging on either directly would
recreate the noise. The semantic decision belongs in the agent instruction,
while native hooks cover requests that may pause before another model action.

## Source of truth

- `home/ai-gotify-notify.sh` — shared, fail-open Gotify publisher and hook
  adapter.
- `home/ai-notification-instructions.md` — one instruction body shared by both
  clients.
- `scripts/merge-markdown-block.py` — atomic/idempotent managed-block merge.
- `scripts/merge-claude-notification-hooks.py` — surgical, idempotent migration of
  Claude's mutable hook configuration.
- `scripts/merge-codex-notification-hooks.py` — surgical merge of the managed
  handler into Codex's mutable `~/.codex/hooks.json`.
- `scripts/merge-toml-settings.py` — line-preserving Codex TOML merge, including
  the managed native callback without replacing an unrelated existing `notify`.
- `home/utils/common.nix` — doc1-only package, Codex hook, Claude hook migration,
  and global instruction activation.

Home Manager continues to preserve runtime-owned Claude/Codex configuration. It
removes only hooks whose parsed command exactly matches the retired
`gotify-turn-ping.sh start|stop` invocation; unrelated hooks and settings remain
untouched.

## Security and privacy

- The endpoint and token path are pinned to `https://gotify.ablz.au` and
  `/run/secrets/gotify/token`; inherited agent environment variables cannot
  redirect the credential. The token is supplied to curl through stdin as an
  `X-Gotify-Key` header, not exposed in the process argument list.
- Notifications contain only agent name, event class, and project basename.
  They do not forward prompts, assistant output, commands, tokens, public IPs,
  or arbitrary hook messages.
- Publisher failures always exit successfully so Gotify cannot block an agent.
- Hooks enqueue a transient user service and return immediately; network delivery
  cannot delay a permission prompt or agent response. The detached curl request
  has an eight-second maximum.
- Mutable-file merges serialize cooperating activations with an advisory lock and
  abort on updates observed before replacement. Malformed marker/hook structures
  also abort rather than being rewritten.

## Verification

Dry routing tests set `AI_GOTIFY_TEST_MODE=1` and use an
`AI_GOTIFY_CAPTURE_FILE=/tmp/ai-gotify-notify-test-*` path; in that mode no
secret is read and no network request occurs. Required checks:

```bash
bash -n home/ai-gotify-notify.sh
python3 scripts/merge-markdown-block.py --self-test
python3 scripts/merge-claude-notification-hooks.py --self-test
python3 scripts/merge-codex-notification-hooks.py --self-test
python3 scripts/merge-toml-settings.py --self-test
nix-instantiate --parse home/utils/common.nix
alejandra --check home/utils/common.nix
nix build --no-link .#homeConfigurations.proxmox-vm.activationPackage
```

Codex callback routing can be exercised without network or secrets:

```bash
AI_GOTIFY_TEST_MODE=1 \
AI_GOTIFY_CAPTURE_FILE=/tmp/ai-gotify-notify-test-codex.json \
ai-gotify-notify codex-notify \
  '{"type":"agent-turn-complete","cwd":"/tmp/demo","last-assistant-message":"done <!-- ai-gotify:complete -->"}'
```

After explicit deployment to doc1, verify the effective files contain one managed
instruction block, Claude has no elapsed-time hooks, and both clients accept their
configuration. Open Codex `/hooks`, review the exact doc1 permission command, and
trust it once; a changed Nix store path after a later update requires review again
by design. Confirm the top-level `notify` callback, then perform one controlled
input ping and one controlled semantic completion ping.

## Rollback

Use a signed cleanup commit and deploy doc1: retain a one-shot activation that
removes only the `HOMELAB AI NOTIFICATIONS` blocks, managed Claude/Codex hook
entries, and managed top-level Codex `notify` callback before removing the
package. A plain revert is insufficient because runtime-owned files intentionally
retain merged content. No secret rotation is needed.
