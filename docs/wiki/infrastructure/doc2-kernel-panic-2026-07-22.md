# doc2 nested Cloud Hypervisor kernel panics — 2026-07-22

**Status:** Mitigation and independent capture/recovery deployed after the second incident. The root-cause statement below is a falsifiable, high-confidence hypothesis, not a proven upstream code-level cause.

## Impact and timeline

- **2026-07-19:** the slskd service moved into a Cloud Hypervisor microVM nested inside Proxmox VM 114 (`doc2`). This introduced nested AMD KVM and a four-vCPU/eight-virtio-net-queue VMM on doc2.
- **2026-07-20 16:22 AWST:** doc2 stopped logging and became unreachable over LAN, Tailscale, and QGA. Proxmox still reported the VM running; disk and network I/O stopped while approximately one of twelve vCPUs remained busy. A hard reset restored it. No panic text survived.
- **2026-07-22 04:50 AWST:** doc2 stopped logging and became unreachable in the same way. A Proxmox VGA screendump captured the terminal state before reset:

  ```text
  RIP: 0010:0xffffffff81001280
  Code: Unable to access opcode bytes at 0xffffffff81001256.
  note: _net0_qp2[...] exited with irqs disabled
  note: _net0_qp2[...] exited with preempt_count 1
  Kernel panic - not syncing: corrupted stack end detected inside scheduler
  ```

- A manual `qm reset 114` restored doc2. There was no host OOM, Proxmox storage/ZFS/NVMe error, MCE, or QEMU process exit around either incident.

## RCA hypothesis

The most likely failure boundary is the nested Cloud Hypervisor networking/KVM path used by the new slskd microVM on AMD, specifically the queue-pair topology created by four guest vCPUs.

Evidence:

1. The panic's task name, `_net0_qp2`, is not a generic Linux network thread. Live `/proc/<cloud-hypervisor-pid>/task/*/comm` inspection maps it exactly to Cloud Hypervisor 52's third slskd virtio-net queue-pair worker.
2. slskd's generated command used `--cpus boot=4` and `--net ... num_queues=8`, producing `_net0_qp0` through `_net0_qp3`.
3. The older qBittorrent cage uses the same Cloud Hypervisor 52 and Linux 6.18.38 stack, but only two vCPUs and four network queues. It has only `qp0` and `qp1`; the task that panicked doc2 cannot exist there.
4. qBittorrent has run this architecture since 2026-06-22 without panicking its outer host. Its outer host is Intel Kaby Lake under Unraid/QEMU, whereas doc2 is nested on AMD Zen 5 under Proxmox/QEMU.
5. Both doc2 failures occurred only after the slskd microVM and nested AMD-V were enabled. The first occurred about one day after activation; the second occurred about 36 hours after the reset.
6. Memory pressure is not a sufficient explanation: there was no OOM report, and the failure was a kernel-stack-canary corruption in a specific VMM queue thread. ZFS taints the kernel but emitted no adjacent fault evidence.

This does **not** prove whether the defect is in Linux 6.18 KVM/SVM, Cloud Hypervisor's multiqueue event path, QEMU's nested-virtualization exposure, or a specific interaction among them. The surviving console did not contain the earlier call trace, and pstore was empty after reset.

### Falsifiable prediction

Reducing slskd to two vCPUs removes `qp2`/`qp3` and matches qbt's proven queue topology. If doc2 panics again while the live slskd command has only `qp0`/`qp1`, this queue-count hypothesis is weakened and the next mitigation is to replace Cloud Hypervisor for slskd with QEMU or move the cage out of nested AMD virtualization.

## Mitigation and recovery design

### 1. Remove the implicated queue topology

`hosts/doc2/slskd-microvm.nix` fixes slskd at two vCPUs. The generated VMM must show:

```text
--cpus boot=2
--net ... num_queues=4
```

Live thread inventory must contain `qp0` and `qp1`, with no `qp2` or `qp3`.

### 2. Recover from a kernel panic without waiting for a human

Doc2 boots with `panic=30`, so a kernel panic reboots the guest after 30 seconds. This does not depend on systemd, networking, QGA, or doc2's co-located monitoring stack.

A separate watchdog runs on doc1 once per minute. It acts only when all of these are true:

- Proxmox is reachable and reports VM 114 running.
- VM uptime is at least ten minutes.
- doc2 TCP/22 is unavailable.
- Proxmox QGA ping is unavailable.
- Both failures persist for five consecutive checks.
- No automated reset occurred in the previous fifteen minutes.

Before resetting, it saves under `/var/lib/doc2-recovery/incidents/<UTC timestamp>/`:

- `qm status --verbose`
- `qm config`
- recent Proxmox kernel and VM/QEMU logs
- a VGA `screendump` as `console.ppm`

It then issues one `qm reset 114`. Failure to reach Proxmox never causes an action. A stopped VM is never started or reset.

### 3. Preserve panic text outside doc2

After networking is online, doc2 loads `netconsole` with fixed inventory values:

```text
6665@192.168.1.35/ens18 -> 6666@192.168.1.29/bc:24:11:a4:f8:32
```

Doc1 receives the datagrams through a systemd UDP socket and writes them to its persistent journal as `SYSLOG_IDENTIFIER=doc2-netconsole`. Its firewall accepts UDP/6666 only from doc2's `192.168.1.35` and drops other sources. This removes the prior evidence gap where doc2's journal stopped with the machine.

## Verification

Non-destructive checks:

```sh
# Exact slskd topology
ssh doc2 'pid=$(systemctl show microvm@slskd.service -p MainPID --value); tr "\0" " " </proc/$pid/cmdline; for f in /proc/$pid/task/*/comm; do cat "$f"; done'

# Panic timeout and sender
ssh doc2 'grep -o "panic=30" /proc/cmdline; systemctl is-active doc2-netconsole-sender; lsmod | grep ^netconsole'

# Receiver and healthy watchdog probe
systemctl is-active doc2-netconsole.socket doc2-recovery.timer
sudo systemctl start doc2-recovery.service
journalctl -u doc2-recovery.service -n 20 --no-pager

# End-to-end netconsole transport without causing a fault
ssh root@prom "qm guest exec 114 -- /run/current-system/sw/bin/bash -c 'echo DOC2-NETCONSOLE-TEST-20260722 > /dev/kmsg'"
journalctl -t doc2-netconsole --since '2 minutes ago' --no-pager
```

Do not test automated reset by taking doc2 offline in production. The safety gates are evaluated from generated service/script content, and the normal healthy invocation must leave the failure counter at zero.

## Rollback

- Revert the mitigation commit and redeploy doc1/doc2 through the signed fleet path.
- Immediate runtime disable without changing history:
  - doc1: `sudo systemctl stop doc2-recovery.timer doc2-netconsole.socket`
  - doc2 sender: stop `doc2-netconsole-sender.service` through the Proxmox console.
- `panic=30` only changes panic behavior; it does not reboot a healthy system.

## Revisit conditions

Escalate from the two-vCPU mitigation to a hypervisor/placement change if any of these occur:

- another outer doc2 kernel panic while slskd has no `qp2`/`qp3` threads;
- netconsole captures a trace that points outside the nested VMM/KVM path;
- an upstream Linux, Cloud Hypervisor, QEMU, or Proxmox fix names this signature;
- qbt develops the same host-kernel signature on its two-queue-pair Intel topology.
