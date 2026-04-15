---
name: pfSense — never flush firewall states
description: When routing changes on pfSense (policy rules, gateway swaps, alias edits), do NOT flush the state table. Never ask the pfsense subagent to do it either.
type: feedback
originSessionId: c7fb99f0-ddc2-4793-9a9c-a4276337bb64
---
Never run `pfctl -F state`, flush individual states, or ask the pfsense subagent to "clear stale states so new rule takes effect". Stale pre-rule connections will age out on their own.

**Why:** User explicitly said "it never ever needs to do that" after the pfsense subagent attempted a state flush and hung. They consider it unnecessary and risky — flushing can drop unrelated long-lived connections across the whole fleet (SSH, VPN, syncthing, etc.), not just the target host.

**How to apply:** When delegating routing changes to the pfsense subagent, explicitly instruct it NOT to flush states after applying rules. If the user wants an immediate effect, suggest restarting the network on the affected host instead (`nmcli con down/up`, reboot, etc.) — that kills only that host's states.
