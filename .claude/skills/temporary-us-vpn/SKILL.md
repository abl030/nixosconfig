---
name: temporary-us-vpn
description: Use when temporarily putting epi or framework on the US VPN, or rolling either host back to direct WAN. Executes the fixed pfSense fast path without topology discovery.
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [homelab, pfsense, vpn, temporary, rollback]
    related_skills: [pfsense]
---

# Temporary US VPN

## Overview

This is the narrow, reversible fast path for giving one of the user's two workstations a fresh US public IP through pfSense, then returning it to normal direct-WAN egress.

The host identities and routing objects are fixed. Do not discover DHCP, search UniFi, inspect all firewall rules, redesign routing, SSH to pfSense, or ask which IP belongs to which host.

| User name | Canonical name | LAN IPv4 |
|---|---|---|
| `epi` | `epimetheus` | `192.168.1.5` |
| `framework` | `framework` | `192.168.1.37` |

The live topology was verified on 2026-07-31:

| Object | Fixed identity | Required state |
|---|---|---|
| Policy alias | id `9`, `MV_VPN_IPS` | target IP temporarily added/removed |
| VPN pass rule | id `35` | enabled; source `MV_VPN_IPS`; gateway `AIRVPN_US_PREFERRED` |
| Kill switch | id `36` | enabled; source `MV_VPN_IPS`; block to `any` |
| US gateway | `AirVPN`, interface `opt5` / `AIRVPN_US` | online; Los Angeles primary |
| Direct gateway | `WAN_DHCP` | normal post-rollback path |

`AIRVPN_US_PREFERRED` uses the USA tunnel first and Netherlands only as failover. A successful operation requires live egress verification to report country `US`; configured policy alone is not proof of a US IP.

Do not use `MV_VPN_SG_IPS`, rules 37/38, or gateway `AirVPN_SG`: those names are historical and currently describe the Netherlands path, not the requested US path.

## When to Use

Use immediately, without a clarification round, for requests such as:

- "put epi on the US VPN"
- "give framework a new US IP"
- "VPN epi"
- "roll epi back"
- "take framework off the VPN"

Do not use for permanent VPN membership, servers, containers, inbound port forwards, a country other than the US, or changing the VPN endpoint itself. Load the full `pfsense` skill for those jobs.

## Authorization and Scope

A direct enable or rollback request authorizes only:

1. reading pfSense overview, alias 9, and rules 35/36;
2. changing only the selected workstation's membership in alias 9;
3. applying the firewall configuration;
4. read-only verification.

Do not request another confirmation. Do not change rule state, rule order, gateways, tunnels, NAT, DHCP, DNS, Nix configuration, or any other alias member. Never flush the firewall state table.

The ordinary `MV_VPN_IPS` → Nix mirror contract applies to permanent membership. This workflow is a deliberate temporary exception: do not add `.5` or `.37` to `hosts/doc2/configuration.nix`; rollback must remove the temporary member. If the user asks to keep it permanently, stop using this skill and follow the full `pfsense` workflow including Nix sync.

## Fast Preflight

For epimetheus, make the host ready before touching pfSense:

```sh
wakeonlan 18:c0:4d:65:86:e8
ssh -o BatchMode=yes -o ConnectTimeout=3 abl030@192.168.1.5 true
```

After Wake-on-LAN, retry SSH every 5 seconds for at most 90 seconds. Framework
has no wake fast path; require it to be online. Record all timestamps with
`date --iso-8601=seconds`; never invent or trust model-generated dates.

Run these four read-only pfSense MCP calls in parallel. Do not list the whole firewall or alias collection.

1. `pfsense_get_overview`
2. `pfsense_get_firewall_alias id=9`
3. `pfsense_get_firewall_rule id=35`
4. `pfsense_get_firewall_rule id=36`

Proceed only when all of these are true:

- alias 9 is named `MV_VPN_IPS` and is type `host`;
- rule 35 is enabled, passes source `MV_VPN_IPS` to gateway `AIRVPN_US_PREFERRED`;
- rule 36 is enabled and blocks source `MV_VPN_IPS` to `any`;
- gateway `AirVPN` is online.

If any identity differs, stop and report the exact mismatch. Do not search for replacement IDs or improvise. The fast path is intentionally fail-closed so stale documentation cannot rewrite the wrong object.

The alias `address` and `detail` arrays are parallel arrays. Preserve every existing pair, including blank details and IPv6 entries, exactly as returned. Never repair unrelated alias/Nix drift during a temporary toggle.

## Enable: Direct WAN → US VPN

Given the selected target IP and canonical name:

1. Start from the live alias-9 arrays returned by preflight.
2. If the target IP is absent, append exactly one pair:
   - address: target IPv4 from the fixed host table;
   - detail: `TEMP US VPN: <canonical-name>`.
3. If the target IP is already present, do not duplicate it; continue to verification.
4. Call `pfsense_update_firewall_alias` with:
   - `id=9`
   - the complete resulting `address` array
   - the complete resulting `detail` array
   - `confirm=true`
5. Call `pfsense_firewall_apply confirm=true`. Live alias changes normally
   report `applied=false` with pending alias work on the first call; immediately
   call apply once more. Treat the second successful apply as the happy path,
   not an error investigation.
6. Re-read alias 9 and require the target IP exactly once while every pre-existing address/detail pair remains unchanged.

Do not touch rules 35/36: they are already enabled and provide both policy routing and the kill switch.

### Egress proof

Prove the result from the selected workstation, not from doc1 or pfSense. Prefer a fresh IPv4 request:

```sh
ssh -o ConnectTimeout=3 abl030@<target-ip> \
  'curl -4fsS --max-time 10 -H "Cache-Control: no-cache" "https://ipinfo.io/json?ts=$(date +%s)"'
```

Require the response's `country` to equal `US` and report the returned public IP. If SSH is unavailable because the workstation is asleep or local SSH access is disabled, report that the pfSense policy is enabled but egress is not yet verified, and give the user this exact local command:

```sh
curl -4fsS https://ipinfo.io/json | jq '{ip,country,region,city}'
```

Do not claim a US IP from alias membership alone. Existing browser connections may reuse old states; open a fresh private window or restart the test application if it still shows the old address. Never flush global states.

If egress is reachable but reports a country other than `US`, immediately run the rollback below for that target and report that the US gateway did not deliver US egress. Do not leave a misleading non-US VPN path active.

## Rollback: US VPN → Direct WAN

Rollback is always safe and idempotent.

1. Run the same four-call fast preflight.
2. Start from the live alias-9 `address`/`detail` pairs.
3. Remove every pair whose address equals only the selected target IP. Preserve all other pairs byte-for-byte and in their current order.
4. Call `pfsense_update_firewall_alias` with `id=9`, the complete reduced arrays, and `confirm=true`.
5. Call `pfsense_firewall_apply confirm=true`; retry once only if pending subsystems are reported.
6. Re-read alias 9 and require the selected target IP to be absent while all unrelated pairs remain unchanged.
7. From the workstation, run a fresh `ipinfo.io` request. Require country `AU` for direct WAN and report the public IP. If the host is unavailable, say rollback is configuration-verified but egress is not yet host-verified.

Never remove both workstation IPs unless the user explicitly requested both. Never replace alias 9 with a memorized static list.

## Complete Reversible Test

When the user asks to test the skill or model, optimize for one safe cycle and
always finish on direct WAN:

1. Wake/SSH-check the target and prove fresh baseline `AU` egress. Every egress
   request in this workflow must run through SSH on the target IP; never run
   `ipinfo.io` locally on doc1. Use this exact shape for baseline, US proof, and
   AU rollback proof:

   ```sh
   ssh -o BatchMode=yes -o ConnectTimeout=3 abl030@<target-ip> \
     'curl -4fsS --max-time 10 -H "Cache-Control: no-cache" "https://ipinfo.io/json?ts=$(date +%s)"'
   ```

2. Run the four-call preflight once and retain the exact initial alias pairs and
   rule values.
3. Enable, apply (including the expected retry), then in parallel re-read alias
   9 and prove fresh `US` egress.
4. In a mandatory cleanup/finally path, use the just-verified live alias result
   to remove only the target. Do not repeat the four-call preflight during the
   same uninterrupted cycle.
5. Apply (including the expected retry), then in parallel re-read alias 9 and
   prove fresh `AU` egress.
6. Require the final alias pairs to equal the initial pairs exactly and rules
   35/36 to remain untouched. Stop; do not add redundant agent or parent
   verification passes.

This complete-cycle path is the speed target. Standalone rollback still uses
the normal preflight because it may run in a fresh session.

## Failure Recovery

- Alias update failed before apply: re-read alias 9 and report live state; do not retry from stale arrays.
- Apply returned pending: retry apply once, then re-read alias 9.
- Verification failed after enable: rollback the selected target automatically.
- Verification failed after rollback: re-read alias 9. If the target is absent, configuration rollback succeeded; report that old client states or host networking may still be in use.
- pfSense MCP/API unavailable: stop. Never SSH or shell into pfSense.
- Concurrent alias change detected: re-read alias 9, recompute from the new arrays, and retry once. Abort rather than clobbering another member.
- Whole-config history audit conflict: this narrow temporary-alias workflow is
  explicitly MCP-only. Initial/final alias-pair equality plus untouched fixed
  rules is its blast-radius audit; never invoke pfSense shell paths.

## Completion Format

Keep the response to one compact status block:

```text
<epi|framework>: US VPN enabled | direct WAN restored
Policy: alias 9 + rules 35/36 verified
Egress: <public-ip>, <country/region> | unverified (host offline)
Rollback: say "roll <host> back" | complete
```

## Common Pitfalls

1. Looking up host IPs even though they are fixed above.
2. Using stale `MV_VPN_SG_IPS` instructions and landing in the Netherlands.
3. Pasting a hardcoded copy of alias 9 and deleting unrelated members.
4. Letting `address` and `detail` lengths diverge.
5. Changing Nix for a temporary test or failing to remove the temporary member afterward.
6. Claiming success from configuration without proving workstation egress.
7. Flushing all firewall states to force an immediate browser change.

## Verification Checklist

- [ ] Correct fixed workstation IP selected
- [ ] Alias 9 and rules 35/36 identities match preflight invariants
- [ ] USA gateway is online before enable
- [ ] Only the selected alias member changed
- [ ] Firewall apply completed
- [ ] Alias state re-read after apply
- [ ] Fresh workstation egress reports `US` after enable or `AU` after rollback, or is explicitly labeled unverified
- [ ] Failed non-US enable was automatically rolled back
