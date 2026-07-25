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
    # writeShellApplication pins PATH to exactly these: dmesg comes from
    # util-linux and the df parser needs awk, both easy to omit and only
    # discoverable at crash time, which is the worst moment to find out.
    runtimeInputs = with pkgs; [coreutils gzip systemd findutils util-linux gawk kexec-tools];
    text = ''
      set -uo pipefail
      dir=${lib.escapeShellArg cfg.kdump.dumpDir}
      keep=${toString cfg.kdump.keepDumps}
      mkdir -p "$dir"
      stamp=$(date -u +%Y%m%dT%H%M%SZ)

      # The crashed kernel's log buffer is the high-value part and is tiny; write
      # it first so a full-disk failure on the vmcore still leaves the backtrace.
      #
      # It must come from vmcore-dmesg(8), which reads the log out of the DEAD
      # kernel's memory via /proc/vmcore. Plain `dmesg` here reads the *capture*
      # kernel's own freshly-booted ring buffer and silently produces an empty
      # file — verified on doc1's 2026-07-25 sysrq test, which wrote 0 bytes.
      vmcore-dmesg /proc/vmcore > "$dir/dmesg-$stamp.txt" 2>"$dir/dmesg-$stamp.err" \
        || echo "vmcore-dmesg failed; see .err and the vmcore itself" \
             >> "$dir/dmesg-$stamp.err"

      avail=$(df -Pk "$dir" | awk 'NR==2{print $4}')
      core=$(stat -Lc %s /proc/vmcore 2>/dev/null || echo 0)
      # gzip on mostly-free guest memory typically lands well under half, but
      # refuse rather than fill the root filesystem and wedge the host on boot.
      if [ "$core" -gt 0 ] && [ "$((core / 1024))" -lt "$((avail / 2))" ]; then
        gzip -1 -c /proc/vmcore > "$dir/vmcore-$stamp.gz" || \
          rm -f "$dir/vmcore-$stamp.gz"
      else
        echo "crash-capture: skipping vmcore (size=$core avail_kb=$avail)" \
          > "$dir/vmcore-$stamp.skipped"
      fi

      # Keep only the newest $keep dumps.
      find "$dir" -maxdepth 1 -name 'vmcore-*.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | tail -n "+$((keep + 1))" | cut -d' ' -f2- \
        | xargs -r rm -f

      sync
      systemctl --force reboot
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
        description = "Number of compressed vmcores retained before pruning.";
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
        unitConfig.ConditionPathExists = "/proc/vmcore";
        after = ["local-fs.target"];
        wantedBy = ["rescue.target" "emergency.target"];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe saveScript;
        };
      };

      systemd.tmpfiles.rules = ["d ${cfg.kdump.dumpDir} 0700 root root -"];
    })
  ];
}
