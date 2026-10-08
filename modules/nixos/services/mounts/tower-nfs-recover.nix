# Recover from booting while tower is down.
#
# Static tower mounts (nfs-local.nix, static magazines-nfs.nix) are plain hard
# mounts. When this host boots before tower is exporting (whole-house power cut:
# prom/doc1/doc2 are back in ~3 min, tower's array takes ~6), the mount times out
# once and every unit with RequiresMountsFor on it is cancelled with result
# 'dependency'. Those units sit at inactive (not failed), so neither systemd nor
# the NFS watchdogs (which only act on is-failed) ever retry them. 2026-10-08
# left forgejo, immich, paperless, komga, syncthing, doc1 nginx, ... down until
# they were started by hand.
#
# This timer closes that gap: once tower lists the export, start any tower mount
# that is down, then start every enabled unit whose most recent job this boot
# ended in 'dependency'. Bounded per unit per boot so an unrelated broken
# dependency can't loop. See docs/wiki/infrastructure/tower-boot-race.md.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}: let
  cfg = config.homelab.mounts.towerRecover;
  nfsLocal = config.homelab.mounts.nfsLocal;
  mags = config.homelab.mounts.magazines;
  server = "192.168.1.2";

  # mountpoint -> tower export, for the STATIC tower mounts only. Automount
  # (roaming) hosts recover on access and never cancel their dependents.
  staticMounts =
    lib.optional nfsLocal.enable {
      inherit (nfsLocal) mountPoint;
      export = "/mnt/user/data";
    }
    ++ lib.optional (mags.enable && !mags.automount && !mags.external) {
      inherit (mags) mountPoint;
      export = "/mnt/user/magazines";
    };

  mountList = lib.concatMapStringsSep "\n" (m: "${utils.escapeSystemdPath m.mountPoint}.mount ${m.export}") staticMounts;

  recover = pkgs.writeShellApplication {
    name = "tower-nfs-recover";
    runtimeInputs = with pkgs; [coreutils gawk gnugrep jq nfs-utils systemd];
    text = ''
      maxAttempts=3
      state=/run/tower-nfs-recover

      if ! exports=$(timeout 20 showmount -e --no-headers ${server} 2>/dev/null | awk '{print $1}') || [ -z "$exports" ]; then
        echo "tower is not exporting yet; nothing to do"
        exit 0
      fi

      allUp=1
      while read -r unit export; do
        [ -n "$unit" ] || continue
        systemctl is-active --quiet "$unit" && continue
        if grep -qxF "$export" <<<"$exports"; then
          echo "tower exports $export but $unit is down; starting it"
          systemctl reset-failed "$unit" 2>/dev/null || true
          systemctl start "$unit" || { echo "starting $unit failed" >&2; allUp=0; }
        else
          echo "tower is up but does not list $export yet"
          allUp=0
        fi
      done <<'EOF'
      ${mountList}
      EOF

      # Only retry dependents once every tower mount is active, otherwise they
      # would just be cancelled again.
      [ "$allUp" = 1 ] || exit 0

      journalctl -b -o json JOB_RESULT=dependency --output-fields=UNIT \
        | jq -r '.UNIT // empty' | sort -u \
        | while read -r u; do
          case "$u" in *.target | *.mount | *.automount | *.slice | *.scope | *.device) continue ;; esac
          [ "$(systemctl is-enabled "$u" 2>/dev/null)" = enabled ] || continue
          [ "$(systemctl show -p ActiveState --value "$u")" = inactive ] || continue
          # Respect a later manual stop: act only if the unit's LAST job this
          # boot was the dependency cancellation.
          last=$(journalctl -b -o json UNIT="$u" --output-fields=JOB_RESULT \
            | jq -rs 'map(select(.JOB_RESULT)) | last | .JOB_RESULT // empty')
          [ "$last" = dependency ] || continue
          f="$state/$(systemd-escape "$u")"
          n=$(cat "$f" 2>/dev/null || echo 0)
          if [ "$n" -ge "$maxAttempts" ]; then
            echo "$u: still cancelled after $maxAttempts recovery attempts; leaving it" >&2
            continue
          fi
          echo $((n + 1)) >"$f"
          echo "starting $u (its start was cancelled by a failed dependency this boot)"
          systemctl start --no-block "$u"
        done
    '';
  };
in {
  options.homelab.mounts.towerRecover.enable = lib.mkOption {
    type = lib.types.bool;
    default = staticMounts != [];
    defaultText = lib.literalMD "true when a static tower NFS mount is enabled";
    description = ''
      Periodically mount tower's static NFS exports once tower is serving them
      and start units whose boot-time start was cancelled because a tower
      mount was missing.
    '';
  };

  config = lib.mkIf cfg.enable {
    systemd.services.tower-nfs-recover = {
      description = "Recover tower NFS mounts and their cancelled dependents";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe recover;
        # Root is needed only to start units over D-Bus; nothing here writes
        # outside its RuntimeDirectory.
        RuntimeDirectory = "tower-nfs-recover";
        RuntimeDirectoryPreserve = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # A mount start can block on a slow tower; give it room.
        TimeoutStartSec = "5min";
      };
    };

    systemd.timers.tower-nfs-recover = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitInactiveSec = "2min";
      };
    };
  };
}
