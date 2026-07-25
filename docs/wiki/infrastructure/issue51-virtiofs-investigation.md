# Issue 51 investigation summary: nested virtiofs, and the doc1 panic

**Date:** 2026-07-25
**Status:** slskd fault solved and reproduced; doc1 panic unreproduced, capture now armed
**Issues:** [#51](https://git.ablz.au/abl030/nixosconfig/issues/51) (investigation), [#53](https://git.ablz.au/abl030/nixosconfig/issues/53) (database-state virtiofs exit)
**Detail pages:** [virtiofs-nested-reexport-stale-pins.md](virtiofs-nested-reexport-stale-pins.md),
[fleet-crash-capture.md](fleet-crash-capture.md),
[virtiofs-database-state-exit.md](virtiofs-database-state-exit.md)

## What was actually wrong

Three separate problems had been fused into one "virtiofs is unreliable" narrative. They are unrelated.

| # | Problem | Verdict |
|---|---|---|
| 1 | slskd move failures (ENOENT/ESTALE/ENOMEM) | **Solved and reproduced** |
| 2 | doc2 wedge, 2026-07-24 | **Cause ruled out; true cause uncaptured** |
| 3 | doc1 kernel panic, 2026-07-24 | **Unreproduced; capture now armed** |

### 1. slskd — solved

doc2's re-exporting `virtiofsd` runs `--inode-file-handles=never`, pinning one `O_PATH` descriptor per
inode into `/mnt/virtio`, which is itself a FUSE mount. The trigger is **two-part**:

- an **external writer** replaces a directory in the shared tree, *and*
- the **guest holds a reference** across that replacement.

Either alone is harmless — which is why only some albums ever failed. With both, everything through the
retained reference returns ESTALE permanently, while the same path resolves fine by name. That is the
incident's central paradox ("the directory was visibly there the whole time").

Reproduced end-to-end in the lab, full production topology, 6/6 replaced directories failing with
controls clean. Onset is coeval with `a73909c6`/`c604cc8f` (2026-07-19) — a six-day regression, not a
chronic condition. Failure rate ran 37–96% of completed downloads per day and dropped to 0% the moment
`microvm-virtiofsd@slskd` was restarted at 18:47 on 2026-07-24.

The original slskd fix options remain in #53. Re-exporting virtiofs is unsound
in **both** `--inode-file-handles` modes, so flipping the flag is not a fix;
the nest has to go. The subsequent storage audit widened #53 to cover the
larger production problem: all nine doc2 nspawn databases also sit on direct
virtiofs. Corrected low-QD and same-filesystem controls now favor an
unprivileged doc2 LXC with direct host dataset binds as the architecture to
prototype; dedicated VM block disks remain the fallback.

### 2. doc2 wedge — misattributed

The issue recorded this as "virtiofs pressure generated inside doc1 took down doc2". Its own preserved
`doc2-ps.json` shows **64 of 65 D-state tasks in `tty_open`**, one in `msleep`, and **zero in any FUSE
or virtiofs path**. Victims were ordinary timer-driven units (`deep-probe-*`, `sanoid`) whose PIDs match
exactly; each timer firing added another blocked task, which is why load reached 65 with **zero memory
PSI and 18 GiB free**. doc2's kernel log is empty across the whole window.

The outcome (both guests lost) is real. The propagation mechanism is unestablished and lives in the TTY
layer. It could not be closed because only WCHAN was captured — enough to name the layer, never the
lock holder.

### 3. doc1 panic — unreproduced

Attempted at full parity in an isolated lab (VM 951 + 952, own dataset, never `/mnt/virtio`):

| | doc1's fatal run | lab |
|---|---|---|
| Kernel | 6.18.38 | identical |
| vCPU | 30, one guest | 15 + 15, two guests |
| virtiofsd flags | `prefer`, `announce-submounts`, `modcaps` | byte-identical |
| Backing | `nvmeprom/containers` | `nvmeprom/issue51-virtiofs-lab` — same pool, same NVMe |
| Guests sharing it | doc1 + doc2 | 951 + 952, separate virtiofsd |
| Cached inodes | doc2 ≈ 1,507,956 | **1,863,925 each** |

**9.6M metadata operations, 35 minutes — past doc1's ~28-minute fatal point. Zero filesystem errors,
zero kernel messages, both guests survived.** The netconsole log stayed byte-identical from boot.

Then repeated **on doc1 itself, against production `/mnt/virtio`**, at exact parity — same host, same
storage, same 24 workers / 3 walkers, same 30 vCPU, same kernel — with kdump and netconsole armed:

| | 2026-07-24 fatal run | 2026-07-25 repeat |
|---|---|---|
| Outcome | panic at ~14M ops, ~28 cumulative min | **14.64M ops, 55 continuous min, nothing** |

Zero genuine violations, and the netconsole log was **byte-identical to its baseline for the entire
run** — not one kernel event. doc2 stayed at 0 D-state tasks and slskd at 0 failures throughout.

Every remaining difference from the fatal run — production dataset, single guest with 30 vCPU,
concurrent production load — has now been eliminated. **The "virtiofs metadata load kills the guest
kernel" hypothesis is not supported.** The load was a bystander on 2026-07-24, not the cause.

doc2 also stayed healthy this time, which fits the finding above: its wedge was tied to doc1 *dying*,
not to I/O pressure. doc1 never died here, and doc2 never wedged.

### Capture is proven, not assumed

Before the real run, doc1 was deliberately panicked with `sysrq-c` to test the pipeline end to end. It
produced a full backtrace on prom (`sysrq_handle_crash+0x1a/0x20`, `Kdump: loaded`) and a 1.86 GB
vmcore, and doc1 self-rebooted and re-armed.

That test paid for itself immediately: the save service wrote a **0-byte** `dmesg-*.txt`, because plain
`dmesg` in a kexec capture kernel reads *that* kernel's freshly-booted ring buffer rather than the dead
one. Fixed to use `vmcore-dmesg(8)`. Without the test, the cheap-to-read artifact would have been empty
on the real panic — the same class of failure as 2026-07-24, discovered too late.

## Things that turned out to be wrong

Recorded because each cost time and would cost it again.

- **The harness's "violations" are always shutdown artifacts.** Every violation in every run — original
  and lab — was `BrokenPipeError`/`ConnectionResetError` from its own multiprocessing manager at stop.
  The in-run counter read `violations: 0` throughout. Check the counter, not the log lines.
- **The O_PATH probes initially overstated their reach.** They demonstrated the primitive; the first
  end-to-end attempt through a real virtiofsd found **nothing**, because re-opening by full path lets
  `cache=auto` expire and re-LOOKUP. The held reference is the missing ingredient.
- **IOPS decay is not accumulated state.** Same virtiofsd process, same guest kernel, **90 seconds
  idle** → throughput went 3,745 → 6,900 and held. Accumulated state cannot recover from an idle. It is
  ZFS write-throttle backpressure; mid-decay the dataset held 333 files, virtiofsd 31 fds, guest cache
  12,627 inodes. Nothing was growing.
- **More workers give fewer IOPS** (4 → 6,465; 24 → 5,040; 64 → 3,770). The ceiling is contention, not
  guest CPU. So "we could not push hard enough" does not rescue the E1 negative result.
- **netconsole was never broken.** `0B in` on the receiver is normal: the fleet boots `loglevel=4`, so
  only KERN_ERR and above reach any console. Verified by emitting `<2>` (arrives) and INFO (correctly
  dropped, zero packets under tcpdump).
- **doc2's I/O pressure is not nvmeprom.** It is `kopia-verify-mum` blocking on a remote NFS-over-
  Tailscale mount — **99.8%** of doc2's I/O stall, with every other cgroup near zero. Using doc2's
  aggregate I/O PSI as a guard against lab load on nvmeprom measures the wrong disk. Guard on
  `zpool iostat -l nvmeprom` and doc2's cgroup pressure **excluding** that verify.
- **The #267 fd-exhaustion path is already closed on prom.** At 1.86M guest cached inodes the lab
  virtiofsd held under 40 fds, because prom runs `--inode-file-handles=prefer`. Only doc2's *nested*
  daemon, forced to `never`, still pins.

## What changed in the repo

- `modules/nixos/services/crash-capture.nix` — netconsole sender on every non-container host (doc1 had
  **none**, which is why its panic frames were lost), plus opt-in kdump with save-then-reboot, a
  free-space guard, and assertions for LXC/WSL.
- `modules/nixos/services/doc2-recovery.nix` — now collects `sysrq-w`/`sysrq-t`, post-sysrq `dmesg` and
  D-state `/proc/<pid>/stack` over QGA, which stays responsive in these wedges while SSH is dead.
- `scripts/issue51/` — the three O_PATH probes (they refuse to run under `/mnt/virtio`).
- `scripts/issue51/l2-lab/` — the nested-seam lab: guest definition, harness, launcher, and a README of
  the gotchas that cost time.

## Lab state

VM 951 (`192.168.1.157`) and 952 exist on prom with their own dataset `nvmeprom/issue51-virtiofs-lab`,
kdump armed, netconsole → prom (`vm951-netconsole-recv` → `/var/log/vm951-netconsole.log`), and narrowly
scoped host firewall rules for those two source addresses. The lab VM's **serial socket does not deliver
to a reader** — use netconsole.

## Open

- #53: move production database/hot mutable state off virtiofs. Prototype doc2
  as an unprivileged LXC with direct host dataset binds; retain tuned VM block
  storage as the fallback. The slskd nested-share decision remains related but
  is no longer the issue's primary scope. See
  [virtiofs-database-state-exit.md](virtiofs-database-state-exit.md).
- doc1 panic: cause unknown, but the load hypothesis is falsified. Capture is armed and proven, so a
  recurrence produces the backtrace this campaign
  could not manufacture.
- doc2 wedge: needs `sysrq-t` from a live recurrence.
- `deep-probe-kopia-mum-*` fails when its 250 s curl timeout collides with the 5–6 hour verify window;
  13 failures since 2026-07-21. Raise the timeout or gate the probe against the verify.
