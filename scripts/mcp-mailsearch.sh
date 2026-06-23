#!/usr/bin/env bash
# doc1 -> doc2 read-only mail-search MCP, over SSH stdio.
#
# The MCP server runs on doc2 (where the index lives) as the unprivileged
# `mailsearch-ro` user. That user's authorized key (homelab.services.mailsearch,
# agentAccess) is a FORCED COMMAND that runs only the read-only MCP binary — so
# there is no secret here and the command we pass is ignored by the server.
#
# Reached over the existing bastion fleet key (doc1 -> doc2). No network
# listener, no port. hermes / other hosts have no access by construction.
#
# See: modules/nixos/services/mailsearch.nix, .claude/agents/mailsearch.md
set -euo pipefail
# No command arg: doc2's forced-command on mailsearch-ro runs the MCP binary
# unconditionally and ignores SSH_ORIGINAL_COMMAND.
exec ssh -T -o BatchMode=yes mailsearch-ro@doc2
