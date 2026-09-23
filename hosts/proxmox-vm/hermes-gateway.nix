# Hermes gateway on doc1: the NixOS drop-in over Hermes' mutable user unit, plus
# the refresh timer that moves a running gateway onto a newly deployed build.
# NixOS switch-to-configuration only reexecs user managers; it never restarts
# changed user units, so without the refresh the gateway ran a 12-day-old build
# through every nightly deploy (#230). See docs/wiki/services/ntfy.md.
{
  lib,
  pkgs,
  config,
  ...
}: let
  user = "abl030";
  sendNegativeAlert = import ../../modules/nixos/lib/negative-alert.nix {inherit config lib pkgs;};

  # Every Nix-managed input to the gateway process. The fingerprint is stamped
  # into the process environment, so /proc/<MainPID>/environ says which deploy
  # the running gateway was started from.
  gatewayExecStart = "${pkgs.hermes-agent}/bin/hermes gateway run";
  gatewayExecStopPost = "-${pkgs.hermes-agent.hermesVenv}/bin/python -m gateway.cgroup_cleanup";
  gatewayEnvironment = [
    # MCP wrappers need the same Nix system/user executables as the CLI.
    "PATH=/run/wrappers/bin:/etc/profiles/per-user/${user}/bin:/run/current-system/sw/bin"
    "VIRTUAL_ENV=${pkgs.hermes-agent.hermesVenv}"
    "HERMES_BUNDLED_PLUGINS=${pkgs.hermes-agent}/share/hermes-agent/plugins"
    "PYTHONPATH=${pkgs.hermes-agent.hermesStateStoreModules}/${pkgs.python312.sitePackages}"
  ];
  gatewayEnvironmentFile = config.sops.secrets."hermes/ntfy-env".path;
  fingerprint = builtins.hashString "sha256" (builtins.toJSON {
    execStart = gatewayExecStart;
    execStopPost = gatewayExecStopPost;
    environment = gatewayEnvironment;
    environmentFile = gatewayEnvironmentFile;
  });

  # A gateway still stale this long after a deploy (Hermes never idle, or the
  # restart keeps failing) pages once per fingerprint.
  staleAlertSeconds = 24 * 60 * 60;

  refreshScript = pkgs.writeShellApplication {
    name = "hermes-gateway-refresh";
    runtimeInputs = [pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.systemd];
    text = ''
      desired=${fingerprint}
      # The user has no declared uid; systemctl --user finds the bus from this.
      XDG_RUNTIME_DIR="/run/user/$(id -u)"
      export XDG_RUNTIME_DIR
      unit=hermes-gateway.service
      gateway_state="$HOME/.hermes/gateway_state.json"
      stale_file="$STATE_DIRECTORY/stale-since"

      running_fingerprint() {
        local pid
        pid="$(systemctl --user show -p MainPID --value "$unit")"
        [ "$pid" != 0 ] || return 0
        sed -n 's/^HERMES_DEPLOY_FINGERPRINT=//p' <(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null) || true
      }

      if ! systemctl --user is-active --quiet "$unit"; then
        # Stopped on purpose or between Restart=always attempts; either way the
        # next start uses the deployed definition.
        echo "$unit is not active; nothing to refresh"
        rm -f "$stale_file"
        exit 0
      fi

      running="$(running_fingerprint)"
      if [ "$running" = "$desired" ]; then
        rm -f "$stale_file"
        exit 0
      fi
      echo "gateway runs fingerprint ''${running:-<none>}; deployed is $desired"

      # switch-to-configuration reexecs the user manager, but reload anyway so a
      # restart can never pick up the previous definition.
      if ! systemctl --user show -p Environment "$unit" | grep -qF "HERMES_DEPLOY_FINGERPRINT=$desired"; then
        systemctl --user daemon-reload
      fi

      # active_agents is Hermes' own drain count: chat turns, running cron jobs,
      # API runs and deferred workers. Restart only when it is provably idle.
      main_pid="$(systemctl --user show -p MainPID --value "$unit")"
      if jq -e --argjson pid "$main_pid" \
        '.pid == $pid and .gateway_state == "running" and .active_agents == 0' \
        "$gateway_state" >/dev/null 2>&1; then
        echo "gateway idle; restarting onto the deployed build"
        systemctl --user restart "$unit"
        sleep 5
        running="$(running_fingerprint)"
        if [ "$running" = "$desired" ]; then
          echo "gateway now runs fingerprint $desired"
          rm -f "$stale_file"
          exit 0
        fi
        echo "gateway restarted but runs fingerprint ''${running:-<none>}" >&2
      else
        echo "gateway busy or state unreadable; retrying on the next timer run"
      fi

      now="$(date +%s)"
      if [ ! -f "$stale_file" ] || [ "$(cut -d' ' -f1 "$stale_file")" != "$desired" ]; then
        echo "$desired $now pending" >"$stale_file"
        exit 0
      fi
      read -r _ since alerted <"$stale_file"
      if [ "$alerted" = pending ] && [ $((now - since)) -ge ${toString staleAlertSeconds} ]; then
        echo "$desired $since alerted" >"$stale_file"
        echo "gateway has run a stale build for over 24h" >&2
        exit 1
      fi
    '';
  };

  notifyFailure = pkgs.writeShellScript "hermes-gateway-refresh-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    message="$(journalctl -u hermes-gateway-refresh.service -n 40 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert "Hermes gateway still on a stale build (${config.networking.hostName})" "$message" 5
  '';
in {
  # Authenticated self-hosted ntfy channel for two-way Hermes access and
  # completion pings. This gateway-only file excludes server provisioning and
  # operator credentials.
  sops.secrets."hermes/ntfy-env" = {
    sopsFile = config.homelab.secrets.sopsFile "hosts/proxmox-vm/ntfy-gateway.env";
    format = "dotenv";
    owner = user;
    mode = "0400";
  };

  # The gateway's primary unit is installed under ~/.config/systemd/user by
  # Hermes. Force NixOS to emit only a drop-in so systemd merges the SOPS
  # environment into that mutable unit instead of shadowing it.
  systemd.user.services.hermes-gateway = {
    overrideStrategy = "asDropin";
    # Reset the mutable installer's pinned commands: core, plugins and cleanup
    # must follow the same deployed package. See docs/wiki/services/ntfy.md.
    serviceConfig = {
      ExecStart = ["" gatewayExecStart];
      ExecStopPost = ["" gatewayExecStopPost];
      Environment = gatewayEnvironment ++ ["HERMES_DEPLOY_FINGERPRINT=${fingerprint}"];
      EnvironmentFile = gatewayEnvironmentFile;
    };
  };

  systemd.services.hermes-gateway-refresh-notify-failure = {
    description = "Page when the Hermes gateway stays on a stale build";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = notifyFailure;
    };
  };

  # Runs as the gateway's owner, not root: it only needs that user's systemd
  # manager and the gateway's own state file.
  systemd.services.hermes-gateway-refresh = {
    description = "Restart an idle Hermes gateway onto the deployed build";
    unitConfig.OnFailure = ["hermes-gateway-refresh-notify-failure.service"];
    serviceConfig = {
      Type = "oneshot";
      User = user;
      ExecStart = lib.getExe refreshScript;
      StateDirectory = "hermes-gateway-refresh";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      RestrictAddressFamilies = ["AF_UNIX"];
    };
  };

  systemd.timers.hermes-gateway-refresh = {
    description = "Move the Hermes gateway onto newly deployed builds";
    wantedBy = ["timers.target"];
    # A changed fingerprint restarts the timer on switch, and OnActiveSec fires
    # the check shortly after — outside the activation transaction, so a busy
    # gateway or a 70s drain never delays the deploy.
    restartTriggers = [fingerprint];
    timerConfig = {
      OnActiveSec = "2min";
      OnCalendar = "*:0/15";
      AccuracySec = "1min";
    };
  };
}
