# Independent doc2 panic capture and recovery, running on doc1.
#
# The watchdog requires BOTH doc2 TCP/22 and Proxmox QGA to fail for a sustained
# interval before it acts. Before resetting VM 114 it captures the VGA console,
# QEMU/VM status, and recent Proxmox logs under /var/lib/doc2-recovery/incidents.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.doc2Recovery;

  recoveryScript = pkgs.writeShellApplication {
    name = "doc2-recovery-check";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      netcat-openbsd
      openssh
      util-linux
    ];
    text = ''
      set -uo pipefail

      state_dir=/var/lib/doc2-recovery
      failures_file="$state_dir/consecutive-failures"
      cooldown_file="$state_dir/cooldown-until"
      known_hosts="$state_dir/known_hosts"
      prom=${lib.escapeShellArg cfg.promHost}
      doc2_address=${lib.escapeShellArg cfg.doc2Address}
      vmid=${toString cfg.vmid}
      threshold=${toString cfg.failureThreshold}
      cooldown_seconds=${toString cfg.cooldownSeconds}
      min_vm_uptime=${toString cfg.minimumVmUptimeSeconds}
      key=${lib.escapeShellArg cfg.sshKeyFile}

      mkdir -p "$state_dir/incidents"
      exec 9>"$state_dir/lock"
      flock -n 9 || exit 0

      ssh_prom() {
        timeout 20 ssh -i "$key" \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=accept-new \
          -o UserKnownHostsFile="$known_hosts" \
          "$prom" "$@"
      }

      now=$(date +%s)
      cooldown_until=$(cat "$cooldown_file" 2>/dev/null || printf '0')
      if [ -z "$cooldown_until" ] || [[ "$cooldown_until" == *[!0-9]* ]]; then
        cooldown_until=0
      fi
      if [ "$now" -lt "$cooldown_until" ]; then
        exit 0
      fi

      status=$(ssh_prom "qm status $vmid --verbose" 2>/dev/null) || {
        echo "DOC2-RECOVERY observer-unreachable prom=$prom action=none"
        exit 0
      }
      if ! grep -qx 'status: running' <<<"$status"; then
        printf '0\n' > "$failures_file"
        echo "DOC2-RECOVERY vm-not-running vmid=$vmid action=none"
        exit 0
      fi

      vm_uptime=$(sed -n 's/^uptime: //p' <<<"$status")
      if [ -z "$vm_uptime" ] || [[ "$vm_uptime" == *[!0-9]* ]]; then
        vm_uptime=0
      fi
      if [ "$vm_uptime" -lt "$min_vm_uptime" ]; then
        printf '0\n' > "$failures_file"
        exit 0
      fi

      tcp_ok=0
      qga_ok=0
      nc -z -w 3 "$doc2_address" 22 >/dev/null 2>&1 && tcp_ok=1
      ssh_prom "timeout 5 qm guest cmd $vmid ping >/dev/null 2>&1" >/dev/null 2>&1 && qga_ok=1

      if [ "$tcp_ok" -eq 1 ] || [ "$qga_ok" -eq 1 ]; then
        if [ -s "$failures_file" ] && [ "$(cat "$failures_file")" != 0 ]; then
          echo "DOC2-RECOVERY recovered-before-threshold tcp_ok=$tcp_ok qga_ok=$qga_ok"
        fi
        printf '0\n' > "$failures_file"
        exit 0
      fi

      failures=$(cat "$failures_file" 2>/dev/null || printf '0')
      if [ -z "$failures" ] || [[ "$failures" == *[!0-9]* ]]; then
        failures=0
      fi
      failures=$((failures + 1))
      printf '%s\n' "$failures" > "$failures_file"
      echo "DOC2-RECOVERY unhealthy count=$failures threshold=$threshold tcp_ok=0 qga_ok=0"
      [ "$failures" -ge "$threshold" ] || exit 0

      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      incident="$state_dir/incidents/$stamp"
      mkdir -p "$incident"
      printf '%s\n' "$status" > "$incident/qm-status.txt"
      ssh_prom "qm config $vmid" > "$incident/qm-config.txt" 2>&1 || true
      ssh_prom "journalctl -k --since '20 minutes ago' --no-pager" > "$incident/prom-kernel.txt" 2>&1 || true
      ssh_prom "journalctl --since '20 minutes ago' --no-pager | grep -Ei 'qemu|kvm|qga|VM $vmid|vhost|virtiofs|oom|mce|hardware error'" \
        > "$incident/prom-vm.txt" 2>&1 || true

      remote_image="/tmp/doc2-recovery-$stamp.ppm"
      if ssh_prom "rm -f '$remote_image'; printf 'screendump $remote_image\\nquit\\n' | qm monitor $vmid >/dev/null; test -s '$remote_image'"; then
        ssh_prom "cat '$remote_image'; rm -f '$remote_image'" > "$incident/console.ppm" 2>/dev/null || true
      fi

      if [ "''${DOC2_RECOVERY_DRY_RUN:-0}" = 1 ]; then
        printf '0\n' > "$failures_file"
        echo "DOC2-RECOVERY dry-run would-reset vmid=$vmid incident=$incident"
        exit 0
      fi

      if ssh_prom "qm reset $vmid"; then
        printf '0\n' > "$failures_file"
        printf '%s\n' "$((now + cooldown_seconds))" > "$cooldown_file"
        echo "DOC2-RECOVERY reset vmid=$vmid incident=$incident cooldown_seconds=$cooldown_seconds"
      else
        echo "DOC2-RECOVERY reset-failed vmid=$vmid incident=$incident"
        exit 1
      fi
    '';
  };
in {
  options.homelab.services.doc2Recovery = {
    enable = lib.mkEnableOption "independent doc2 kernel-panic capture and reset watchdog";

    promHost = lib.mkOption {
      type = lib.types.str;
      default = "root@192.168.1.12";
      description = "Proxmox SSH target that owns the doc2 VM.";
    };

    doc2Address = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.35";
      description = "Direct doc2 LAN address used for the independent TCP probe.";
    };

    vmid = lib.mkOption {
      type = lib.types.ints.positive;
      default = 114;
    };

    sshKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Root-readable SSH key authorized on the Proxmox host.";
    };

    failureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      default = 5;
      description = "Consecutive one-minute dual-path failures required before reset.";
    };

    minimumVmUptimeSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Never reset a newly started VM during its boot window.";
    };

    cooldownSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Minimum time after an automated reset before another can occur.";
    };

    receiverAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.29";
      description = "doc1 address on which to receive doc2 netconsole datagrams.";
    };

    netconsolePort = lib.mkOption {
      type = lib.types.port;
      default = 6666;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.failureThreshold >= 3;
        message = "doc2Recovery.failureThreshold must require at least three consecutive failures";
      }
      {
        assertion = cfg.minimumVmUptimeSeconds >= 300;
        message = "doc2Recovery.minimumVmUptimeSeconds must protect at least five minutes of boot";
      }
    ];

    systemd.services.doc2-recovery = {
      description = "Capture and reset a persistently frozen doc2 VM";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe recoveryScript;
        StateDirectory = "doc2-recovery";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        TimeoutStartSec = "120s";
      };
    };

    systemd.timers.doc2-recovery = {
      description = "Independent sustained-failure watchdog for doc2";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "1min";
        AccuracySec = "10s";
      };
    };

    # Kernel netconsole datagrams arrive on this socket and are persisted in
    # doc1's journal under SYSLOG_IDENTIFIER=doc2-netconsole. The socket is
    # source-restricted by the firewall rules below.
    systemd.sockets.doc2-netconsole = {
      description = "Receive doc2 kernel netconsole records";
      wantedBy = ["sockets.target"];
      socketConfig = {
        ListenDatagram = "${cfg.receiverAddress}:${toString cfg.netconsolePort}";
        FreeBind = true;
      };
    };

    systemd.services.doc2-netconsole = {
      description = "Persist doc2 kernel netconsole records";
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/bin/systemd-cat --identifier=doc2-netconsole --priority=warning";
        StandardInput = "socket";
        DynamicUser = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    networking.firewall = {
      extraCommands = ''
        iptables -A nixos-fw -p udp --dport ${toString cfg.netconsolePort} -s ${cfg.doc2Address} -j nixos-fw-accept
        iptables -A nixos-fw -p udp --dport ${toString cfg.netconsolePort} -j DROP
      '';
      extraStopCommands = ''
        iptables -D nixos-fw -p udp --dport ${toString cfg.netconsolePort} -s ${cfg.doc2Address} -j nixos-fw-accept 2>/dev/null || true
        iptables -D nixos-fw -p udp --dport ${toString cfg.netconsolePort} -j DROP 2>/dev/null || true
      '';
    };
  };
}
