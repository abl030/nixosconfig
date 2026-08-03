# Independent doc2 panic capture and recovery, running on doc1.
#
# A sustained TCP/22 failure triggers evidence capture. QGA availability controls
# the action: a responsive agent gets SysRq/task stacks and no reset; when both
# paths are dead the watchdog captures host/QMP evidence before resetting VM 114.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.doc2Recovery;

  promKnownHosts = pkgs.writeText "doc2-recovery-prom-known-hosts" ''
    ${cfg.promReceiverAddress} ${cfg.promHostKey}
  '';

  # prom is not NixOS-managed, so doc1 materialises this tiny source-filtered
  # receiver over the already-scoped root@prom operations key. A dedicated port
  # prevents production panic text being mixed into issue-51 lab logs again.
  promReceiver = pkgs.writeText "doc2-netconsole-receiver.py" ''
    #!/usr/bin/env python3
    import argparse
    import datetime
    import os
    import signal
    import socket
    import struct
    import time

    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--source", action="append", required=True)
    parser.add_argument("--log", required=True)
    args = parser.parse_args()

    allowed = set(args.source)
    os.makedirs(os.path.dirname(args.log), mode=0o700, exist_ok=True)

    reopen_requested = False
    stop_requested = False

    def request_reopen(_signum, _frame):
      global reopen_requested
      reopen_requested = True

    def request_stop(_signum, _frame):
      global stop_requested
      stop_requested = True

    def open_log():
      return os.open(args.log, os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)

    def write_all(fd, data):
      view = memoryview(data)
      while view:
        written = os.write(fd, view)
        if written <= 0:
          raise OSError("short write to netconsole log")
        view = view[written:]

    signal.signal(signal.SIGHUP, request_reopen)
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    fd = open_log()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    so_rxq_ovfl = getattr(socket, "SO_RXQ_OVFL", 40)
    sock.setsockopt(socket.SOL_SOCKET, so_rxq_ovfl, 1)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.1)

    effective_rcvbuf = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
    started = datetime.datetime.now(datetime.UTC).isoformat(timespec="microseconds")
    write_all(fd, f"{started} source=receiver event=start rcvbuf={effective_rcvbuf}\n".encode())
    os.fdatasync(fd)

    dirty = False
    last_drop_count = 0
    last_sync = time.monotonic()
    while not stop_requested:
      if reopen_requested:
        if dirty:
          os.fdatasync(fd)
          dirty = False
        os.close(fd)
        fd = open_log()
        reopen_requested = False
      try:
        payload, ancdata, _flags, peer = sock.recvmsg(65535, socket.CMSG_SPACE(4))
      except TimeoutError:
        payload = None
        ancdata = []
      for level, kind, data in ancdata:
        if level == socket.SOL_SOCKET and kind == so_rxq_ovfl and len(data) >= 4:
          drop_count = struct.unpack("=I", data[:4])[0]
          if drop_count != last_drop_count:
            stamp = datetime.datetime.now(datetime.UTC).isoformat(timespec="microseconds")
            write_all(fd, f"{stamp} source=receiver event=udp-drop total={drop_count}\n".encode())
            last_drop_count = drop_count
            dirty = True
      if payload is not None:
        source = peer[0]
        if source in allowed:
          stamp = datetime.datetime.now(datetime.UTC).isoformat(timespec="microseconds")
          lines = payload.splitlines() or [b""]
          for line in lines:
            record = stamp.encode() + b" source=" + source.encode() + b" " + line + b"\n"
            write_all(fd, record)
          dirty = True
      now = time.monotonic()
      if dirty and (now - last_sync >= 0.1 or reopen_requested or stop_requested):
        os.fdatasync(fd)
        dirty = False
        last_sync = now


    if dirty:
      os.fdatasync(fd)
    os.close(fd)
  '';

  promReceiverUnit = pkgs.writeText "doc2-netconsole-receiver.service" ''
    [Unit]
    Description=Receive source-filtered doc2 kernel netconsole records
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=simple
    DynamicUser=yes
    LogsDirectory=doc2-netconsole
    LogsDirectoryMode=0700
    UMask=0077
    ExecStart=/usr/local/libexec/doc2-netconsole-receiver.py --bind ${cfg.promReceiverAddress} --port ${toString cfg.netconsolePort} --source ${cfg.doc2Address} --source ${cfg.doc2SecondaryAddress} --log /var/log/doc2-netconsole/kernel.log
    ExecStartPost=/bin/sh -c 'i=0; while [ "$i" -lt 50 ]; do /usr/bin/ss -H -lun | /usr/bin/grep -Eq "[.:]${toString cfg.netconsolePort}[[:space:]]" && exit 0; i=$((i + 1)); sleep 0.1; done; exit 1'
    Restart=always
    RestartSec=5s
    NoNewPrivileges=yes
    PrivateDevices=yes
    PrivateTmp=yes
    ProtectHome=yes
    ProtectSystem=strict
    RestrictAddressFamilies=AF_INET

    [Install]
    WantedBy=multi-user.target
  '';

  receiverHealthCommand = ''
    pid=$(systemctl show -p MainPID --value doc2-netconsole-receiver.service) &&
    rules=$(iptables-save) &&
    rule_primary=$(printf '%s\n' "$rules" | grep -nFx -- '-A PVEFW-HOST-IN -s ${cfg.doc2Address}/32 -p udp -m udp --dport ${toString cfg.netconsolePort} -j RETURN' | head -n 1 | cut -d: -f1) &&
    rule_secondary=$(printf '%s\n' "$rules" | grep -nFx -- '-A PVEFW-HOST-IN -s ${cfg.doc2SecondaryAddress}/32 -p udp -m udp --dport ${toString cfg.netconsolePort} -j RETURN' | head -n 1 | cut -d: -f1) &&
    drop_rule=$(printf '%s\n' "$rules" | grep -nFx -- '-A PVEFW-HOST-IN -j PVEFW-Drop' | tail -n 1 | cut -d: -f1) &&
    systemctl is-active --quiet doc2-netconsole-receiver.service &&
    test "$pid" -gt 0 &&
    test -f /var/log/doc2-netconsole/kernel.log &&
    grep -Fqx 'IN ACCEPT -source ${cfg.doc2Address},${cfg.doc2SecondaryAddress} -p udp -dport ${toString cfg.netconsolePort} -log nolog' /etc/pve/nodes/prom/host.fw &&
    test -n "$rule_primary" && test -n "$rule_secondary" && test -n "$drop_rule" &&
    test "$rule_primary" -lt "$drop_rule" && test "$rule_secondary" -lt "$drop_rule" &&
    ss -H -lunp | grep -F ':${toString cfg.netconsolePort}' | grep -F "pid=$pid,"
  '';

  promReceiverLogrotate = pkgs.writeText "doc2-netconsole-logrotate" ''
    /var/log/doc2-netconsole/kernel.log {
      weekly
      size 16M
      rotate 8
      compress
      missingok
      notifempty
      sharedscripts
      postrotate
        if ! /bin/systemctl kill -s HUP doc2-netconsole-receiver.service >/dev/null 2>&1; then
          /bin/systemctl restart doc2-netconsole-receiver.service
        fi
        i=0
        while [ "$i" -lt 50 ] && [ ! -f /var/log/doc2-netconsole/kernel.log ]; do
          i=$((i + 1))
          /bin/sleep 0.1
        done
        if [ ! -f /var/log/doc2-netconsole/kernel.log ]; then
          /bin/systemctl restart doc2-netconsole-receiver.service
        fi
      endscript
    }
  '';

  promReceiverSync = pkgs.writeShellApplication {
    name = "doc2-netconsole-prom-sync";
    runtimeInputs = with pkgs; [coreutils gnugrep openssh];
    text = ''
      set -euo pipefail
      prom=${lib.escapeShellArg cfg.promHost}
      ssh_key=${lib.escapeShellArg cfg.sshKeyFile}
      known_hosts=/var/lib/doc2-recovery/known_hosts
      install -m 0600 ${promKnownHosts} "$known_hosts"

      ssh_opts=(
        -i "$ssh_key"
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes
        -o UserKnownHostsFile="$known_hosts"
      )

      remote_dir=""
      cleanup() {
        if [ -n "$remote_dir" ]; then
          # The path is validated below and must expand locally.
          # shellcheck disable=SC2029
          ssh "''${ssh_opts[@]}" "$prom" "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
        fi
      }
      trap cleanup EXIT

      remote_dir=$(ssh "''${ssh_opts[@]}" "$prom" "umask 077; mktemp -d /run/doc2-netconsole-sync.XXXXXX")
      if [[ ! "$remote_dir" =~ ^/run/doc2-netconsole-sync\.[A-Za-z0-9]{6}$ ]]; then
        echo "unsafe remote staging path: $remote_dir" >&2
        exit 1
      fi

      scp "''${ssh_opts[@]}" ${promReceiver} "$prom:$remote_dir/receiver.py"
      scp "''${ssh_opts[@]}" ${promReceiverUnit} "$prom:$remote_dir/receiver.service"
      scp "''${ssh_opts[@]}" ${promReceiverLogrotate} "$prom:$remote_dir/logrotate"
      # The validated local staging path is deliberately interpolated; escaped
      # substitutions execute on prom.
      # shellcheck disable=SC2029,SC2140
      ssh "''${ssh_opts[@]}" "$prom" \
        "chmod 0600 '$remote_dir/receiver.py' '$remote_dir/receiver.service' '$remote_dir/logrotate' &&
         test \"\$(stat -c '%u:%a' '$remote_dir/receiver.py')\" = '0:600' && test -f '$remote_dir/receiver.py' && test ! -L '$remote_dir/receiver.py' &&
         test \"\$(stat -c '%u:%a' '$remote_dir/receiver.service')\" = '0:600' && test -f '$remote_dir/receiver.service' && test ! -L '$remote_dir/receiver.service' &&
         test \"\$(stat -c '%u:%a' '$remote_dir/logrotate')\" = '0:600' && test -f '$remote_dir/logrotate' && test ! -L '$remote_dir/logrotate' &&
         rm -f /usr/local/libexec/.doc2-netconsole-receiver.py.new /etc/systemd/system/.doc2-netconsole-receiver.service.new /etc/logrotate.d/.doc2-netconsole.new &&
         install -D -m 0755 '$remote_dir/receiver.py' /usr/local/libexec/.doc2-netconsole-receiver.py.new &&
         install -D -m 0644 '$remote_dir/receiver.service' /etc/systemd/system/.doc2-netconsole-receiver.service.new &&
         install -D -m 0644 '$remote_dir/logrotate' /etc/logrotate.d/.doc2-netconsole.new &&
         mv /usr/local/libexec/.doc2-netconsole-receiver.py.new /usr/local/libexec/doc2-netconsole-receiver.py &&
         mv /etc/systemd/system/.doc2-netconsole-receiver.service.new /etc/systemd/system/doc2-netconsole-receiver.service &&
         mv /etc/logrotate.d/.doc2-netconsole.new /etc/logrotate.d/doc2-netconsole &&
         systemctl daemon-reload &&
         systemctl enable doc2-netconsole-receiver.service &&
         systemctl restart doc2-netconsole-receiver.service &&
         systemctl is-active --quiet doc2-netconsole-receiver.service &&
         pid=\$(systemctl show -p MainPID --value doc2-netconsole-receiver.service) &&
         test \"\$pid\" -gt 0 &&
         ss -H -lunp | grep -F ":${toString cfg.netconsolePort}" | grep -Fq "pid=\$pid," &&
         grep -Fqx 'IN ACCEPT -source ${cfg.doc2Address},${cfg.doc2SecondaryAddress} -p udp -dport ${toString cfg.netconsolePort} -log nolog' /etc/pve/nodes/prom/host.fw &&
         iptables-save > '$remote_dir/iptables' &&
         rule_primary=\$(grep -nFx -- '-A PVEFW-HOST-IN -s ${cfg.doc2Address}/32 -p udp -m udp --dport ${toString cfg.netconsolePort} -j RETURN' '$remote_dir/iptables' | cut -d: -f1) &&
         rule_secondary=\$(grep -nFx -- '-A PVEFW-HOST-IN -s ${cfg.doc2SecondaryAddress}/32 -p udp -m udp --dport ${toString cfg.netconsolePort} -j RETURN' '$remote_dir/iptables' | cut -d: -f1) &&
         drop_rule=\$(grep -nFx -- '-A PVEFW-HOST-IN -j PVEFW-Drop' '$remote_dir/iptables' | tail -n 1 | cut -d: -f1) &&
         test -n \"\$rule_primary\" && test -n \"\$rule_secondary\" && test -n \"\$drop_rule\" &&
         test \"\$rule_primary\" -lt \"\$drop_rule\" && test \"\$rule_secondary\" -lt \"\$drop_rule\""
    '';
  };

  recoveryScript = pkgs.writeShellApplication {
    name = "doc2-recovery-check";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gnused
      netcat-openbsd
      openssh
      util-linux
    ];
    text = ''
      set -uo pipefail

      state_dir=/var/lib/doc2-recovery
      tcp_failures_file="$state_dir/consecutive-tcp-failures"
      dual_failures_file="$state_dir/consecutive-dual-failures"
      cooldown_file="$state_dir/cooldown-until"
      last_observation_file="$state_dir/last-observation"
      known_hosts="$state_dir/known_hosts"
      prom=${lib.escapeShellArg cfg.promHost}
      doc2_address=${lib.escapeShellArg cfg.doc2Address}
      doc2_secondary_address=${lib.escapeShellArg cfg.doc2SecondaryAddress}
      vmid=${toString cfg.vmid}
      capture_threshold=${toString cfg.captureFailureThreshold}
      reset_threshold=${toString cfg.resetFailureThreshold}
      cooldown_seconds=${toString cfg.cooldownSeconds}
      min_vm_uptime=${toString cfg.minimumVmUptimeSeconds}
      ssh_key=${lib.escapeShellArg cfg.sshKeyFile}

      mkdir -p "$state_dir/incidents"
      install -m 0600 ${promKnownHosts} "$known_hosts"
      exec 9>"$state_dir/lock"
      flock -n 9 || exit 0

      ssh_prom() {
        timeout 15 ssh -i "$ssh_key" \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=yes \
          -o UserKnownHostsFile="$known_hosts" \
          "$prom" "$@"
      }

      ssh_prom_long() {
        timeout 35 ssh -i "$ssh_key" \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=yes \
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

      last_observation=$(cat "$last_observation_file" 2>/dev/null || printf '0')
      if [ -z "$last_observation" ] || [[ "$last_observation" == *[!0-9]* ]] \
        || [ "$last_observation" -gt "$now" ] || [ "$((now - last_observation))" -gt 150 ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
      fi
      printf '%s\n' "$now" > "$last_observation_file"

      status=$(ssh_prom "qm status $vmid --verbose" 2>/dev/null) || {
        # An observation gap breaks the consecutive-failure proof. Never carry a
        # nearly armed reset counter across a prom/network outage.
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY observer-unreachable prom=$prom counters=reset action=none"
        exit 0
      }
      if ! grep -qx 'status: running' <<<"$status"; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY vm-not-running vmid=$vmid action=none"
        exit 0
      fi

      vm_uptime=$(sed -n 's/^uptime: //p' <<<"$status")
      vm_pid=$(sed -n 's/^pid: //p' <<<"$status")
      if [ -z "$vm_uptime" ] || [[ "$vm_uptime" == *[!0-9]* ]]; then
        vm_uptime=0
      fi
      if [ -z "$vm_pid" ] || [[ "$vm_pid" == *[!0-9]* ]] \
        || [ "$vm_uptime" -lt "$min_vm_uptime" ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        exit 0
      fi

      tcp_ok=0
      qga_ok=0
      if nc -z -w 3 "$doc2_address" 22 >/dev/null 2>&1 \
        || nc -z -w 3 "$doc2_secondary_address" 22 >/dev/null 2>&1; then
        tcp_ok=1
      fi
      ssh_prom "timeout 5 qm guest cmd $vmid ping >/dev/null 2>&1" >/dev/null 2>&1 && qga_ok=1

      if [ "$tcp_ok" -eq 1 ]; then
        previous=$(cat "$tcp_failures_file" 2>/dev/null || printf '0')
        if [ -n "$previous" ] && [[ "$previous" != *[!0-9]* ]] && [ "$previous" -gt 0 ]; then
          echo "DOC2-RECOVERY recovered-before-threshold tcp_ok=$tcp_ok qga_ok=$qga_ok"
        fi
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        exit 0
      fi

      read_counter() {
        local value
        value=$(cat "$1" 2>/dev/null || printf '0')
        if [ -z "$value" ] || [[ "$value" == *[!0-9]* ]]; then
          value=0
        fi
        printf '%s\n' "$value"
      }

      tcp_failures=$(( $(read_counter "$tcp_failures_file") + 1 ))
      printf '%s\n' "$tcp_failures" > "$tcp_failures_file"
      if [ "$qga_ok" -eq 1 ]; then
        dual_failures=0
        printf '0\n' > "$dual_failures_file"
        required=$capture_threshold
        current=$tcp_failures
        mode=capture-only
      else
        dual_failures=$(( $(read_counter "$dual_failures_file") + 1 ))
        printf '%s\n' "$dual_failures" > "$dual_failures_file"
        required=$reset_threshold
        current=$dual_failures
        mode=dual-failure
      fi
      echo "DOC2-RECOVERY unhealthy tcp_failures=$tcp_failures dual_failures=$dual_failures required=$required mode=$mode tcp_ok=0 qga_ok=$qga_ok"
      [ "$current" -ge "$required" ] || exit 0

      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      incident="$state_dir/incidents/$stamp"
      mkdir -p "$incident"
      find "$state_dir/incidents" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
        | sort -rn | tail -n +21 | cut -d' ' -f2- | xargs -r rm -rf
      printf '%s\n' "$status" > "$incident/qm-status.txt"
      ssh_prom "qm config $vmid" > "$incident/qm-config.txt" 2>&1 || true
      ssh_prom "qm pending $vmid" > "$incident/qm-pending.txt" 2>&1 || true
      ssh_prom "qm showcmd $vmid --pretty" > "$incident/qm-showcmd.txt" 2>&1 || true

      # Capture the untouched console before QMP interrogation or guest SysRq.
      remote_image_dir=$(ssh_prom "umask 077; mktemp -d /run/doc2-recovery-console.XXXXXX" 2>/dev/null || true)
      if [[ "$remote_image_dir" =~ ^/run/doc2-recovery-console\.[A-Za-z0-9]{6}$ ]]; then
          remote_image="$remote_image_dir/console.ppm"
          if ssh_prom "printf 'screendump $remote_image\\nquit\\n' | qm monitor $vmid >/dev/null; test -s '$remote_image'"; then
            if ssh_prom "cat '$remote_image'" > "$incident/console.ppm.tmp" 2>/dev/null; then
              mv "$incident/console.ppm.tmp" "$incident/console.ppm"
            elif [ -s "$incident/console.ppm.tmp" ]; then
              mv "$incident/console.ppm.tmp" "$incident/console.ppm.partial"
            else
              rm -f "$incident/console.ppm.tmp"
            fi
            ssh_prom "rm -rf '$remote_image_dir'" >/dev/null 2>&1 || true
          else
            ssh_prom "rm -rf '$remote_image_dir'" >/dev/null 2>&1 || true
          fi
      else
        printf '%s\n' "invalid remote screendump directory: $remote_image_dir" > "$incident/console-error.txt"
      fi

      ssh_prom "journalctl -k --since '20 minutes ago' --no-pager" > "$incident/prom-kernel.txt" 2>&1 || true
      ssh_prom "journalctl --since '20 minutes ago' --no-pager | grep -Ei 'qemu|kvm|qga|VM $vmid|vhost|virtiofs|oom|mce|hardware error'" \
        > "$incident/prom-vm.txt" 2>&1 || true
      ssh_prom "tail -n 20000 /var/log/doc2-netconsole/kernel.log" \
        > "$incident/doc2-netconsole.txt" 2>&1 || true
      ssh_prom "pvesh get /nodes/\$(hostname)/qemu/$vmid/rrddata --timeframe hour --cf AVERAGE --output-format json-pretty" \
        > "$incident/qm-rrd-hour.json" 2>&1 || true

      # QMP remains available when the guest kernel, TCP and QGA are all dead.
      # Preserve every vCPU register set and the host-side QEMU thread stacks
      # before reset; both are independent of guest cooperation.
      ssh_prom "printf 'info status\\ninfo cpus\\ninfo registers -a\\ninfo irq\\ninfo network\\ninfo block\\ninfo qtree\\nquit\\n' | qm monitor $vmid" \
        > "$incident/qemu-monitor.txt" 2>&1 || true
      ssh_prom "pid=\$(qm status $vmid --verbose | sed -n 's/^pid: //p'); test -n \"\$pid\"; echo === process-status ===; cat /proc/\$pid/status; echo === process-cmdline ===; tr '\\0' ' ' < /proc/\$pid/cmdline; echo; echo === threads ===; ps -eLo pid,tid,psr,stat,pcpu,wchan:32,comm --sort=tid | awk -v p=\"\$pid\" 'NR == 1 || \$1 == p'; for task in /proc/\$pid/task/*; do tid=\''${task##*/}; echo === tid=\$tid ===; cat \$task/comm \$task/wchan \$task/stack 2>&1; done" \
        > "$incident/qemu-host-threads.txt" 2>&1 || true

      # In-guest kernel state. The 2026-07-24 tty wedge was captured with WCHAN
      # only, which named the layer (64/65 tasks in tty_open) but never the lock
      # holder, so the RCA could not be closed. QGA stays responsive in exactly
      # these wedges even when SSH is dead, so drive sysrq through it:
      #   t = every task's stack, w = tasks blocked in uninterruptible sleep.
      # __handle_sysrq() raises console_loglevel for the duration, so this output
      # also reaches prom over netconsole despite doc2's loglevel=4 console filter
      # (which is why routine INFO-level records never appear there).
      # See docs/wiki/infrastructure/virtiofs-nested-reexport-stale-pins.md (#51).
      if [ "$qga_ok" -eq 1 ]; then
        qga_exec() {
          # Remote timeout exceeds qm's 20-second timeout; ssh_prom_long's
          # 35-second outer bound exceeds both, so results are not truncated.
          ssh_prom_long "timeout 25 qm guest exec $vmid --timeout 20 -- $*" 2>&1 || true
        }
        for sysrq_key in w t; do
          qga_exec "/bin/sh -c 'echo $sysrq_key > /proc/sysrq-trigger'" \
            > "$incident/sysrq-$sysrq_key.json" 2>&1 || true
        done
        # Give the task dump time to drain into the ring buffer before reading it.
        sleep 5
        qga_exec "/bin/sh -c 'dmesg --notime --level=emerg,alert,crit,err,warn,info | tail -n 2000'" \
          > "$incident/doc2-dmesg-after-sysrq.json" 2>&1 || true
        # Per-task kernel stacks for everything still stuck in D state.
        qga_exec "/bin/sh -c 'for p in \$(ls /proc | grep -E \"^[0-9]+\$\"); do s=\$(cut -d\" \" -f3 /proc/\$p/stat 2>/dev/null); [ \"\$s\" = D ] || continue; echo \"=== pid \$p \$(tr -d \"\\0\" < /proc/\$p/comm 2>/dev/null) ===\"; cat /proc/\$p/stack 2>/dev/null; done'" \
          > "$incident/doc2-dstate-stacks.json" 2>&1 || true
      else
        printf '%s\n' 'QGA unavailable at the sustained dual-failure threshold; intrusive guest probes skipped.' \
          > "$incident/qga-unavailable.txt"
      fi


      # A live QGA makes this a partial guest outage, not authorization to reset.
      # The evidence above is still valuable (notably SysRq stacks), so retain it
      # and resume observation rather than classifying the VM as healthy.
      if [ "$qga_ok" -eq 1 ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY captured-qga-only vmid=$vmid incident=$incident action=none"
        exit 0
      fi

      # Evidence collection can take several minutes. Never reset from a stale
      # health decision if either independent path recovered meanwhile.
      final_tcp_ok=0
      final_qga_ok=0
      if nc -z -w 3 "$doc2_address" 22 >/dev/null 2>&1 \
        || nc -z -w 3 "$doc2_secondary_address" 22 >/dev/null 2>&1; then
        final_tcp_ok=1
      fi
      ssh_prom "timeout 5 qm guest cmd $vmid ping >/dev/null 2>&1" >/dev/null 2>&1 && final_qga_ok=1
      if [ "$final_tcp_ok" -eq 1 ] || [ "$final_qga_ok" -eq 1 ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY recovered-during-capture tcp_ok=$final_tcp_ok qga_ok=$final_qga_ok incident=$incident action=none"
        exit 0
      fi

      final_status=$(ssh_prom "qm status $vmid --verbose" 2>/dev/null || true)
      if ! grep -qx 'status: running' <<<"$final_status"; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY vm-not-running-after-capture vmid=$vmid incident=$incident action=none"
        exit 0
      fi
      final_vm_uptime=$(sed -n 's/^uptime: //p' <<<"$final_status")
      final_vm_pid=$(sed -n 's/^pid: //p' <<<"$final_status")
      if [ -z "$final_vm_uptime" ] || [[ "$final_vm_uptime" == *[!0-9]* ]] \
        || [ -z "$final_vm_pid" ] || [[ "$final_vm_pid" == *[!0-9]* ]] \
        || [ "$final_vm_pid" -ne "$vm_pid" ] \
        || [ "$final_vm_uptime" -lt "$vm_uptime" ] \
        || [ "$final_vm_uptime" -lt "$min_vm_uptime" ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY vm-transition-after-capture vmid=$vmid incident=$incident action=none"
        exit 0
      fi
      # The command is intentionally single-quoted for expansion only by prom's shell.
      # shellcheck disable=SC2016
      if ! ssh_prom ${lib.escapeShellArg receiverHealthCommand}; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY receiver-unhealthy vmid=$vmid incident=$incident action=none"
        exit 0
      fi

      if [ "''${DOC2_RECOVERY_DRY_RUN:-0}" = 1 ]; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        echo "DOC2-RECOVERY dry-run would-reset vmid=$vmid incident=$incident"
        exit 0
      fi

      if ssh_prom "qm reset $vmid"; then
        printf '0\n' > "$tcp_failures_file"
        printf '0\n' > "$dual_failures_file"
        printf '%s\n' "$(( $(date +%s) + cooldown_seconds ))" > "$cooldown_file"
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

    promHostKey = lib.mkOption {
      type = lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/=]+";
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxgJAe0s4TmE6fPADxB4EAEERKZ5Q1B0kTQiqQuckVd";
      description = "Pinned SSH host public key for prom; first-use trust is forbidden.";
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

    captureFailureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      # A clean doc2 reboot can spend more than four minutes stopping Kopia.
      # Capture-only diagnostics therefore require sustained TCP failure.
      default = 10;
      description = "Consecutive one-minute TCP failures before QGA-assisted capture-only diagnostics.";
    };

    resetFailureThreshold = lib.mkOption {
      type = lib.types.ints.positive;
      # doc2's crash-dump writer has a 15-minute hard deadline. Five more
      # minutes cover crash-kernel boot and service teardown without racing it.
      default = 25;
      description = "Consecutive one-minute failures of both TCP and QGA before capture and reset.";
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

    netconsolePort = lib.mkOption {
      type = lib.types.port;
      default = 6667;
      description = "Dedicated doc2 netconsole UDP port on prom.";
    };

    promReceiverAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.12";
      description = "Address on prom to which the dedicated receiver binds.";
    };

    doc2SecondaryAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.36";
      description = "Second doc2 LAN address accepted by the receiver and used as an independent TCP probe.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.captureFailureThreshold >= 5;
        message = "doc2Recovery.captureFailureThreshold must require at least five consecutive failures";
      }
      {
        assertion = cfg.resetFailureThreshold >= 25;
        message = "doc2Recovery.resetFailureThreshold must outlast the bounded crash-dump transaction";
      }
      {
        assertion = cfg.resetFailureThreshold > cfg.captureFailureThreshold;
        message = "doc2Recovery reset threshold must be stricter than its capture-only threshold";
      }
      {
        assertion = cfg.promHost == "root@${cfg.promReceiverAddress}";
        message = "doc2Recovery.promHost must match the pinned prom receiver address";
      }
      {
        assertion = cfg.minimumVmUptimeSeconds >= 300;
        message = "doc2Recovery.minimumVmUptimeSeconds must protect at least five minutes of boot";
      }
    ];

    systemd.services.doc2-recovery = {
      description = "Capture and reset a persistently frozen doc2 VM";
      requires = ["doc2-netconsole-prom-sync.service"];
      after = ["doc2-netconsole-prom-sync.service"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe recoveryScript;
        StateDirectory = "doc2-recovery";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        TimeoutStartSec = "10min";
      };
    };

    systemd.services.doc2-netconsole-prom-sync = {
      description = "Install and verify the dedicated doc2 netconsole receiver on prom";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      before = ["doc2-recovery.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe promReceiverSync;
        StateDirectory = "doc2-recovery";
        StateDirectoryMode = "0700";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
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
  };
}
