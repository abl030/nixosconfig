# Temporary workstation US VPN fast path

**Status:** active temporary testing workflow

**Last verified:** 2026-07-31

**Operator surface:** `.claude/skills/temporary-us-vpn/SKILL.md`

## Purpose

Temporarily policy-route epimetheus (`192.168.1.5`) or framework (`192.168.1.37`) through the AirVPN USA path to obtain a fresh US public IP, then return only that host to direct WAN. This is an operator testing action, not permanent network configuration.

## Live routing contract

The fast path uses the existing `MV_VPN_IPS` policy cohort:

- alias id 9: `MV_VPN_IPS`;
- LAN pass rule id 35: `MV_VPN_IPS` via `AIRVPN_US_PREFERRED`;
- LAN kill-switch rule id 36;
- USA gateway: `AirVPN` on `opt5` / `AIRVPN_US`;
- direct post-rollback gateway: `WAN_DHCP`.

`AIRVPN_US_PREFERRED` has Netherlands fallback, so alias membership alone does not prove a US exit. The workstation must make a fresh IPv4 request and return `country=US` before the operator calls the enable successful.

The historical `MV_VPN_SG_IPS` path is not used. Its ids and geography drifted: rules 37/38 are disabled, and `AirVPN_SG` is now the Netherlands tunnel.

## Safety model

The skill performs a fixed four-object preflight instead of rediscovering topology. It fails closed if alias/rule identities drift. It preserves the live alias's parallel address/detail pairs, mutates only `.5` or `.37`, applies once, and reads the alias back.

Temporary membership deliberately does not update doc2's `vpnClientIPs` mirror. Rollback removes the temporary workstation member and restores the normal mirror relationship. Permanent membership must use the full pfSense workflow and update the Nix mirror.

No rule, gateway, tunnel, NAT, DHCP, DNS, or firewall state-table changes are part of this workflow. Never SSH into pfSense.

## Rollback

Remove only the selected workstation IP from alias 9, preserve every other live pair, apply the firewall, re-read alias 9, and prove fresh workstation egress returns `country=AU`. Rollback is idempotent.

If enable reaches a non-US exit, the skill rolls the selected workstation back automatically rather than leaving a misleading VPN state active.

## Live model acceptance — 2026-07-31

Three sequential end-to-end cycles ran against epimetheus. Every cycle began on
direct AU egress, reached the Los Angeles US exit, rolled back, and ended on the
original Perth AU address. Usage receipts confirm the requested OpenAI Codex
models:

| Model | Complete cycle | Result | Finding folded into skill |
|---|---:|---|---|
| `gpt-5.6-sol` | 4m32s | pass | document Wake-on-LAN, expected apply retry, MCP-only audit, and no redundant final probes |
| `gpt-5.6-terra` | 80s | pass | make every `ipinfo.io` proof explicitly execute through SSH on the target |
| `gpt-5.6-luna` | 58s | pass | no new ambiguity; safe fast path accepted |

The Luna cycle demonstrates roughly 29 seconds per half (enable and rollback),
including fresh host egress proof. Both alias updates consistently required the
documented immediate second apply because the first response reported pending
`aliases` work.

Final independent verification after Luna found epimetheus absent from alias 9,
rules 35/36 enabled and unchanged, and fresh epimetheus egress restored to
direct Perth/AU routing. Public addresses are intentionally not recorded in
tracked documentation.
