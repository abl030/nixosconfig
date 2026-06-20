# Host hardening baseline (kernel sysctl + sshd algos + idle-session reap)

**Date:** 2026-06-20 · **Status:** live fleet-wide · **Issue:** [#232](https://github.com/abl030/nixosconfig/issues/232) (least-privilege umbrella, "host-hardening block")

Fleet-wide host baseline that lands automatically on every NixOS host via
`modules/nixos/profiles/base.nix` (kernel sysctl + logind) and
`modules/nixos/services/ssh/default.nix` (sshd algorithm pinning). No per-host
opt-in — a host that needs to deviate must `lib.mkForce`, which is a deliberate,
auditable act. This is *not* the nixpkgs `hardened.nix` profile (see "What we
deliberately left out").

## Threat model

The same two the umbrella assumes: a popped **unprivileged process / container**
trying to (a) defeat KASLR to build a kernel exploit, or (b) spoof / redirect
traffic on the LAN or tailnet; and an **abandoned authenticated SSH session**
left open on an unlocked terminal.

## 1. Kernel sysctl baseline (`base.nix`, section 3c)

| sysctl | value | why |
|---|---|---|
| `kernel.kptr_restrict` | `2` | Hide kernel pointers from **everyone** (defeats `/proc/kallsyms` KASLR leaks). Safe because our diagnostic set (tcpdump/strace/iotop/dmesg/...) never reads kallsyms. Drop to `1` only if we start running perf/bcc/eBPF tracing. |
| `kernel.dmesg_restrict` | `1` | `dmesg` → CAP_SYSLOG only. `sudo dmesg` on the bastion still works (runs as root). |
| `net.ipv4.tcp_syncookies` | `1` | SYN-flood mitigation. Usually already on; explicit = harmless. |
| `net.ipv4.conf.{all,default}.rp_filter` | `2` (**loose**) | Anti-spoof reverse-path filtering. **Loose, NOT strict (`1`)** — see the asymmetric-routing footgun below. |
| `net.ipv4.conf.{all,default}.accept_redirects` + ipv6 | `0` | Ignore ICMP redirects (MITM / route-injection vector). Tailscale uses its own routing, unaffected. |
| `net.ipv4.conf.{all,default}.send_redirects` | `0` | We're leaf hosts, not routers — never emit redirects. |
| `net.ipv4.conf.{all,default}.accept_source_route` + ipv6 | `0` | Reject source-routed packets (can bypass routing/firewall assumptions). |

### ⚠️ Footgun: `rp_filter` must be LOOSE (`2`), never strict (`1`)

Strict reverse-path filtering drops any packet whose reply would route out a
*different* interface than it arrived on. Two things in this fleet break under
strict mode:

1. **doc2 has two NICs on the same subnet** — `ens18` = 192.168.1.35,
   `ens19` = 192.168.1.36. Replies pick one route for the /24, so traffic
   arriving on the other NIC is asymmetric and strict rp_filter silently drops
   it.
2. **Tailscale subnet routing / exit nodes** are inherently asymmetric.

Loose mode (`2`) still rejects packets whose source address has **no route via
any interface at all** (the actual anti-spoof win) without the breakage. If you
ever see mysterious one-way connectivity loss after a kernel/network change,
check that nothing flipped rp_filter to `1`.

## 2. sshd algorithm pinning (`modules/nixos/services/ssh/default.nix`)

Added to `services.openssh.settings`:

```
LoginGraceTime 30                      # was 120; bounds the UNAUTH login window
KexAlgorithms  mlkem768x25519-sha256, sntrup761x25519-sha512@openssh.com,
               curve25519-sha256, curve25519-sha256@libssh.org,
               diffie-hellman-group16-sha512, diffie-hellman-group18-sha512
Ciphers        chacha20-poly1305@openssh.com, aes256-gcm@openssh.com,
               aes128-gcm@openssh.com
Macs           hmac-sha2-512-etm@openssh.com, hmac-sha2-256-etm@openssh.com,
               umac-128-etm@openssh.com
```

- **`LoginGraceTime = 30`** — caps how long an *unauthenticated* connection can
  squat a listener slot (slow-loris / half-open). 30s is ample for key auth.
- **Cipher/KEX/MAC pin** = the ssh-audit "hardened" set. Every entry was verified
  present in `ssh -Q {kex,cipher,mac}` on the fleet's **OpenSSH 10.3p1**. Because
  the whole fleet builds from one `flake.lock`, the sshd version can't skew across
  hosts, so there is **no risk of sshd failing to start on an unknown algorithm**
  (the one real lockout hazard with algo pinning). `mlkem768x25519-sha256` is the
  OpenSSH 10.x post-quantum default and is preferred first.
- **Inbound-only.** This pins what *our* sshd will negotiate with connecting
  clients. It does not touch outbound `ssh`/`git push` (client config) or
  Tailscale SSH (bypasses sshd entirely). Every fleet host + workstation client
  runs this same OpenSSH, so nothing inbound is locked out.

### Decisions NOT taken (and why)

- **`MaxAuthTries` left at the default 6.** With `PasswordAuthentication no`
  fleet-wide the brute-force benefit is marginal, and a lower cap breaks
  multi-key ssh-agents — each key the agent offers counts as one attempt, so a
  user with >N keys hits "Too many authentication failures" before the right key.
- **`ClientAliveInterval`/`ClientAliveCountMax` not used for idle reaping.** They
  send encrypted keepalive probes the *client OS auto-answers*, so they only reap
  genuinely-dead connections, not a user idle at a live prompt. The idle reap is
  done by logind instead (below).
- **No host-key / `PubkeyAcceptedAlgorithms` pin** — would risk breaking a key
  type; out of scope for "cipher pinning".

## 3. Idle authenticated-session reap (`base.nix`, logind)

```nix
services.logind.settings.Login.StopIdleSessionSec = "55min";
```

- **55 min** is set deliberately just under the user's ssh-agent passphrase
  re-ask, so a reconnect re-prompts for the key anyway.
- **"Idle" = no PTY activity.** A session actively streaming output (a build, a
  `claude` run printing) keeps the pts atime fresh and is **not** killed. A
  session left at a bare idle prompt past 55 min is terminated (SSH connection
  dropped).
- **`KillUserProcesses` stays `false`** (nixpkgs default — it's that way
  precisely so tmux/screen/mosh/nohup survive a logout). So the idle reap drops
  the *connection* but a detached tmux/mosh session persists; reconnect and
  reattach.

## What we deliberately left out (NOT `hardened.nix`)

We did **not** import `nixpkgs/nixos/modules/profiles/hardened.nix`. Its
aggressive knobs would break this fleet:

- `kernel.unprivileged_bpf_disabled` / `net.core.bpf_jit_harden` — breaks tooling.
- `boot.kernel.sysctl."user.max_user_namespaces" = 0` /
  `kernel.unprivileged_userns_clone = 0` — **breaks rootless containers and the
  nix build sandbox**.
- `security.lockKernelModules`, hardened malloc, etc. — too disruptive for a
  homelab that hot-loads modules and runs mixed workloads.

We took the high-value, low-blast-radius subset and harden the **runtime** as the
compensating control (see the podman `cap-drop`/`no-new-privileges` baseline in
`docs/wiki/nixos-service-modules.md`).

## Why no enforcing flake check (unlike the bind/network items)

The bind/network/container items got `hostBindAuditCheck` /
`containerNetworkAuditCheck` because they live **per-service-module** and drift
as new modules are added. This baseline is **centralized in `base.nix` +the ssh
module** and applies to every host automatically — there is no per-module surface
to drift. The only way to weaken it is an explicit `lib.mkForce` in a host
config, which is self-documenting and grep-able. A check here would be enforcing
"nobody mkForce'd the baseline", which isn't worth the eval cost.

## Verifying on a host

```sh
# sysctl (loose rp_filter, restricts in place)
sysctl kernel.kptr_restrict kernel.dmesg_restrict net.ipv4.conf.all.rp_filter \
       net.ipv4.tcp_syncookies net.ipv4.conf.all.accept_redirects

# sshd negotiated algos (inbound)
sshd -T | grep -iE '^(ciphers|kexalgorithms|macs|logingracetime|maxauthtries)'

# logind idle reap
loginctl show-session "$XDG_SESSION_ID" -p IdleHint -p IdleSinceHint 2>/dev/null
busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager StopIdleSessionUSec 2>/dev/null   # = 55min in µs
```

## When to revisit

- If we start running **eBPF/perf tracing** routinely → `kptr_restrict` may need
  `1` (or a per-host mkForce on the tracing host).
- If a **non-NixOS / old SSH client** ever needs in → re-check the cipher pin
  against its supported algos (`ssh -Q` on the client) before assuming it's a
  network problem.
- On a major **OpenSSH bump**, re-run `ssh -Q kex` to pick up newer PQ KEX
  (e.g. a future mlkem variant) and reorder the pin.
