{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.framework.fingerprintFix;
  vid = "27c6";
  pid = "609c";

  waitGoodixReady = pkgs.writeShellScript "wait-goodix-ready" ''
    set -euo pipefail
    deadline=$((SECONDS+10))  # hibernate can be slower than suspend

    log_info() {
      echo "[wait-goodix] $*" | ${pkgs.systemd}/bin/systemd-cat -t goodix-fprintd -p info
    }
    log_warn() {
      echo "[wait-goodix] $*" | ${pkgs.systemd}/bin/systemd-cat -t goodix-fprintd -p warning
    }

    find_dev() {
      for d in /sys/bus/usb/devices/*; do
        [ -f "$d/idVendor" ] || continue
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = "${vid}" ] && \
           [ "$(cat "$d/idProduct" 2>/dev/null)" = "${pid}" ]; then
          echo "$d"
          return 0
        fi
      done
      return 1
    }

    while [ $SECONDS -lt $deadline ]; do
      dev="$(find_dev 2>/dev/null || true)"
      if [ -n "$dev" ]; then
        [ -w "$dev/power/control" ] && echo on > "$dev/power/control" || true
        [ -w "$dev/power/persist" ] && echo 1 > "$dev/power/persist" || true

        if [ -r "$dev/authorized" ]; then
          auth="$(cat "$dev/authorized" 2>/dev/null || echo 1)"
          if [ "$auth" != "1" ]; then
            sleep 0.2
            continue
          fi
        fi

        if [ -r "$dev/bConfigurationValue" ]; then
          cfg_val="$(cat "$dev/bConfigurationValue" 2>/dev/null || true)"
          if [ -z "$cfg_val" ]; then
            sleep 0.2
            continue
          fi
        fi

        if [ -r "$dev/power/runtime_status" ]; then
          st="$(cat "$dev/power/runtime_status" 2>/dev/null || true)"
          if [ "$st" = "active" ]; then
            log_info "Device ready at $dev (runtime_status=active)"
            exit 0
          fi
        else
          log_info "Device ready at $dev (no runtime_status)"
          exit 0
        fi
      fi

      sleep 0.2
    done

    log_warn "Timeout waiting for ${vid}:${pid}"
    exit 1
  '';

  sleepHook = pkgs.writeShellScript "goodix-fprintd-sleep-hook" ''
    set -euo pipefail
    log() { echo "[goodix-fprintd] $*" | ${pkgs.systemd}/bin/systemd-cat -t goodix-fprintd -p info; }

    case "$1" in
      pre)
        log "pre-sleep: stopping fprintd to avoid in-flight ops during sleep"
        ${pkgs.systemd}/bin/systemctl stop fprintd.service || true

        for i in 1 2 3 4 5; do
          ${pkgs.systemd}/bin/systemctl is-active --quiet fprintd.service || exit 0
          sleep 0.2
        done

        log "pre-sleep: fprintd still active; killing to avoid dirty libusb handles"
        ${pkgs.procps}/bin/pkill -x fprintd || true
        ;;
      post)
        log "post-resume: waiting briefly for Goodix to be ready (non-fatal)"
        ${waitGoodixReady} || true
        ;;
    esac
  '';
in {
  options.homelab.framework.fingerprintFix = {
    enable = lib.mkEnableOption "Framework Goodix fingerprint resume fix";
  };

  config = lib.mkIf cfg.enable {
    services.fprintd.enable = true;

    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${vid}", ATTR{idProduct}=="${pid}", \
        ATTR{power/control}="on", ATTR{power/persist}="1"
    '';

    systemd.services.fprintd = {
      serviceConfig = {
        ExecStartPre = lib.mkBefore ["${waitGoodixReady}"];
        Restart = "on-failure";
        RestartSec = "2s";
      };

      unitConfig = {
        StartLimitIntervalSec = 60;
        StartLimitBurst = 10;
      };
    };

    environment.etc."systemd/system-sleep/goodix-fprintd" = {
      source = sleepHook;
      mode = "0755";
    };
  };
}
