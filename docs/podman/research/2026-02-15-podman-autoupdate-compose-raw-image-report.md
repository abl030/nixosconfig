Podman Auto-Update Failures With Compose-Managed Containers on NixOS
Executive summary and conclusion

Your observed failure (locally auto-updating container "<id>": raw-image name is empty) is best explained as a Podman implementation gap/bug in the Docker-compatible (“compat”) container create API path, which is the path used by podman compose when it delegates to docker-compose / docker compose as provider.

In Podman 5.7.1, podman auto-update hard-requires that ctr.RawImageName() be non-empty; if it is empty, Podman records an error and skips the container. However, the compat API CreateContainer handler in 5.7.1 does not set SpecGenerator.RawImageName, which is the record needed for ctr.RawImageName() later. As a result, containers created through this API path can have a valid ImageName/Config.Image but still have empty RawImageName, which reliably breaks podman auto-update.

This is also explicitly reported upstream as a bug for docker-compose/API-created containers (issue #19688).

Conclusion: this is not intended “working as designed” behavior for the compose-managed lifecycle + Podman auto-update combination; it is a known incompatibility stemming from an incomplete implementation in the Docker-compat API create path, and it is still present in the v5.7.1 source shown below.

Confidence: High for root cause (directly supported by 5.7.1 source + upstream bug report).
Confidence: Medium for “fixed in later versions” status (I did not find evidence of a fix in available release notes, and the relevant 5.7.1 code path still exists).
What exactly fails and why it fails
Auto-update requires RawImageName and errors if it is empty

In Podman 5.7.1, auto-update builds a task list over running containers with io.containers.autoupdate set. It reads rawImageName := ctr.RawImageName() and immediately errors out if it is empty, producing the exact message you see.

This is not an incidental log string—RawImageName is used as the image reference for (a) checking digests and (b) pulling updates; the task logic stores it as task.rawImageName and uses it to parse registry references and to pull.

Podman’s own spec generator data model documents the intent: RawImageName is the user-specified, unprocessed image input, and while “optional”, it is “strongly encouraged” when Image is set—specifically because workflows like auto-update need the exact original reference.
Why compose-managed containers tend to have empty RawImageName

podman compose is not a native compose engine; it is a thin wrapper that executes an external provider (typically docker-compose / docker compose), wiring it to the local Podman socket. By default, if docker-compose is installed, it takes precedence.

When the provider is Docker Compose, container creation goes through Podman’s Docker-compat (“compat”) API.

In Podman 5.7.1, the compat CreateContainer handler:

    normalizes the image name (NormalizeToDockerHub),
    looks up the image,
    then creates a SpecGenerator using either the image ID or a resolved name, but never sets SpecGenerator.RawImageName.

Because SpecGenerator.NewSpecGenerator() sets only ContainerStorageConfig.Image (not RawImageName), RawImageName remains unset unless a higher layer explicitly populates it.

So you get the exact mismatch you reported:

    podman inspect shows an image name in several places (e.g., normalized image name),
    but RawImageName (the “original user input”) can still be empty,
    and podman auto-update fails.

This is confirmed by the upstream bug report for docker-compose/API-created containers: “Looks like rawImageName is only set in CLI and play but not in API handler.”
Bug vs design vs edge-case and version behavior
Classification

Bug / implementation gap (most accurate):

    Auto-update requires RawImageName and fails without it (documented by 5.7.1 code).
    The Podman compat API CreateContainer handler does not set RawImageName in 5.7.1 (documented by 5.7.1 code).
    The SpecGenerator model strongly encourages setting RawImageName when Image is set (documented in the model comment).
    Upstream issue #19688 identifies the exact mismatch and is labeled as a bug.

Not “intended behavior”: the spec generator explicitly frames RawImageName as important for exact user input, and the issue report expects parity with CLI-created containers.

Edge-case limitation (secondary framing): Podman also enforces fully-qualified references for registry-based update, because if containers are created from IDs, Podman cannot know which registry reference to check/pull. This is explicitly documented in Podman’s systemd/quadlet unit docs.
However, your case is not “image ID used intentionally”; it is a missing metadata field despite having a usable image name elsewhere.
Does podman compose fail to populate RawImageName “by design”?

If podman compose is using Docker Compose (docker-compose) as provider (the default behavior when installed), it is essentially routing creation through the compat API handler, which in 5.7.1 visibly does not populate RawImageName.

That makes the observed behavior an implementation gap/bug in Podman’s compat API path, not a deliberate “compose must not support auto-update” design choice.
Versions affected and fixed

Directly evidenced as affected

    Podman 5.7.1: compat CreateContainer handler does not set RawImageName; auto-update errors on empty RawImageName.
    Podman 4.6.0 is implicated by the upstream issue reproduction environment, and the reported symptom matches the same missing-field root cause.

Related precedent: fixed elsewhere

    A similar class of bug existed for podman play kube: containers created by podman play kube “did not record the raw image name used to create containers,” and this was later fixed (documented in release notes).
    This supports the interpretation that “missing RawImageName breaks auto-update” is a recognized correctness issue, not an accepted limitation.

Fixed for compat compose path?

    I did not find evidence (in the investigated sources) that compat container create now sets RawImageName in a way that would resolve this in 5.7.1. The 5.7.1 code shown still omits it.
    Issue #19688 is closed/locked, but the closure state alone does not demonstrate a fix; the report contains no linked PR in the captured view.

Confidence: Medium that “no fix exists up through 5.7.1 and the current documented behavior you’re seeing”; High that 5.7.1 is affected.
Officially supported update strategies for compose-managed workloads today
What Podman officially supports well: systemd/Quadlet + auto-update

Podman’s systemd integration (via generator / quadlet-style unit definitions) is where Podman auto-update is most “first-class”:

    Podman’s systemd unit documentation includes AutoUpdate= and explicitly ties it to podman-auto-update(1).
    It also documents the fully-qualified image reference requirement for registry auto-update.

Additionally, Podman’s podman-auto-update documentation explicitly references configuring auto-update via quadlet.

For a homelab/single-host environment, the “Podman-native” strategy that aligns with official documentation is therefore:

    Manage containers via Quadlet/systemd units (user units for rootless)
    Set AutoUpdate=registry (or equivalent labels)
    Run podman-auto-update.timer or invoke podman auto-update on a schedule

What Podman officially provides for compose: a wrapper, not lifecycle semantics

Podman documents that podman compose is a wrapper executing an external compose provider and passing through commands/options.

Therefore, “compose-managed updates” are, in practice, the provider’s update workflow—typically:

    podman compose pull
    podman compose up -d (and sometimes --force-recreate, depending on provider semantics)

This is not a Podman-specific claim of guarantee; it follows directly from “podman compose executes another tool and passes the command/args directly.”
Practical implication for your environment

Because the compat create handler in 5.7.1 does not set RawImageName, Podman-native auto-update is not operationally reliable for containers created via docker-compose over the Podman socket.

So, “officially recommended” in the sense of “most supported by Podman docs and implementation” is:

    Use Quadlet/systemd-managed containers for auto-update, or
    Use compose pull + redeploy as your update mechanism when you stay on compose.

Best practices for rootless + systemd + compose in ops
Scheduling and observability with systemd timers

Systemd timers are explicitly designed for time-based activation of services (cron-like scheduling under systemd supervision). For a homelab goal of low-toil + reliable logging, this matters because timer-triggered services:

    run under a consistent unit name,
    emit logs to journald in a centralized way (systemd-managed).

Prefer Podman’s systemd/Quadlet integration for “production-like” stability

Podman’s systemd unit docs emphasize that it supports both system and user units, and that unit generation is integrated into boot/daemon-reload.

Enterprise guidance (RHEL documentation) explicitly positions Quadlet as having “many advantages” over generated unit files and notes Quadlet availability in recent Podman versions (starting with Podman v4.6 in that doc). This is a strong signal that “systemd-native container units” are the long-term-friendly management approach.
Compose in production/homelab: minimize “API impedance mismatch”

Given podman compose defaults to Docker Compose if installed, and Docker Compose uses the compat API path, you should assume “Docker API semantics” apply unless proven otherwise.

When an operational feature depends on Podman-internal metadata (like RawImageName), prefer workflows that create containers through Podman-native code paths (Quadlet/CLI) over Docker-compat code paths. This is an inference supported by the specifically missing RawImageName in the compat handler vs its use in auto-update.
Watchtower in Podman environments
Compatibility and maintenance status

Watchtower’s documented operating model is to run as a container which must mount the Docker socket because it “needs to interact with the Docker API.”

There are long-running upstream Watchtower discussions requesting Podman support because Watchtower expects /var/run/docker.sock and Docker API behavior.

More importantly for 2026 operational decision-making: the upstream Watchtower repository was archived (read-only) on December 17, 2025, which indicates the original project is no longer actively maintained in its upstream home.
Risk profile compared to Podman-native approaches

Based on Watchtower’s requirement to mount a privileged control socket for the container runtime (Docker API socket), Watchtower inherently expands the blast radius of a compromise of the Watchtower container (general socket-mount risk). This is a security inference from the documented requirement to mount the control socket.

Podman’s preferred path for automatic updates is integrated with systemd/quadlet (AutoUpdate=) and podman auto-update, which avoids introducing an additional third-party controller container.
Bottom line

For Podman environments in 2026, Watchtower is generally redundant at best and risky at worst, and the archival of the upstream repo materially increases operational risk.

Confidence: High that Watchtower relies on Docker API socket mounting; High that upstream repo is archived; Medium that it is “not recommended” for Podman specifically (because some people run it against Podman’s Docker-compat socket, but you inherit both compatibility gaps and a now-archived upstream).
Remediation options, decision matrix, and a rollout plan
Can missing raw image metadata be repaired in place?

Practically, treat this as not repairable in place.

Podman’s internal container config states the container configuration “may not be changed once created” and is stored read-only in state; changes are not written back and can cause inconsistencies.

Since podman auto-update uses ctr.RawImageName() and fails when empty, the remediation is to ensure new containers are created with RawImageName populated, rather than trying to mutate existing containers.

Confidence: Medium-high (based on Podman internal documentation + behavior), but note this is based on upstream code comments rather than a “supported admin API” statement.
What “creation paths” will populate RawImageName?

From the upstream bug report perspective, RawImageName is “set in CLI and play but not in API handler.” In your case, this implies:

    Docker-compat API path (docker-compose / docker compose provider): does not set it in 5.7.1.
    Podman-native creation paths: are expected to set it (at least in the cases called out by upstream), and Podman historically fixed missing-raw-image-name issues in other command paths (e.g., play kube).

Decision matrix
Option	Reliability in real ops	Operational complexity	Downtime risk	Security posture	Notes / key tradeoffs
Stay on podman auto-update + wait for fix	Low (for docker-compose/compat-created containers) 	Low (no changes)	Low (but you’re not updating)	Good (Podman-native)	You will keep getting “raw-image name is empty” until containers are created with RawImageName populated or Podman changes compat handler.
Recreate containers under a path that sets required metadata	Medium–High (if you truly move off compat create) 	Medium	Medium (recreate events)	Good	Requires changing how containers are created (e.g., Quadlet or Podman-native create path). Container config is not meant to be mutated in place.
Replace with pull/redeploy script per stack (podman compose pull && up -d)	High (most predictable) 	Medium (per-stack timers/scripts)	Medium (depends on restart strategy)	Good	Uses compose provider semantics; avoids RawImageName entirely. Works even when compat path can’t support auto-update.
Use Watchtower	Low–Medium (depends on compat/socket behavior) 	Medium	Medium	Worse (socket-mount controller) 	Upstream is archived/read-only as of Dec 17, 2025, increasing long-term risk.
Recommended operational path for a homelab

Given your stated priorities (“low toil, high reliability”) and the demonstrated incompatibility between auto-update and compat-created containers, the most pragmatic approach is:

    Short term: move to per-stack pull + redeploy under systemd timers (option 3).
    Medium term: migrate “important” stacks to Quadlet/systemd units with AutoUpdate=registry (Podman-native path), so you can use Podman’s supported auto-update model without compose/provider edge cases.
    Avoid: Watchtower, unless you accept the security tradeoff and the archived-upstream risk.

Confidence: High for “option 3 works around the RawImageName failure”; Medium-high for “Quadlet migration is the best-aligned long-term strategy.”
Practical rollout plan with rollback
Preparation phase

Create an inventory report that lets you separate:

    containers that can be auto-updated today vs those that cannot, and
    which stacks are impacted.

Example checks (illustrative commands):

    Identify containers with the autoupdate label
    Ensure RawImageName is populated (this is the key failure point)
    Confirm PODMAN_SYSTEMD_UNIT label is set where you expect

This is justified because 5.7.1 auto-update will otherwise fail at task-assembly time.
Phase one: stabilize updates via compose redeploy

For each stack:

    Create a systemd .service that runs the external compose provider command you already rely on (podman compose ...). This leverages the fact that podman compose simply passes through to the provider you have installed.
    Create a matching .timer with an OnCalendar= schedule. Systemd timers are explicitly intended for time-based activation.
    Implement an update routine:
        podman compose pull
        podman compose up -d
        (Optionally include provider-specific flags to reduce downtime or force recreation, depending on your provider’s behavior—this is provider-defined since podman compose delegates.)

Rollback strategy:

    If the update breaks functionality, revert the compose file to the prior image tag/digest and run podman compose up -d again.
    Because this is compose-driven, rollback is tied to your compose configuration and image tagging policy, not to Podman auto-update state. (This is an operational inference based on compose delegation.)

Phase two: migrate high-value stacks to Quadlet auto-update

For the stacks where you most want Podman-native auto-update:

    Convert the stack from compose to Quadlet/systemd units (container or pod units as appropriate). Podman documents this systemd integration and AutoUpdate= in podman-systemd.unit(5).
    Use fully-qualified image references when using AutoUpdate=registry, per the Podman systemd unit documentation.
    Enable Podman’s update timer or schedule podman auto-update using a systemd timer (the latter is consistent with systemd’s model).

Rollback strategy:

    Keep a known-good image tag available and ensure your systemd unit can be reverted to it; Podman auto-update also has explicit rollback logic in its implementation when Rollback is enabled (as seen in code).

Decommission phase

Once you have either:

    moved the stack to Quadlet, or
    accepted compose redeploy as your update mechanism,

you should remove io.containers.autoupdate=registry from containers that are still created via the compat compose path, because it will produce persistent update errors and noise. This follows from the documented failure mode in 5.7.1.
