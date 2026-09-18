# Fermecraft tank metrics

- **Date:** 2026-09-18
- **Status:** OPC UA access proved end to end through a temporary,
  laptop-source-pinned SiteManager forwarding rule. Metrics collection design is
  next; no collector service or permanent VLAN has been deployed.
- **External coordination:** Cullen IT will create the permanent UPLINK VLAN and
  SonicWall policy. Fermecraft controls the SiteManager/GateManager configuration.

## Purpose

Collect tank wine temperature and cooling-solenoid state so Cullen can measure
valve-on duration, compare relative tank cooling efficiency, and model thermal
performance without buying a FermeCloud historian subscription.

The Siemens PLC exposes anonymous, read-only OPC UA on `10.60.0.1:4840`. The
required values are under `Vessel Storage`; the verified node IDs for tank 1 are:

```text
ns=3;s="Vessel Storage"."T001"."Temperature 1"
ns=3;s="Vessel Storage"."T001"."Valve 1"
```

The same pattern exists through `T040`. Forty nodes being present does not mean
forty tanks are active or instrumented: the commissioning browse returned zeros,
negative values, and implausibly cold readings for several tanks, all with OPC UA
status `Good`. The collector must preserve raw values and quality, while the
analytics layer separately decides whether a tank is active and physically
plausible. It must not silently treat zero or `Good` as proof of a valid sensor.

## Observed topology

Tom's description of an unmanaged control network is correct on the DEV side,
but incomplete at the Cullen boundary. A Secomea SiteManager 1549 separates the
two networks:

```text
Cullen LAN (192.168.100.0/24)
  |
  | SiteManager UPLINK: 192.168.100.119
  v
Secomea SiteManager 1549 (firewall/NAT boundary)
  |
  | DEV1: 10.60.0.101/24
  v
Unmanaged control switch
  +-- Siemens PLC: 10.60.0.1:4840
  +-- HMI and other Fermecraft equipment
```

The SiteManager is connected to Fermecraft's GateManager service and already has
agents for the PLC, HMI, remote HMI access, another control device, and Layer-2
discovery. The new OPC UA forward uses the sixth of ten available agent slots;
the five existing agents were not changed.

The SiteManager administration UI is currently reachable from its UPLINK side
and still accepts its factory-default local credential. The credential is
deliberately not recorded here. Change it in coordination with Fermecraft, and
do not copy it into the repository, a ticket, shell history, or collector
configuration.

## Current temporary access path

SiteManager agent `#05`, named `OPCUA-Forward`, is active with this exact rule:

```text
UPLINK*:TCP:192.168.100.128:4840>>DEV1:10.60.0.1
```

This means:

- only the Cullen Windows/WSL laptop at `192.168.100.128` may originate the
  connection;
- clients connect to `opc.tcp://192.168.100.119:4840`;
- the SiteManager forwards that TCP connection to `10.60.0.1:4840` on DEV1;
- the rest of `10.60.0.0/24` is not routed or exposed; and
- no SiteManager source-translation, whole-subnet routing, or all-ports agent is
  enabled.

This is a temporary design and not a substitute for the VLAN. Source-IP pinning
limits accidental access, but every ordinary Cullen client still shares the
SiteManager's current UPLINK broadcast domain, and OPC UA itself is anonymous.

### End-to-end proof

Before the rule existed, TCP connection to `192.168.100.119:4840` was refused.
After saving it:

- TCP `4840` connected from `192.168.100.128`;
- an anonymous OPC UA session connected through the UPLINK address;
- `T001/Temperature 1` read approximately `16.4` with status `Good`;
- `T001/Valve 1` read `false` with status `Good`; and
- a negative control from another Cullen client (`192.168.100.111`) timed out,
  proving the source restriction is enforced on the wire.

The direct commissioning test also connected Framework to the unmanaged DEV
switch with temporary address `10.60.0.150/24`, reached the PLC at sub-millisecond
latency, opened TCP `4840`, and browsed the live namespace. Framework is not part
of the permanent path and does not advertise the control subnet over Tailscale.

Quick positive probe from the pinned laptop:

```bash
nc -vz -w 5 192.168.100.119 4840
```

Do not broaden the source address merely to make this probe work from another
machine. Update the intended collector identity deliberately.

### Rollback

Delete SiteManager agent `#05` (`OPCUA-Forward`). That removes the only new
forwarding rule and returns UPLINK port `4840` to its previous closed state. Do
not modify or renumber agents `#00` through `#04` during rollback.

## Permanent network design

Cullen IT will place only the SiteManager UPLINK in a dedicated VLAN. The PLC,
DEV ports, and unmanaged control switch remain untouched.

```text
approved collector on Cullen LAN
  |
  | SonicWall: exact source -> SiteManager:4840 only
  v
dedicated SiteManager UPLINK VLAN
  |
  v
SiteManager forwarding agent -> DEV1 PLC:4840
```

Required controls:

1. Create the VLAN and gateway interface on the SonicWall.
2. Carry it tagged between SonicWall and UniFi, and configure the SiteManager
   UPLINK switch port as an untagged access port in that VLAN.
3. Give the SiteManager a stable UPLINK address using IT's normal reservation or
   static-address process. Obtain its interface identity live during the change;
   do not publish it as a credential surrogate.
4. Default-deny traffic between the VLAN and Cullen networks.
5. Permit only the chosen collector source to the SiteManager UPLINK address on
   TCP `4840`. Administration HTTPS needs a separate, narrower management rule.
6. Preserve the SiteManager's required outbound GateManager, DNS, and time
   access. Moving UPLINK interrupts Fermecraft remote support until those flows
   work, so coordinate the cutover with Tom.
7. Re-test GateManager status, existing agents, the OPC UA forward, the positive
   collector path, and a negative source after the move.
8. Change the factory-default SiteManager local credential and store the new
   secret outside this public repository.

Do not put the laptop itself into the SiteManager VLAN. It should remain on the
normal Cullen network so the SonicWall sees and enforces the routed policy.

## Collector design requirements

The first implementation will run from the pinned Cullen laptop while the VLAN
request proceeds. Treat that as a prototyping boundary, not a durable host
decision. Before moving the collector, update both the SiteManager rule and the
SonicWall rule to the new exact source; never leave the old pinhole as a spare.

The collector should:

- use OPC UA reads or subscriptions only; never request writes;
- cover `Temperature 1` and `Valve 1` for the deliberately selected tank set;
- retain source timestamp, receipt timestamp, OPC UA status, raw temperature,
  and raw valve state;
- calculate valve-on duration from timestamped transitions, explicitly marking
  gaps rather than assuming the last state persisted through an outage;
- retain raw data independently of later efficiency-model assumptions;
- expose freshness, connection failure, missing-node, and implausible-reading
  health signals; and
- make tank activation/sensor-validity metadata explicit rather than inferring
  it from the existence of `T001` through `T040`.

Sampling/subscription cadence, storage destination, retention, dashboarding,
active tank inventory, and the eventual durable collector host remain design
decisions for the implementation session.

## References

- <https://kb.secomea.com/docs/basic-port-forwarding-setup>
- <https://kb.secomea.com/docs/forwarding-and-routing-scada-agents-on-sitemanager>
