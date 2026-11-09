# Independent doc1 (VM 104) hang detection, evidence capture and recovery.
#
# doc1 cannot watch itself, and the 2026-11-09 panic hung it for 9h after kdump
# failed. Two halves:
#
#   doc1RescueProm (on doc1): installs a forced-command wrapper on prom plus an
#     authorized_keys entry that lets doc2's key run ONLY that wrapper.
#   doc1Recovery (on doc2): a per-minute watcher. It pages "doc1 DOWN" early,
#     and on a sustained hang asks prom to dump guest memory host-side (QEMU
#     dump-guest-memory, independent of the dead guest kernel), sends an NMI in
#     case kdump can still run, then resets the VM and pages again.
#
# Least privilege: doc2 never gets a shell on prom. The wrapper accepts only
# status|dump|nmi|reset for VM 104, and re-verifies on prom itself that doc1 is
# really dead (VM running for 30+ min, QGA silent, TCP/22 dead from prom) before
# any action. Memory dumps stay on prom; doc2 can start one but never read it
# (doc1's RAM holds every secret it has).
#
# See docs/wiki/infrastructure/fleet-crash-capture.md ("doc1 hang recovery").
{
  config,
  lib,
  pkgs,
  ...
}: let
  promCfg = config.homelab.services.doc1RescueProm;
  cfg = config.homelab.services.doc1Recovery;

  wrapperPath = "/usr/local/libexec/doc1-rescue";
  keyComment = "doc1-rescue@doc2";

  # Runs on prom (Debian/PVE), so it uses prom's own tools, not store paths.
  promWrapper = pkgs.writeText "doc1-rescue" ''
    #!/bin/bash
    # Installed by doc1's doc1-rescue-prom-sync.service from nixosconfig
    # (modules/nixos/services/doc1-recovery.nix). Do not edit on prom.
    set -euo pipefail
    umask 077
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin

    vmid=${toString promCfg.vmid}
    doc1=${promCfg.doc1Address}
    state=/var/lib/doc1-rescue
    dumps=${promCfg.dumpDir}
    min_uptime=${toString promCfg.minimumVmUptimeSeconds}
    reset_cooldown=${toString promCfg.resetCooldownSeconds}
    min_free_gib=${toString promCfg.minimumFreeGiB}
    keep=${toString promCfg.keepDumps}
    mkdir -p "$state" "$dumps"

    log() { logger -t doc1-rescue -- "$*"; }
    qga_ok() { timeout 8 qm guest cmd "$vmid" ping >/dev/null 2>&1; }
    tcp_ok() { timeout 4 bash -c "exec 3<>/dev/tcp/$doc1/22" >/dev/null 2>&1; }
    hmp() { printf '%s\nquit\n' "$1" | timeout 60 qm monitor "$vmid" 2>&1; }

    # Independent proof that doc1 is dead, checked on prom for every action, so
    # a compromised doc2 cannot dump, NMI or reset a healthy doc1.
    guard_dead() {
      status=$(qm status "$vmid" --verbose) || { echo "refused: qm status failed"; exit 3; }
      grep -qx 'status: running' <<<"$status" || { echo "refused: vm not running"; exit 3; }
      up=$(sed -n 's/^uptime: //p' <<<"$status")
      if [[ ! "$up" =~ ^[0-9]+$ ]] || [ "$up" -lt "$min_uptime" ]; then
        echo "refused: vm uptime ''${up:-?}s < ''${min_uptime}s"; exit 3
      fi
      if tcp_ok; then echo "refused: doc1 TCP/22 answers from prom"; exit 3; fi
      if qga_ok; then echo "refused: doc1 QGA answers"; exit 3; fi
    }

    # Internal entry point, reachable only via systemd-run below: sshd always
    # runs the forced command without arguments.
    if [ "''${1:-}" = internal-dump ] && [ -z "''${SSH_ORIGINAL_COMMAND:-}" ]; then
      stamp=$2
      [[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || exit 2
      d="$dumps/$stamp"
      mkdir -p "$d"
      result() { printf '%s %s %s\n' "$1" "$stamp" "''${2:-}" > "$state/dump-result"; log "dump $1 $stamp ''${2:-}"; }
      qm status "$vmid" --verbose > "$d/qm-status.txt" 2>&1 || true
      qm config "$vmid" > "$d/qm-config.txt" 2>&1 || true
      hmp 'info status' > "$d/info-status.txt" || true
      hmp 'info cpus' > "$d/info-cpus.txt" || true
      hmp 'info registers -a' > "$d/info-registers.txt" || true
      tail -n 5000 /var/log/doc1-serial.log > "$d/doc1-serial-tail.log" 2>/dev/null || true
      # -z -R: raw kdump-compressed (zlib) core that crash(8) reads directly.
      # -d: detach; progress is polled with "info dump".
      hmp "dump-guest-memory -d -z -R $d/vmcore.kdump" > "$d/dump-start.txt" || true
      deadline=$(( $(date +%s) + ${toString promCfg.dumpTimeoutSeconds} ))
      while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 15
        info=$(hmp 'info dump' || true)
        printf '%s\n' "$info" > "$d/dump-progress.txt"
        if grep -q 'Status: completed' <<<"$info"; then
          result "done" "$(du -h "$d/vmcore.kdump" 2>/dev/null | cut -f1)"
          exit 0
        fi
        if grep -qE 'Status: (failed|none)' <<<"$info"; then
          result failed "qemu-reported"
          exit 1
        fi
      done
      result failed timeout
      exit 1
    fi

    case "''${SSH_ORIGINAL_COMMAND:-}" in
      status)
        status=$(qm status "$vmid" --verbose 2>/dev/null) || { echo "qm: error"; exit 0; }
        grep -E '^(status|uptime|pid|qmpstatus): ' <<<"$status" || true
        if qga_ok; then echo "qga: ok"; else echo "qga: dead"; fi
        if tcp_ok; then
          echo "prom_tcp: ok"
          # doc1 is alive: disarm the one-shot-per-outage markers.
          [ ! -e "$state/dump-result" ] || mv -f "$state/dump-result" "$state/last-dump-result"
          rm -f "$state/dumped" "$state/nmi-sent"
        else
          echo "prom_tcp: dead"
        fi
        if systemctl is-active --quiet doc1-rescue-dump.service; then
          echo "dump: running $(cat "$state/dump-stamp" 2>/dev/null || true)"
        elif [ -e "$state/dump-result" ]; then
          echo "dump: $(cat "$state/dump-result")"
        else
          echo "dump: none"
        fi
        ;;
      dump)
        guard_dead
        if systemctl is-active --quiet doc1-rescue-dump.service; then echo "dump: already running"; exit 0; fi
        if [ -e "$state/dumped" ]; then echo "refused: already dumped this outage"; exit 3; fi
        # Keep the newest keep-1 sets so the new one makes keep.
        find "$dumps" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
          | sort -rn | tail -n "+$keep" | cut -d' ' -f2- | xargs -r rm -rf --
        avail=$(df --output=avail -BG "$dumps" | tail -n1 | tr -dc 0-9)
        if [ "''${avail:-0}" -lt "$min_free_gib" ]; then
          echo "refused: only ''${avail}G free on $dumps (need $min_free_gib)"; exit 3
        fi
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        printf '%s\n' "$stamp" > "$state/dump-stamp"
        touch "$state/dumped"
        rm -f "$state/dump-result"
        systemd-run --quiet --unit=doc1-rescue-dump --collect \
          -p RuntimeMaxSec=${toString (promCfg.dumpTimeoutSeconds + 300)} \
          ${wrapperPath} internal-dump "$stamp"
        log "dump started $stamp"
        echo "dump: started $stamp"
        ;;
      nmi)
        guard_dead
        if [ -e "$state/nmi-sent" ]; then echo "refused: NMI already sent this outage"; exit 3; fi
        hmp nmi >/dev/null
        touch "$state/nmi-sent"
        log "nmi sent"
        echo "nmi: sent"
        ;;
      reset)
        guard_dead
        if systemctl is-active --quiet doc1-rescue-dump.service; then echo "refused: dump in progress"; exit 3; fi
        now=$(date +%s)
        last=$(cat "$state/last-reset" 2>/dev/null || echo 0)
        [[ "$last" =~ ^[0-9]+$ ]] || last=0
        if [ $((now - last)) -lt "$reset_cooldown" ]; then
          echo "refused: last reset $((now - last))s ago (cooldown ''${reset_cooldown}s)"; exit 3
        fi
        qm reset "$vmid"
        printf '%s\n' "$now" > "$state/last-reset"
        log "reset vm $vmid"
        echo "reset: done"
        ;;
      *)
        log "refused command: ''${SSH_ORIGINAL_COMMAND:-<none>}"
        echo "refused: allowed commands are status|dump|nmi|reset"
        exit 2
        ;;
    esac
  '';

  authorizedKeyLine = ''command="${wrapperPath}",from="${lib.concatStringsSep "," promCfg.watcherSources}",restrict ${promCfg.watcherPublicKey} ${keyComment}'';

  promKnownHosts = hostKey:
    pkgs.writeText "doc1-rescue-prom-known-hosts" ''
      ${lib.removePrefix "root@" promCfg.promHost} ${hostKey}
    '';

  promSync = pkgs.writeShellApplication {
    name = "doc1-rescue-prom-sync";
    runtimeInputs = with pkgs; [coreutils openssh];
    text = ''
      prom=${lib.escapeShellArg promCfg.promHost}
      known_hosts=/var/lib/doc1-rescue-sync/known_hosts
      install -m 0600 ${promKnownHosts promCfg.promHostKey} "$known_hosts"
      ssh_opts=(
        -i ${lib.escapeShellArg promCfg.sshKeyFile}
        -o BatchMode=yes
        -o ConnectTimeout=5
        -o IdentitiesOnly=yes
        -o StrictHostKeyChecking=yes
        -o UserKnownHostsFile="$known_hosts"
      )

      remote_dir=""
      cleanup() {
        if [ -n "$remote_dir" ]; then
          # shellcheck disable=SC2029
          ssh "''${ssh_opts[@]}" "$prom" "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
        fi
      }
      trap cleanup EXIT

      remote_dir=$(ssh "''${ssh_opts[@]}" "$prom" "umask 077; mktemp -d /run/doc1-rescue-sync.XXXXXX")
      if [[ ! "$remote_dir" =~ ^/run/doc1-rescue-sync\.[A-Za-z0-9]{6}$ ]]; then
        echo "unsafe remote staging path: $remote_dir" >&2
        exit 1
      fi
      scp "''${ssh_opts[@]}" ${promWrapper} "$prom:$remote_dir/wrapper"
      # The validated staging path is deliberately expanded locally.
      # shellcheck disable=SC2029
      printf '%s\n' ${lib.escapeShellArg authorizedKeyLine} \
        | ssh "''${ssh_opts[@]}" "$prom" "cat > '$remote_dir/keyline'"

      # /root/.ssh/authorized_keys on PVE is a symlink into pmxcfs
      # (/etc/pve/priv), so it is rewritten in place, never replaced by mv.
      # Every line not carrying our comment must survive; a mismatch after the
      # write restores the backup.
      # shellcheck disable=SC2029,SC2016
      ssh "''${ssh_opts[@]}" "$prom" "
        set -eu
        install -D -m 0755 '$remote_dir/wrapper' ${wrapperPath}.new
        mv -f ${wrapperPath}.new ${wrapperPath}
        ak=\$(readlink -f /root/.ssh/authorized_keys)
        want='$remote_dir/want'
        grep -v ' ${keyComment}\$' \"\$ak\" > \"\$want\" || true
        cat '$remote_dir/keyline' >> \"\$want\"
        if cmp -s \"\$want\" \"\$ak\"; then echo 'authorized_keys: unchanged'; exit 0; fi
        before=\$(grep -vc ' ${keyComment}\$' \"\$ak\" || true)
        after=\$(grep -vc ' ${keyComment}\$' \"\$want\" || true)
        [ \"\$before\" = \"\$after\" ] || { echo 'refusing: unrelated key count changed' >&2; exit 1; }
        cp -p \"\$ak\" /root/authorized_keys.bak-doc1-rescue
        cat \"\$want\" > \"\$ak\"
        if ! cmp -s \"\$want\" \"\$ak\"; then
          cat /root/authorized_keys.bak-doc1-rescue > \"\$ak\"
          echo 'authorized_keys write verification failed; restored backup' >&2
          exit 1
        fi
        echo 'authorized_keys: updated'
      "
    '';
  };

  sendNegativeAlert = import ../lib/negative-alert.nix {inherit config lib pkgs;};

  watcher = pkgs.writeShellApplication {
    name = "doc1-recovery-check";
    runtimeInputs = with pkgs; [coreutils gnugrep gnused netcat-openbsd openssh util-linux];
    # negative-alert.nix interpolates the Gotify URL at build time.
    excludeShellChecks = ["SC2157"];
    text = ''
      set -uo pipefail
      ${sendNegativeAlert}
      state=/var/lib/doc1-recovery
      known_hosts="$state/known_hosts"
      install -m 0600 ${promKnownHosts cfg.promHostKey} "$known_hosts"
      exec 9>"$state/lock"
      flock -n 9 || exit 0

      doc1=${lib.escapeShellArg cfg.doc1Address}
      page_threshold=${toString cfg.pageThreshold}
      action_threshold=${toString cfg.actionThreshold}
      nmi_grace=${toString cfg.nmiGraceSeconds}

      prom() {
        timeout "''${2:-20}" ssh -i ${lib.escapeShellArg cfg.sshKeyFile} \
          -o BatchMode=yes -o ConnectTimeout=5 -o IdentitiesOnly=yes \
          -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$known_hosts" \
          ${lib.escapeShellArg cfg.promHost} "$1"
      }
      # Direct Gotify: Hermes (the RCA path) runs on doc1, the host that is down.
      page() { send_gotify_alert "$1" "$2" "$3"; echo "DOC1-RECOVERY page: $1"; }
      field() { sed -n "s/^$1: //p" <<<"$status" | head -n1; }
      counter() { local v; v=$(cat "$state/$1" 2>/dev/null || echo 0); [[ "$v" =~ ^[0-9]+$ ]] || v=0; echo "$v"; }

      now=$(date +%s)
      # A gap in observation (prom unreachable, timer stalled) breaks the
      # consecutive-failure proof: never carry a nearly armed counter across it.
      last=$(counter last-observation)
      if [ "$last" -gt "$now" ] || [ $((now - last)) -gt 150 ]; then
        echo 0 > "$state/failures"
      fi
      echo "$now" > "$state/last-observation"

      status=$(prom status) || {
        echo 0 > "$state/failures"
        echo "DOC1-RECOVERY observer-unreachable action=none"
        exit 0
      }
      vm=$(field status); uptime=$(field uptime); qga=$(field qga)
      prom_tcp=$(field prom_tcp); dump=$(field dump)

      tcp=dead
      nc -z -w 3 "$doc1" 22 >/dev/null 2>&1 && tcp=ok
      if [ "$tcp" = ok ] || [ "$prom_tcp" = ok ]; then
        if [ -e "$state/paged-down" ]; then
          since=$(counter paged-down)
          page "doc1 recovered" "doc1 (VM 104) answers again after ~$(( (now - since) / 60 + ${toString cfg.pageThreshold} )) min down. Watcher stage reached: $(cat "$state/stage" 2>/dev/null || echo none). Last dump: ''${dump:-none}. Host-side dumps: root@prom:${promCfg.dumpDir}/ (journal: ssh root@prom journalctl -t doc1-rescue)." 7
        fi
        rm -f "$state/paged-down" "$state/stage"
        echo 0 > "$state/failures"
        exit 0
      fi

      failures=$(( $(counter failures) + 1 ))
      echo "$failures" > "$state/failures"
      echo "DOC1-RECOVERY unhealthy failures=$failures vm=$vm uptime=$uptime qga=$qga prom_tcp=$prom_tcp dump=$dump"

      if [ "$failures" -ge "$page_threshold" ] && [ ! -e "$state/paged-down" ]; then
        echo "$now" > "$state/paged-down"
        page "doc1 (VM 104) is DOWN" "doc1 has not answered TCP/22 (from doc2 and from prom) for $failures min. VM: ''${vm:-?}, uptime ''${uptime:-?}s, guest agent: ''${qga:-?}. Every doc1-hosted service is affected; ignore their individual Kuma pages. If it is still dead at $action_threshold min the doc2 watcher dumps guest memory on prom, sends an NMI, then resets VM 104. Runbook: docs/wiki/infrastructure/fleet-crash-capture.md." 10
      fi

      [ "$failures" -ge "$action_threshold" ] || exit 0
      if [ "$vm" != running ] || [ "$qga" != dead ]; then
        echo "DOC1-RECOVERY no-action vm=$vm qga=$qga (only a running VM with a dead guest agent is recovered)"
        exit 0
      fi

      stage=none
      stage_at=0
      if [ -s "$state/stage" ]; then
        read -r stage stage_at < "$state/stage" || true
      fi
      [[ "$stage_at" =~ ^[0-9]+$ ]] || stage_at=0
      case "$stage" in
        none)
          out=$(prom dump 2>&1) || true
          echo "DOC1-RECOVERY dump-request: $out"
          if [[ "$out" == "dump: started"* || "$out" == "dump: already running"* ]]; then
            echo "dumping $now" > "$state/stage"
          else
            echo "nmi $now" > "$state/stage"
          fi
          ;;
        dumping)
          case "$dump" in
            running*) exit 0 ;;
            *) echo "nmi $now" > "$state/stage" ;;
          esac
          ;;
        nmi)
          out=$(prom nmi 2>&1) || true
          echo "DOC1-RECOVERY nmi-request: $out"
          echo "nmi-sent $now" > "$state/stage"
          ;;
        nmi-sent)
          if [ $((now - stage_at)) -lt "$nmi_grace" ]; then
            echo "DOC1-RECOVERY awaiting-kdump age=$((now - stage_at)) grace=$nmi_grace"
            exit 0
          fi
          if [ "''${DOC1_RECOVERY_DRY_RUN:-0}" = 1 ]; then
            echo "DOC1-RECOVERY dry-run would-reset"
            exit 0
          fi
          out=$(prom reset 2>&1) || true
          echo "DOC1-RECOVERY reset-request: $out"
          echo "reset $now" > "$state/stage"
          page "doc1 (VM 104) reset by doc2 watcher" "doc1 stayed dead for $failures min. Memory dump: ''${dump:-none} (root@prom:${promCfg.dumpDir}/). NMI sent ~$((nmi_grace / 60)) min ago without recovery. Reset result: $out. Check the crash-captured page once doc1 is up." 10
          ;;
        reset)
          # One automated reset per outage; anything beyond needs a human.
          exit 0
          ;;
      esac
    '';
  };
in {
  options.homelab.services = {
    doc1RescueProm = {
      enable = lib.mkEnableOption "the prom-side doc1 rescue wrapper (run on doc1, which installs it)";
      promHost = lib.mkOption {
        type = lib.types.str;
        default = "root@192.168.1.12";
      };
      promHostKey = lib.mkOption {
        type = lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/=]+";
        default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxgJAe0s4TmE6fPADxB4EAEERKZ5Q1B0kTQiqQuckVd";
        description = "Pinned prom host key; first-use trust is forbidden.";
      };
      sshKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "doc1's existing root@prom key used to install the wrapper.";
      };
      watcherPublicKey = lib.mkOption {
        type = lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/=]+";
        description = "doc2's rescue public key; prom lets it run only the wrapper.";
      };
      watcherSources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["192.168.1.35" "192.168.1.36"];
        description = "Source addresses the rescue key is accepted from (doc2 is dual-homed).";
      };
      vmid = lib.mkOption {
        type = lib.types.ints.positive;
        default = 104;
      };
      doc1Address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.29";
      };
      dumpDir = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/doc1-crash";
      };
      keepDumps = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2;
      };
      minimumFreeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        # doc1 has 44 GiB RAM; a zlib kdump of it is far smaller, but never
        # let a dump fill prom's root pool.
        default = 80;
      };
      dumpTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 2400;
      };
      minimumVmUptimeSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1800;
      };
      resetCooldownSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1800;
      };
    };

    doc1Recovery = {
      enable = lib.mkEnableOption "the doc1 hang watcher (run on doc2)";
      promHost = lib.mkOption {
        type = lib.types.str;
        default = "root@192.168.1.12";
      };
      promHostKey = lib.mkOption {
        type = lib.types.strMatching "ssh-ed25519 [A-Za-z0-9+/=]+";
        default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKxgJAe0s4TmE6fPADxB4EAEERKZ5Q1B0kTQiqQuckVd";
      };
      sshKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "doc2's forced-command rescue key for prom.";
      };
      doc1Address = lib.mkOption {
        type = lib.types.str;
        default = "192.168.1.29";
      };
      pageThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "Consecutive dead minutes before the 'doc1 is DOWN' page.";
      };
      actionThreshold = lib.mkOption {
        type = lib.types.ints.positive;
        # doc1's own kdump path (15-min save deadline + boot) must get its
        # chance before the host-side dump pauses the VM.
        default = 25;
        description = "Consecutive dead minutes before dump -> NMI -> reset begins.";
      };
      nmiGraceSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 1200;
        description = "Wait after the NMI for kdump to save and reboot before resetting.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf promCfg.enable {
      systemd.services.doc1-rescue-prom-sync = {
        description = "Install the doc1 rescue wrapper and doc2's forced-command key on prom";
        wantedBy = ["multi-user.target"];
        wants = ["network-online.target"];
        after = ["network-online.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe promSync;
          StateDirectory = "doc1-rescue-sync";
          StateDirectoryMode = "0700";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
        };
      };
    })

    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.actionThreshold >= 25 && cfg.actionThreshold > cfg.pageThreshold;
          message = "doc1Recovery.actionThreshold must outlast doc1's own kdump window and follow the page";
        }
      ];
      sops.secrets."doc1-recovery/key" = {
        sopsFile = config.homelab.secrets.sopsFile "doc1-rescue-key";
        format = "binary";
        owner = "root";
        group = "root";
        mode = "0400";
      };
      homelab.services.doc1Recovery.sshKeyFile = lib.mkDefault config.sops.secrets."doc1-recovery/key".path;

      systemd.services.doc1-recovery = {
        description = "Detect, capture and recover a hung doc1 VM";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe watcher;
          StateDirectory = "doc1-recovery";
          StateDirectoryMode = "0700";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          TimeoutStartSec = "5min";
        };
      };
      systemd.timers.doc1-recovery = {
        description = "Per-minute doc1 hang watcher";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "1min";
          AccuracySec = "10s";
        };
      };
    })
  ];
}
