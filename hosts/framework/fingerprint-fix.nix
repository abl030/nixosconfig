# fingerprint-fix.nix
# Target: Framework 13 AMD + Goodix 27c6:609c
# Idea:
#  - Stop fprintd before sleep/hibernate to avoid “dirty handles”.
#  - On resume, do NOT forcibly start fprintd; let GDM/dbus start it.
#  - But when fprintd starts, block in ExecStartPre until the device is actually “ready”.
#
# Import this module from your host config.
{
  lib,
  pkgs,
  ...
}: let
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
        # keep it awake
        [ -w "$dev/power/control" ] && echo on > "$dev/power/control" || true
        [ -w "$dev/power/persist" ] && echo 1 > "$dev/power/persist" || true

        # if authorized exists, require it to be 1
        if [ -r "$dev/authorized" ]; then
          auth="$(cat "$dev/authorized" 2>/dev/null || echo 1)"
          if [ "$auth" != "1" ]; then
            sleep 0.2
            continue
          fi
        fi

        # small extra “enumeration is complete” hint (often present when ready)
        if [ -r "$dev/bConfigurationValue" ]; then
          cfg="$(cat "$dev/bConfigurationValue" 2>/dev/null || true)"
          if [ -z "$cfg" ]; then
            sleep 0.2
            continue
          fi
        fi

        # runtime PM readiness
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
    exit 1  # causes fprintd start to fail => Restart=on-failure will retry
  '';

  sleepHook = pkgs.writeShellScript "goodix-fprintd-sleep-hook" ''
    set -euo pipefail
    log() { echo "[goodix-fprintd] $*" | ${pkgs.systemd}/bin/systemd-cat -t goodix-fprintd -p info; }

    case "$1" in
      pre)
        log "pre-sleep: stopping fprintd to avoid in-flight ops during sleep"
        ${pkgs.systemd}/bin/systemctl stop fprintd.service || true

        # give it a moment to exit cleanly
        for i in 1 2 3 4 5; do
          ${pkgs.systemd}/bin/systemctl is-active --quiet fprintd.service || exit 0
          sleep 0.2
        done

        log "pre-sleep: fprintd still active; killing to avoid dirty libusb handles"
        ${pkgs.procps}/bin/pkill -x fprintd || true
        ;;
      post)
        # Do NOT start fprintd here.
        # Let GNOME/GDM D-Bus activation start it when needed,
        # but we can “warm up” the USB PM state a little.
        log "post-resume: waiting briefly for Goodix to be ready (non-fatal)"
        ${waitGoodixReady} || true
        ;;
    esac
  '';
in {
  services.fprintd.enable = true;

  # Keep the device from runtime autosuspending (helps reduce the “still suspended” window)
  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="usb", ATTR{idVendor}=="${vid}", ATTR{idProduct}=="${pid}", \
      ATTR{power/control}="on", ATTR{power/persist}="1"
  '';

  # Make fprintd wait for the device to be truly ready whenever it starts
  systemd.services.fprintd = {
    serviceConfig = {
      ExecStartPre = lib.mkBefore ["${waitGoodixReady}"];

      Restart = "on-failure";
      RestartSec = "2s";
    };

    # Prevent pathological restart storms if the device never comes back
    unitConfig = {
      StartLimitIntervalSec = 60;
      StartLimitBurst = 10;
    };
  };

  # systemd sleep hook (runs pre + post for suspend/hibernate)
  environment.etc."systemd/system-sleep/goodix-fprintd" = {
    source = sleepHook;
    mode = "0755";
  };
}
