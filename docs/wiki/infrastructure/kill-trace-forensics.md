# Attributing a SIGKILL: `homelab.killTrace`

**Date:** 2026-08-22 · **Status:** live on doc1 · **Module:** `modules/nixos/services/kill-trace.nix` · **PRs:** [#175](https://git.ablz.au/abl030/nixosconfig/pulls/175), [#176](https://git.ablz.au/abl030/nixosconfig/pulls/176)

## Symptom

`user@1000.service` on doc1 died at 16:54:09, taking the durable tmux server,
every `claude` process and the hermes gateway with it. From the operator's seat
it looked identical to the familiar 55-minute idle reap
([tmux-durable-idle-reap.md](tmux-durable-idle-reap.md)) — a tmux pane and an
agents view simply vanished ~43 min after a fresh boot.

```
systemd[1]: user@1000.service: Main process exited, code=killed, status=9/KILL
systemd[1]: user@1000.service: Failed with result 'signal'
systemd[1]: user@1000.service: Killing process 1507 (dbus-broker-lau) with signal SIGKILL
... (the whole cgroup follows)
```

## Why the first RCA could not finish

The journal proves a great deal about what did **not** happen, and nothing at
all about what did.

Ruled out, each with positive evidence:

| Suspect | Evidence it was not this |
| --- | --- |
| logind idle reap (`StopIdleSessionSec=55min`) | Zero `is idle, stopping` records that boot. The reaper logs at info level and stops a *session scope*; the durable tmux server was in `user@1000.service`, which it cannot touch. |
| Kernel OOM killer | `oom_kill` was `0` in `/proc/vmstat` **and** in every cgroup's `memory.events`. The counter is per-boot, and the incident was in that boot. |
| systemd-oomd | Running, but every `ManagedOOM*` property was `auto` with no kill policy, and it logged nothing. |
| earlyoom / nohang | Both `inactive`. |
| A rebuild | `/run/current-system` was untouched since 16:10:55; no `switch-to-configuration` ran. |
| A managed stop | PID 1 never logged `Stopping User Manager for UID 1000`. `Failed with result 'signal'` means an unsolicited death, not a stop request. |

What remains is that some process called `kill(2)` with SIGKILL. PID 1 records
only that its child died by signal 9 — never the sender. Linux does not attribute
signals anywhere by default, so with no audit trail the incident closed
**unattributed**.

One further hint survived: `(sd-pam)` logged `session closed` cleanly ~150 µs
before PID 1 noticed. `(sd-pam)` is forked by the manager and reacts to its
parent's death, so it was not itself signalled. That points at something aimed
at the manager rather than a blanket sweep — but "points at" is not attribution.

## What the module does

Two independent halves, enabled together by `homelab.killTrace.enable`.

### 1. Audit rule

```
-a always,exit -F arch=b64 -S kill,tkill,tgkill -F a1=9 -k sigkill
-a always,exit -F arch=b32 -S kill,tkill,tgkill -F a1=9 -k sigkill
```

Registering a signal-syscall rule also enables the kernel's `audit_signals`
path, which attaches an `OBJ_PID` record naming the **target** to each event.
A single deliberate `kill -9` produces one `----`-delimited event holding all
three of:

```
type=SYSCALL   ... a0=0x8c0e6 a1=SIGKILL ppid=214361 pid=573668
                   auid=abl030 uid=abl030 ses=2
                   comm=bash exe=/nix/store/...-bash-interactive-5.3p15/bin/bash key=sigkill
type=OBJ_PID   ... opid=573670 oauid=abl030 ouid=abl030 oses=2 ocomm=sleep
type=PROCTITLE ... proctitle=/nix/store/...-bash --norc --noprofile -c source /home/abl030/.claude/s
```

- `a0` is the target pid (hex), matching `opid`.
- `auid` and `ses` name the **login session** behind the kill. This is the field
  that actually matters: it separates "a command run inside an agent's shell in
  session 2" from "a system service" (which reports `auid=unset`).
- `PROCTITLE` is the sender's full command line, decoded by `ausearch -i`.

Kernel-originated SIGKILLs (the OOM killer) are **not** syscalls and never
appear here. Their absence is itself evidence, corroborated by the `oom_kill`
counters the capture snapshots.

### 2. On-failure capture

An `OnFailure=` drop-in on each watched unit fires
`kill-trace-capture@<unit>.service` the instant it dies — while the sender may
still be running. It writes to `/var/log/kill-trace/<UTC stamp>-<unit>/`:

| File | Contents |
| --- | --- |
| `summary.txt` | Distilled verdict; also the body of the page |
| `audit-sigkill-interpreted.txt` | `ausearch -k sigkill -ts recent -i` |
| `audit-sigkill-raw.txt` | Same, uninterpreted (for hex `a0` matching) |
| `ps-forest.txt` | Full process forest with `lstart`/`etimes` |
| `systemd-cgls.txt` | Cgroup tree |
| `loginctl.txt` | Sessions and users |
| `memory-and-oom.txt` | `oom_kill` counters, meminfo, per-cgroup `memory.events` |
| `journal-tail.txt`, `kernel.txt` | Surrounding narrative |
| `unit-status.txt`, `failed-units.txt` | systemd state |

Then it pages through the existing RCA/Gotify path so the trap is known to have
sprung.

`summary.txt` splits findings into three sections, most-suspicious first:

1. **SIGKILL aimed at a systemd user manager** — `ocomm="systemd"`. The exact
   fingerprint of this incident.
2. **`kill(-1)` sweeps** — `a0=ffffffff`. See below.
3. **Everything else**, with build noise removed.

## `kill(-1, SIGKILL)` is the sleeper

Measuring the noise floor turned up something worth knowing: of 19 SIGKILL
records in 3 minutes on doc1, 18 were `nix-daemon` tearing down build sandboxes,
and **12 of those were `a0=ffffffff` — `kill(-1, SIGKILL)`**.

`kill(-1, sig)` signals *every process the caller is permitted to signal*. From
a nix builder that is harmless: it runs as `nixbld` inside its own PID
namespace, so the blast is contained. From a process running as uid 1000 it is
not contained — it reaps that uid's entire process tree **including its own
`systemd --user`**, which is precisely the observed failure. Any tool that
"cleans up" with `kill -9 -1`, `pkill -9 -u $USER` or similar will do this.

That is why sweeps get their own summary section rather than being left to be
spotted by eye in a wall of records.

## Two traps found while deploying

**`freq` must accompany any `INCREMENTAL*` flush mode.** It has no NixOS
default, so it renders as `0`, and auditd refuses to start rather than falling
back:

```
auditd[471072]: Error - incremental flushing chosen, but 0 selected for freq
auditd.service: Control process exited, code=exited, status=6/NOTCONFIGURED
```

The failure is quiet in the worst way: `audit-rules-nixos.service` starts fine
and `auditctl -l` shows the rules, so auditing *looks* healthy — but with no
daemon holding the netlink there is no `/var/log/audit/audit.log`, and every
`ausearch` in the capture returns empty at exactly the wrong moment. Check
`systemctl is-active auditd`, never just "switch succeeded".

**The watched unit needs `restartIfChanged = false`.** Adding the drop-in makes
`user@1000.service` a changed unit, and `switch-to-configuration` would restart
it — killing every process it contains and inflicting the very outage the
module exists to explain. nixpkgs pins the same flag on the `user@.service`
template for this reason. Confirmed working: both deploys logged

```
NOT restarting the following changed units: user@1000.service
```

and the manager kept its pre-deploy `MainPID` and start timestamp.

## Cost and blast radius

- ~6 records/min while nix is building, near zero otherwise. Log hard capped at
  `num_logs * max_log_file` = 120 MiB.
- auditd's stock disk-pressure actions include `SUSPEND` and `HALT`; every
  action is pinned to a logging-only response so a full `/var` cannot wedge the
  bastion.
- `failureMode = printk`, never `panic` — a diagnostic must not be able to take
  a host down.
- The capture unit is `NoNewPrivileges` with `ProtectSystem=strict`, writing
  only its own `LogsDirectory`. It deliberately sets **no** `ProtectProc` or
  `ProcSubset`: observing other users' processes is the entire job, and hiding
  them would yield a silently empty capture.

## Reading a capture

```sh
sudo ls /var/log/kill-trace/
sudo cat /var/log/kill-trace/<stamp>-<unit>/summary.txt      # start here
sudo cat /var/log/kill-trace/<stamp>-<unit>/audit-sigkill-interpreted.txt
```

Ad-hoc queries against the live log:

```sh
sudo ausearch -k sigkill -ts recent -i                 # all recent SIGKILLs
sudo ausearch -k sigkill -ts today -i | grep -B4 'ocomm=systemd'
sudo auditctl -l                                       # rules loaded
sudo auditctl -s                                       # enabled / pid / lost
```

## When to widen it

Deliberately SIGKILL-only. SIGTERM is the ordinary service-stop signal and
auditing it would bury the interesting record under thousands of routine ones.
If a future incident shows a clean-exit signature instead of `status=9/KILL`,
add `-F a1=15` rules — a one-line change to `security.audit.rules` in the
module.

To watch another unit, add it to `homelab.killTrace.watchedUnits`. Note that
`audit-rules-nixos.service` carries `ConditionVirtualization=!container`, so
this module is a no-op on LXC guests such as igpu.

## Verification performed

- Controlled `kill -9` resolved end to end: sender pid/comm/exe, `auid`, `ses`,
  target `opid`/`ocomm`, and decoded `PROCTITLE`.
- `systemctl start 'kill-trace-capture@SELFTEST.service'` → `Result=success`,
  all artefacts written, sandbox does not blank the capture. That capture is
  retained under `/var/log/kill-trace/20260822T101649Z-SELFTEST/`.
- Both deploys left `user@1000.service` at its pre-deploy `MainPID` (313827),
  with tmux and hermes untouched.

## Resolved on first fire: 2026-08-23 07:29:33

The trap sprang less than 14 hours after deploy and named the killer outright.

```
OBJ_PID   opid=1285 oauid=abl030 ouid=abl030 oses=1 ocomm=systemd
SYSCALL   a0=0x505 a1=SIGKILL ppid=1285 pid=2604483 auid=abl030 ses=1
          comm=python3.14 exe=/nix/store/...-python3-3.14.7/bin/python3.14
PROCTITLE .../python3 /home/abl030/cratedigger/.claude/worktrees/1241-compl…
```

`a0=0x505` is 1285, `ocomm=systemd` — the user manager. The sender's `ppid`
is **also** 1285: it killed its own parent.

The source is a cratedigger test fixture,
`tests/test_parallel_test_runner.py`, which writes a throwaway test whose body
is:

```python
def test_worker_dies(self):
    os.kill(os.getppid(), signal.SIGKILL)
```

The fixture's intent is documented and reasonable — kill the
`ProcessPoolExecutor` worker to reproduce the `BrokenProcessPool` shape an OOM
produces. The bug is that `os.getppid()` is evaluated **at kill time**, not at
spawn time, and the fixture deliberately runs `count` of these concurrently
(`--jobs count`, default 2), each killing a worker.

The moment one instance's own pool worker exits first, that instance is
orphaned — and `systemd --user` sets `PR_SET_CHILD_SUBREAPER`, so orphans in a
user session reparent to the **user manager**, not to PID 1. `os.getppid()`
then returns 1285 and the fixture SIGKILLs the manager, taking the whole user
session — tmux server, every agent, hermes, dbus — with it.

The audit trail captures both halves of the race 64 ms apart:

```
07:29:33.521  pid=2604461 → opid=2604049 ocomm="python3.14"   (real pool worker)
07:29:33.585  pid=2604483 → opid=1285    ocomm="systemd"      (reparented!)
07:29:33      user@1000.service: Main process exited, code=killed, status=9/KILL
```

This is also the explanation for the original 2026-08-22 incident: same host,
same agent workload, manager PID 1296 that boot. Both were `.claude/worktrees`
cratedigger sessions running the suite.

**Fix belongs in cratedigger, not here**: the fixture must target a PID
captured at spawn time, or refuse to fire when its parent is not the expected
pool worker (compare `/proc/<ppid>/cmdline`). Until then, any run of that
fixture can end the user session.

### What this run taught the module

The prime-suspect section did **not** fire, even though `ocomm=systemd` was
right there. `ausearch -i` prints `ocomm` UNQUOTED while the raw log quotes it,
and the matcher only accepted the quoted form — so the headline finding landed
in the "other senders" bucket instead. Fixed by making the quotes optional;
re-running the corrected matcher against this capture surfaces exactly the one
fatal event.

Also worth knowing: the page came through Gotify, not the RCA webhook. The
capture logged `curl: (7) Failed to connect to 127.0.0.1:8644` — the RCA
endpoint is hermes, which runs *inside* `user@1000.service` and had just been
killed. **The primary alert path is guaranteed dead for exactly this class of
event**, so the Gotify fallback in `negative-alert.nix` is what makes the trap
useful, not a nicety.

Related known gap: the durable tmux server survives the idle reaper but not its
own container; see [tmux-durable-idle-reap.md](tmux-durable-idle-reap.md).
