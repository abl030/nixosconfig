# modules/nixos/services/kill-trace.nix
#
# Answers one question that the journal alone cannot: WHO sent the SIGKILL.
#
# Motivating incident (2026-08-22, doc1). `user@1000.service` died with:
#
#   systemd[1]: user@1000.service: Main process exited, code=killed, status=9/KILL
#   systemd[1]: user@1000.service: Failed with result 'signal'
#
# taking the durable tmux server, every `claude` process and the hermes gateway
# down with it. Post-mortem could prove what it was NOT — logind never fired an
# idle stop (`StopIdleSessionSec`, zero "is idle, stopping" records that boot),
# `oom_kill` was 0 system-wide AND in every cgroup, systemd-oomd had no kill
# policy, earlyoom/nohang were inactive, no rebuild had run — but PID 1 logs
# only that its child died by signal 9, never who sent it. With no audit trail
# the sender is unknowable after the fact, so the incident closed unattributed.
#
# This module makes the NEXT occurrence attributable. Two independent halves:
#
#   1. The Linux audit subsystem records every kill(2)/tkill(2)/tgkill(2)
#      carrying SIGKILL. An audit SYSCALL record names the sender's pid, ppid,
#      comm, exe, uid AND `auid`/`ses` — the *login session* it came from, which
#      is what actually distinguishes "an agent's shell command" from "a system
#      service". `audit_signals` (enabled by registering a signal-syscall rule)
#      adds an OBJ_PID record naming the target, so sender→target is one lookup.
#      Kernel-originated SIGKILLs (the OOM killer) are not syscalls and never
#      appear here — that absence is itself evidence, corroborated by the
#      oom_kill counters the capture below snapshots.
#
#   2. An `OnFailure=` drop-in on each watched unit fires a capture the instant
#      it dies, while the sender may still be alive: audit records, a full
#      process forest with cgroups, login sessions, memory/OOM counters and the
#      journal tail, written to a persistent directory under /var/log — then
#      pages the operator so the trap is known to have sprung.
#
# Deliberately narrow: SIGKILL only. SIGTERM is the ordinary service-stop signal
# and auditing it would bury the interesting record in thousands of routine
# ones. Widening to `-F a1=15` is a one-line change if a future incident shows a
# clean-exit signature instead of `status=9/KILL`.
#
# Full incident write-up and how to read a capture:
# docs/wiki/infrastructure/kill-trace-forensics.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.killTrace;
  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  captureDir = "/var/log/kill-trace";

  # Root is required and is the whole point: the capture reads /var/log/audit
  # (0600 root), every /proc/<pid>/cgroup across all users, and the full
  # journal. It only ever reads, plus writes under its own captureDir. No
  # network egress except the alert, which reuses the existing RCA/Gotify path.
  captureScript = pkgs.writeShellApplication {
    name = "kill-trace-capture";
    # No `errexit`: every section is best-effort and must be attempted even if
    # an earlier one fails. A partial capture is far better than none — this
    # runs exactly when the machine is already in a strange state.
    bashOptions = ["nounset" "pipefail"];
    # SC2157 fires inside the inlined shared negative-alert helper, where the
    # Gotify URL is a Nix-substituted literal so `[ -z "<literal>" ]` is
    # provably false. It is not reachable from this script's own code, and
    # keeping writeShellApplication (rather than dropping to writeShellScript
    # as the older alerting modules do) keeps shellcheck on everything else.
    excludeShellChecks = ["SC2157"];
    runtimeInputs = with pkgs; [
      audit
      coreutils
      gnugrep
      procps
      systemd
      util-linux
    ];
    text = ''
      ${sendNegativeAlert}

      unit="''${1:-unknown}"
      host="${config.networking.hostName}"
      stamp="$(date -u +%Y%m%dT%H%M%SZ)"
      dir="${captureDir}/''${stamp}-''${unit}"

      mkdir -p "$dir"
      chmod 0750 "$dir"

      # --- 1. The signal itself -------------------------------------------
      # Every SIGKILL syscall in the recent window. `-i` interprets numeric
      # uids/syscalls into names; the raw form is kept alongside because the
      # target pid is only visible there as the hex `a0` argument when the
      # kernel did not emit an OBJ_PID record.
      ausearch -k sigkill -ts recent -i \
        >"$dir/audit-sigkill-interpreted.txt" 2>&1
      ausearch -k sigkill -ts recent \
        >"$dir/audit-sigkill-raw.txt" 2>&1

      # --- 2. What is alive right now --------------------------------------
      # The sender may still be running; capture it before it exits. lstart and
      # etimes let a reader tell a long-lived daemon from something spawned
      # seconds before the kill.
      ps -eo pid,ppid,pgid,sid,user,stat,lstart,etimes,rss,args --forest \
        >"$dir/ps-forest.txt" 2>&1
      systemd-cgls --no-pager --all >"$dir/systemd-cgls.txt" 2>&1

      # --- 3. systemd and login state --------------------------------------
      systemctl status "$unit" --no-pager -l >"$dir/unit-status.txt" 2>&1
      systemctl list-units --failed --no-pager >"$dir/failed-units.txt" 2>&1
      {
        loginctl list-sessions --no-pager
        echo
        loginctl list-users --no-pager
      } >"$dir/loginctl.txt" 2>&1

      # --- 4. Rule the OOM killer in or out, definitively -------------------
      # oom_kill counts kernel OOM kills since boot, globally and per cgroup. A
      # zero here alongside a dead process is proof the kernel did not do it.
      {
        echo "--- /proc/vmstat (oom counters) ---"
        grep -E 'oom_kill|pgmajfault' /proc/vmstat
        echo
        echo "--- /proc/meminfo ---"
        head -n 20 /proc/meminfo
        echo
        echo "--- per-cgroup memory.events ---"
        find /sys/fs/cgroup -maxdepth 3 -name memory.events -print -exec cat {} \;
      } >"$dir/memory-and-oom.txt" 2>&1

      # --- 5. Surrounding narrative ----------------------------------------
      journalctl -b -n 5000 --no-pager >"$dir/journal-tail.txt" 2>&1
      journalctl -b -k -n 2000 --no-pager >"$dir/kernel.txt" 2>&1

      # --- 6. Distil something a human can act on ---------------------------
      # The SYSCALL records carry the sender identity. auid/ses are the prize:
      # they name the login session behind the kill, or 4294967295 ("unset")
      # for something with no login ancestry, i.e. a system service.
      senders="$(grep -E '^type=SYSCALL' "$dir/audit-sigkill-interpreted.txt" 2>/dev/null | tail -n 25)"
      targets="$(grep -E '^type=OBJ_PID' "$dir/audit-sigkill-interpreted.txt" 2>/dev/null | tail -n 25)"

      {
        echo "kill-trace capture"
        echo "  host:    $host"
        echo "  unit:    $unit"
        echo "  when:    $stamp"
        echo "  dir:     $dir"
        echo
        if [ -n "$senders" ]; then
          echo "SIGKILL senders seen in the audit window:"
          echo "$senders"
        else
          echo "No SIGKILL syscall records in the audit window."
          echo "If the unit still died by signal 9, the sender was the kernel"
          echo "(OOM/cgroup) rather than a process — see memory-and-oom.txt."
        fi
        echo
        if [ -n "$targets" ]; then
          echo "Signal targets (OBJ_PID):"
          echo "$targets"
        fi
      } >"$dir/summary.txt" 2>&1

      # --- 7. Page, so the trap is known to have sprung ---------------------
      send_negative_alert \
        "kill-trace: $unit died by signal on $host" \
        "$(cat "$dir/summary.txt")" \
        7
    '';
  };
in {
  options.homelab.killTrace = {
    enable = lib.mkEnableOption "SIGKILL attribution via the audit subsystem plus on-failure forensic capture";

    watchedUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["user@1000.service"];
      example = ["user@1000.service" "hermes-gateway.service"];
      description = ''
        Units that receive an `OnFailure=` drop-in firing the forensic capture.
        Each entry must be a full unit name. The drop-in adds nothing but
        `OnFailure=`, so a watched unit's own behaviour is unchanged.
      '';
    };

    retain = lib.mkOption {
      type = lib.types.str;
      default = "30d";
      description = "systemd-tmpfiles age after which old captures under ${captureDir} are removed.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Load the rules into the kernel. `printk` (never `panic`) on failure: a
    # diagnostic must not be able to take the host down, and on the bastion
    # that matters more than a guaranteed-complete audit stream.
    security.audit = {
      enable = true;
      failureMode = "printk";
      backlogLimit = 8192;
      # 0 disables rate limiting. A limit would silently drop records exactly
      # during the storm we are trying to capture.
      rateLimit = 0;
      rules = [
        "-a always,exit -F arch=b64 -S kill,tkill,tgkill -F a1=9 -k sigkill"
        "-a always,exit -F arch=b32 -S kill,tkill,tgkill -F a1=9 -k sigkill"
      ];
    };

    # The daemon that persists records to /var/log/audit so a capture can read
    # them back after the fact.
    security.auditd.enable = true;

    # Blast-radius control. auditd's stock disk-pressure actions include
    # SUSPEND and HALT — a full /var must never wedge or halt the bastion, so
    # every action is pinned to a logging-only response and the log is hard
    # capped at num_logs * max_log_file = 120 MiB.
    security.auditd.settings = {
      max_log_file = 30;
      num_logs = 4;
      max_log_file_action = "ROTATE";
      space_left = "10%";
      space_left_action = "SYSLOG";
      admin_space_left = "5%";
      admin_space_left_action = "SYSLOG";
      disk_full_action = "ROTATE";
      disk_error_action = "SYSLOG";
      flush = "INCREMENTAL_ASYNC";
    };

    systemd.tmpfiles.rules = [
      "d ${captureDir} 0750 root root ${cfg.retain}"
    ];

    systemd.services = lib.mkMerge (
      [
        # `%I` is the failing unit's name, forwarded from the
        # `OnFailure=...@%n.service` on each watched unit below.
        {
          "kill-trace-capture@" = {
            description = "Forensic capture for %I dying by signal";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe captureScript} %I";

              # Runs as root by necessity — it reads /var/log/audit (0600
              # root), every /proc/<pid> across all users, and the full
              # journal. It never needs to GAIN privileges beyond that, so NNP
              # is unconditional.
              NoNewPrivileges = true;

              # systemd creates and owns the capture root, which also makes it
              # the one writable path under ProtectSystem=strict. The tmpfiles
              # rule below only ages entries out; both agree on 0750.
              LogsDirectory = "kill-trace";
              LogsDirectoryMode = "0750";

              # Read-everything, write-only-its-own-captures. Deliberately no
              # ProtectProc/ProcSubset: the whole job is to observe other
              # users' processes, and a sandbox that hid them would produce a
              # silently empty capture at the one moment it matters.
              ProtectSystem = "strict";
              PrivateTmp = true;
            };
          };
        }
      ]
      # Attach the trigger as a drop-in so units NixOS does not otherwise
      # define (systemd's own `user@.service` instances) keep their upstream
      # definition and gain only this one line.
      ++ map (unit: {
        ${lib.removeSuffix ".service" unit} = {
          overrideStrategy = "asDropin";
          unitConfig.OnFailure = ["kill-trace-capture@%n.service"];
          # Adding the drop-in makes the watched unit "changed" in switch-to-
          # configuration's eyes. Restarting user@1000.service kills every
          # process it contains — the tmux server, agents, hermes — i.e. the
          # deploy would inflict the very outage this module exists to explain.
          # nixpkgs pins the same flag on the `user@.service` template for
          # exactly this reason; set it on the instance too rather than relying
          # on drop-in merge order.
          restartIfChanged = false;
        };
      })
      cfg.watchedUnits
    );
  };
}
