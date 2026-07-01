---
name: feedback-email-use-mailsearch-not-gmail
description: "Email/mail tasks go to the mailsearch agent (local notmuch archive on doc2), NEVER the Gmail MCP connector"
metadata:
  type: feedback
---

When the user asks about "emails" / "my mail" / "find that invoice" — even if they
never say the word "Gmail" — route it to the **`mailsearch` subagent**, which
searches the purpose-built local notmuch + embeddings archive on doc2 (~143k msgs,
personal **and** Cullen Wines work mail). See `docs/wiki/services/mailsearch.md`.

Do NOT use the inherited Gmail/Google MCP connector (`mcp__*Gmail*` /
`mcp__*Google*`). The user built the local archive precisely to be better than the
connector, and finds the Gmail-first reflex actively annoying.

**Why:** the Gmail connector is strictly worse than the local archive — it covers
only one Gmail account (misses the Cullen work mail), it's OAuth-gated so its token
silently expires (the "1 MCP server needs authentication" prompt), and it's not the
local corpus the mailsearch agent is trusted to read attachment contents from.

**How to apply:** for any mail ask, spawn the `mailsearch` agent (it self-corrected
off Gmail last time but only after wasting calls). The agent's own prompt now
forbids touching the Gmail connector. Personal mail happens to live in the gmail
Maildir leg — that does NOT mean use the Gmail connector.
