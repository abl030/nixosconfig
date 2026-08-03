# Fleet crash capture: stream kernel oops/panic text off-box, and optionally
# take a full vmcore.
#
# Motivation (#51): doc1 kernel-panicked on 2026-07-24 and the faulting frames
# were lost — EFI pstore dropped the middle chunks and doc1 had no off-box
# console, so the one artifact that would have closed the RCA never existed.
# doc2 has had a netconsole sender since the 2026-07-22 panic work and it is
# verified working; every other host is still mute.
#
# Two tiers, deliberately separated by cost:
#
#   netconsole (default ON)  — streams KERN_ERR and above to a collector as the
#     kernel prints it. Costs nothing: no reserved memory, no disk, no
#     availability change. Captures the oops/panic backtrace, which is the
#     artifact that was actually missing. This is the fleet standard.
#
#   kdump (opt-in, OFF)      — reserves memory for a capture kernel and writes a
#     full /proc/vmcore. Only worth it where you intend to run crash(8) against
#     the image. See the cost warnings on the options below before enabling.
#
# Neither tier can work in an LXC container or WSL: both share the host kernel,
# so there is no guest kernel to capture and no kexec to perform. The module
# asserts rather than silently doing nothing.
#
# See docs/wiki/infrastructure/fleet-crash-capture.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.crashCapture;

  isContainer = config.boot.isContainer or false;
  isWsl = config.wsl.enable or false;
  canCapture = !isContainer && !isWsl;

  # netconsole must be told the collector's MAC. At panic time the kernel is in
  # atomic context and cannot ARP, so a stale neighbour entry means the panic
  # text is silently dropped — exactly the failure we are trying to fix. The
  # source interface is discovered at start time instead of hardcoded, so hosts
  # with different NIC names need no per-host configuration.
  senderScript = pkgs.writeShellApplication {
    name = "crash-capture-netconsole-start";
    runtimeInputs = with pkgs; [iproute2 kmod gawk coreutils];
    text = ''
      set -uo pipefail
      collector=${lib.escapeShellArg cfg.netconsole.collectorAddress}
      collector_mac=${lib.escapeShellArg cfg.netconsole.collectorMac}
      port=${toString cfg.netconsole.collectorPort}
      src_port=${toString cfg.netconsole.sourcePort}

      # Resolve the egress interface and address the kernel will actually use to
      # reach the collector, rather than assuming a NIC name. Parse by keyword
      # position: `ip route get` emits "<dst> dev X src Y ..." for a remote peer
      # but "local <dst> dev lo table local src Y ..." on the collector itself,
      # so any fixed-shape regex silently matches only one of the two forms.
      read -r dev src < <(ip -4 route get "$collector" | awk '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "dev") d = $(i + 1)
            if ($i == "src") s = $(i + 1)
          }
          if (d != "" && s != "") { print d, s; exit }
        }')
      if [ -z "''${dev:-}" ] || [ -z "''${src:-}" ]; then
        echo "crash-capture: cannot resolve route to collector $collector" >&2
        exit 1
      fi

      if [ "$src" = "$collector" ]; then
        echo "crash-capture: this host IS the collector; sender not started"
        exit 0
      fi

      modprobe -r netconsole 2>/dev/null || true
      exec modprobe netconsole \
        "netconsole=$src_port@$src/$dev,$port@$collector/$collector_mac" \
        oops_only=${
        if cfg.netconsole.oopsOnly
        then "1"
        else "0"
      }
    '';
  };

  # NixOS's boot.crashDump drops the capture kernel into systemd rescue and
  # leaves it there. Unattended that is strictly worse than the current
  # panic=30 reboot: a panicked host stays down until a human notices. Save the
  # dump, prune old ones, then reboot, so kdump never costs availability.
  saveScript = pkgs.writeShellApplication {
    name = "crash-capture-save-vmcore";
    runtimeInputs = with pkgs; [coreutils gzip systemd findutils util-linux gawk kexec-tools gnutar];
    text = ''
      set -uo pipefail
      dir=${lib.escapeShellArg cfg.kdump.dumpDir}
      keep=${toString cfg.kdump.keepDumps}
      minimum_free_gib=${toString cfg.kdump.minimumFreeGiB}
      max_dump_seconds=${toString (cfg.kdump.maxDumpMinutes * 60)}
      configured_vmlinux=${lib.escapeShellArg "${config.boot.kernelPackages.kernel.dev}/vmlinux"}
      configured_modules=${lib.escapeShellArg config.system.modulesTree}
      stamp=""
      target=""
      partial=""
      reserve="$dir/.vmcore-reserve"

      # Invoked transitively by the EXIT/signal trap.
      # shellcheck disable=SC2329
      cleanup() {
        if [ -n "$target" ]; then
          if [ -s "$target.tmp" ]; then
            mv "$target.tmp" "$partial"
          else
            rm -f "$target.tmp"
          fi
        fi
        if [ -n "$stamp" ]; then
          rm -f "$dir/vmlinux-$stamp.gz.tmp" \
            "$dir/kernel-modules-$stamp.tar.gz.tmp"
        fi
        rm -f "$reserve"
      }
      # Installed as the EXIT trap immediately below.
      # shellcheck disable=SC2329
      reboot_after_capture() {
        trap - EXIT HUP INT TERM
        set +e
        cleanup
        sync
        # The crash kernel must never remain stranded in rescue mode. The unit's
        # FailureAction=reboot-force is the final fallback if both commands return.
        if timeout 5 systemctl --force reboot; then
          sleep 1
        else
          timeout 5 reboot -f || true
        fi
        exit 1
      }
      trap reboot_after_capture EXIT
      trap 'exit 1' HUP INT TERM

      mkdir -p "$dir"
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      target="$dir/vmcore-$stamp.gz"
      partial="$target.partial"

      # A reset during an earlier capture can leave incomplete state. The reserve
      # is real allocated space, not a sparse file, so releasing it always leaves
      # minimumFreeGiB available even if gzip reaches ENOSPC.
      for stale in "$dir"/vmcore-*.tmp; do
        [ -e "$stale" ] || continue
        if [ -s "$stale" ]; then
          mv "$stale" "''${stale%.tmp}.partial"
        else
          rm -f "$stale"
        fi
      done
      rm -f "$reserve"

      prune_generations() {
        local limit=$1
        { find "$dir" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null \
          | grep -oE '[0-9]{8}T[0-9]{6}Z' || true; } | sort -ru \
          | tail -n "+$((limit + 1))" \
          | while IFS= read -r old_stamp; do
              find "$dir" -maxdepth 1 -type f -name "*-$old_stamp.*" -delete
            done
      }
      # Make room before beginning the new transaction, while retaining enough
      # prior contexts to satisfy keepDumps once this one completes.
      prune_generations "$((keep - 1))"

      # The crashed kernel's log buffer is the high-value part and is tiny; write
      # it first so a full-disk failure on the vmcore still leaves the backtrace.
      vmcore-dmesg /proc/vmcore > "$dir/dmesg-$stamp.txt" 2>"$dir/dmesg-$stamp.err" \
        || echo "vmcore-dmesg failed; see .err and the vmcore itself" \
             >> "$dir/dmesg-$stamp.err"

      {
        printf 'captured_utc=%s\n' "$(date -u --iso-8601=seconds)"
        printf 'configured_vmlinux=%s\n' "$configured_vmlinux"
        printf 'configured_modules=%s\n' "$configured_modules"
        printf 'capture_kernel_uname='; uname -a
        printf 'capture_kernel_cmdline='; cat /proc/cmdline
        printf 'current_system='; readlink -f /run/current-system 2>/dev/null || true
        sha256sum "$configured_vmlinux" 2>/dev/null || true
      } > "$dir/kernel-context-$stamp.txt"

      core=$(stat -Lc %s /proc/vmcore 2>/dev/null || echo 0)
      if [ "$core" -le 0 ]; then
        echo "crash-capture: /proc/vmcore had zero size" > "$dir/vmcore-$stamp.skipped"
      elif ! fallocate -l "''${minimum_free_gib}G" "$reserve"; then
        echo "crash-capture: vmcore skipped reason=reserve-allocation-failed reserve_gib=$minimum_free_gib" \
          > "$dir/vmcore-$stamp.skipped"
      else
        # Preserve the exact unstripped image and module closure alongside the
        # vmcore. Referencing these store paths also keeps them in the generation
        # closure so routine Nix garbage collection cannot orphan the dump.
        if gzip -1 -c "$configured_vmlinux" > "$dir/vmlinux-$stamp.gz.tmp" \
          2> "$dir/vmlinux-$stamp.err"; then
          mv "$dir/vmlinux-$stamp.gz.tmp" "$dir/vmlinux-$stamp.gz"
        else
          rm -f "$dir/vmlinux-$stamp.gz.tmp"
        fi
        if tar -C "$configured_modules" -czf "$dir/kernel-modules-$stamp.tar.gz.tmp" . \
          2> "$dir/kernel-modules-$stamp.err"; then
          mv "$dir/kernel-modules-$stamp.tar.gz.tmp" "$dir/kernel-modules-$stamp.tar.gz"
        else
          rm -f "$dir/kernel-modules-$stamp.tar.gz.tmp"
        fi

        # A separate process group lets the deadline terminate gzip and any
        # descendants before waiting; a TERM-resistant helper cannot strand us.
        setsid gzip -1 -c /proc/vmcore > "$target.tmp" &
        gzip_pid=$!
        started=$SECONDS
        abort_reason=""
        while kill -0 "$gzip_pid" 2>/dev/null; do
          if [ "$((SECONDS - started))" -ge "$max_dump_seconds" ]; then
            abort_reason="deadline-exceeded"
            kill -- "-$gzip_pid" 2>/dev/null || true
            for _ in $(seq 1 50); do
              kill -0 "$gzip_pid" 2>/dev/null || break
              sleep 0.1
            done
            kill -KILL -- "-$gzip_pid" 2>/dev/null || true
            break
          fi
          sleep 1
        done
        if wait "$gzip_pid" && [ -z "$abort_reason" ]; then
          mv "$target.tmp" "$target"
        else
          [ -n "$abort_reason" ] || abort_reason="write-failed"
          if [ -s "$target.tmp" ]; then
            mv "$target.tmp" "$partial"
          else
            rm -f "$target.tmp"
          fi
          echo "crash-capture: vmcore aborted reason=$abort_reason max_dump_seconds=$max_dump_seconds partial=$partial" \
            > "$dir/vmcore-$stamp.skipped"
        fi
      fi

      prune_generations "$keep"
      exit 0
    '';
  };
in {
  options.homelab.crashCapture = {
    netconsole = {
      enable =
        lib.mkEnableOption "streaming kernel oops/panic text to a collector"
        // {default = canCapture;};

      collectorAddress = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.29";
        description = "Host running the netconsole receiver (doc1).";
      };

      collectorMac = lib.mkOption {
        type = lib.types.str;
        default = "bc:24:11:a4:f8:32";
        description = ''
          Collector's link-layer address. Hardcoded deliberately: at panic time
          the kernel cannot ARP, so relying on a live neighbour entry loses
          exactly the messages this exists to capture.
        '';
      };

      collectorPort = lib.mkOption {
        type = lib.types.port;
        default = 6666;
      };

      sourcePort = lib.mkOption {
        type = lib.types.port;
        default = 6665;
      };

      oopsOnly = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Restrict transmission to oops/panic records only. Left off so that
          sysrq task dumps — which raise console_loglevel for their duration —
          also reach the collector during a wedge.
        '';
      };
    };

    kdump = {
      enable = lib.mkEnableOption ''
        full vmcore capture via kexec.

        Costs, all real: `reservedMemory` is taken from this host permanently and
        is unavailable to workloads; a dump is written at up to RAM size (gzipped)
        into `dumpDir`; and `panic_on_oops` is turned on, so oopses this host
        would previously have limped through now become reboots. Enable only
        where you actually intend to run crash(8) against the image
      '';

      reservedMemory = lib.mkOption {
        type = lib.types.str;
        default = "256M";
        description = ''
          Memory reserved for the capture kernel. Too large and the reservation
          fails at boot ("crashkernel reservation failed" in dmesg); too small
          and the capture kernel cannot boot.
        '';
      };

      dumpDir = lib.mkOption {
        type = lib.types.path;
        default = "/var/crash";
      };

      keepDumps = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
        description = "Number of crash artifact generations retained before pruning each older set atomically.";
      };

      minimumFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = 8;
        description = "Preallocated filesystem reserve held throughout vmcore compression.";
      };

      maxDumpMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = "Hard deadline for vmcore compression before partial output is retained and the host reboots.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !(cfg.kdump.enable && !canCapture);
          message = ''
            homelab.crashCapture.kdump is enabled on a host that shares its
            kernel with the hypervisor (LXC container or WSL). There is no guest
            kernel to dump and kexec is unavailable. Capture crashes for this
            host on its kernel owner instead.
          '';
        }
        {
          assertion = !(cfg.netconsole.enable && !canCapture);
          message = ''
            homelab.crashCapture.netconsole is enabled on an LXC container or
            WSL host, which has no own kernel log to stream. Disable it here.
          '';
        }
      ];
    }

    (lib.mkIf (cfg.netconsole.enable && canCapture) {
      systemd.services.crash-capture-netconsole = {
        description = "Stream kernel oops/panic records to the fleet collector";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe senderScript;
          ExecStop = "${pkgs.kmod}/bin/modprobe -r netconsole";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
        };
      };
    })

    (lib.mkIf (cfg.kdump.enable && canCapture) {
      boot.crashDump = {
        enable = true;
        reservedMemory = cfg.kdump.reservedMemory;
      };

      # Dump on the FIRST oops. Without this the initial fault is only logged and
      # the cascade that follows corrupts the state we wanted to inspect — which
      # is how doc1's original faulting frames were lost.
      boot.kernel.sysctl."kernel.panic_on_oops" = lib.mkDefault 1;

      # Safety net only. With a capture kernel loaded, panic kexecs immediately
      # and this never fires; it matters when kexec itself fails, where the
      # alternative is the host hanging until someone notices. doc1 currently
      # runs panic=0, i.e. hang forever — never arm kdump without this.
      boot.kernel.sysctl."kernel.panic" = lib.mkDefault 30;

      systemd.services.crash-capture-save-vmcore = {
        description = "Persist vmcore after a kernel crash, then reboot";
        unitConfig = {
          ConditionPathExists = "/proc/vmcore";
          FailureAction = "reboot-force";
          RequiresMountsFor = cfg.kdump.dumpDir;
        };
        after = ["local-fs.target"];
        wantedBy = ["rescue.target" "emergency.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe saveScript;
          # Bound the entire crash-kernel transaction. The script's compression
          # deadline leaves five minutes for symbols, cleanup and reboot.
          TimeoutStartSec = "${toString (cfg.kdump.maxDumpMinutes + 5)}min";
          TimeoutStopSec = "30s";
          KillMode = "control-group";
          SendSIGKILL = true;
        };
      };

      systemd.tmpfiles.rules = ["d ${cfg.kdump.dumpDir} 0700 root root -"];
    })
  ];
}
