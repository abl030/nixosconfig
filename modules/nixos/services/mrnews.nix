# Margaret River News: static Hugo site on doc1.
#
# The live site is NOT the flake-pinned package. Posts are written by the
# Hermes Margaret River jobs, which push signed commits to the mrnews repo and
# then run `mrnews-deploy`. That starts mrnews-deploy.service (polkit-scoped to
# `deployUsers`, no sudo), which fetches master, requires a fleet-trusted SSH
# signature and a fast-forward of the live revision, builds the site with Nix,
# swaps /var/lib/mrnews/site and restarts the file server. A 15-minute timer is
# the backstop. The flake input only seeds the site on a fresh host.
# See docs/wiki/services/mrnews.md.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.mrnews;
  defaultPackage = inputs.mrnews.packages.${pkgs.system}.default;
  stateDir = "/var/lib/mrnews";
  systemctl = "${config.systemd.package}/bin/systemctl";

  deployScript = pkgs.writeShellApplication {
    name = "mrnews-deploy-run";
    runtimeInputs = [pkgs.coreutils pkgs.findutils pkgs.git pkgs.openssh config.nix.package];
    text = ''
      state=${stateDir}
      repo="$state/repo"
      export HOME="$state"

      if [ ! -d "$repo/.git" ]; then
        rm -rf "$repo"
        git init --quiet "$repo"
      fi
      git -C "$repo" fetch --quiet --no-tags ${lib.escapeShellArg cfg.repoUrl} \
        "+refs/heads/master:refs/remotes/origin/master"
      rev="$(git -C "$repo" rev-parse --verify 'refs/remotes/origin/master^{commit}')"
      current="$(cat "$state/deployed-rev" 2>/dev/null || true)"

      if [ "$rev" = "$current" ] && [ -e "$state/site/index.html" ]; then
        echo "mrnews: already live at $rev"
        exit 0
      fi

      git -C "$repo" -c gpg.format=ssh \
        -c gpg.ssh.allowedSignersFile=${lib.escapeShellArg config.homelab.update.verify.allowedSignersPath} \
        verify-commit "$rev"

      if [ -n "$current" ] && ! git -C "$repo" merge-base --is-ancestor "$current" "$rev"; then
        echo "mrnews: refusing $rev; it does not descend from live $current" >&2
        exit 1
      fi

      out="$(nix --extra-experimental-features 'nix-command flakes' build \
        --no-link --print-out-paths "git+file://$repo?rev=$rev")"
      test -s "$out/index.html"

      mkdir -p "$state/gcroots"
      nix-store --add-root "$state/gcroots/$rev" --realise "$out" >/dev/null
      ln -sfn "$out" "$state/site.new"
      mv -T "$state/site.new" "$state/site"
      printf '%s\n' "$rev" >"$state/deployed-rev.new"
      mv -T "$state/deployed-rev.new" "$state/deployed-rev"
      find "$state/gcroots" -mindepth 1 -maxdepth 1 ! -name "$rev" -delete
      touch "$state/restart-needed"
      echo "mrnews: deployed $rev ($out)"
    '';
  };

  # Root post-step: only restarts the file server, and only after a swap.
  restartIfChanged = pkgs.writeShellScript "mrnews-restart-if-changed" ''
    if [ -e ${stateDir}/restart-needed ]; then
      ${pkgs.coreutils}/bin/rm -f ${stateDir}/restart-needed
      ${systemctl} restart mrnews.service
    fi
  '';

  # Agent-facing trigger. Runs unprivileged; polkit allows only this unit.
  deployCommand = pkgs.writeShellApplication {
    name = "mrnews-deploy";
    runtimeInputs = [pkgs.coreutils config.systemd.package];
    text = ''
      if ! systemctl start mrnews-deploy.service; then
        journalctl -u mrnews-deploy.service -n 30 --no-pager -o cat >&2 || true
        echo "mrnews-deploy: deployment failed" >&2
        exit 1
      fi
      echo "mrnews-deploy: live revision $(cat ${stateDir}/deployed-rev)"
    '';
  };

  polkitUsers = lib.concatMapStringsSep " || " (u: ''subject.user == "${u}"'') cfg.deployUsers;
in {
  options.homelab.services.mrnews = {
    enable = lib.mkEnableOption "Margaret River News static Hugo site";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "Flake-pinned mrnews build, used only to seed the site before the first deploy.";
    };

    repoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://git.ablz.au/abl030/mrnews.git";
      description = "Anonymous-readable mrnews repository whose signed master is deployed.";
    };

    deployUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["abl030"];
      description = "Users allowed (via polkit) to start mrnews-deploy.service.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "mrnews.ablz.au";
      description = "LAN/tailnet HTTPS hostname served by homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8850;
      description = "Loopback port for the sandboxed static file server.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.mrnews-deploy = {
      isSystemUser = true;
      group = "mrnews-deploy";
      home = stateDir;
    };
    users.groups.mrnews-deploy = {};

    # `L` only creates the seed link when absent; deploys replace it.
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 mrnews-deploy mrnews-deploy -"
      "L ${stateDir}/site - - - - ${cfg.package}"
    ];

    systemd.services.mrnews = {
      description = "Margaret River News static site";
      wantedBy = ["multi-user.target"];
      after = ["network.target" "systemd-tmpfiles-setup.service"];
      serviceConfig = {
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.static-web-server}/bin/static-web-server"
          "--host 127.0.0.1"
          "--port ${toString cfg.port}"
          # Resolved once at startup; mrnews-deploy restarts after a swap.
          "--root ${stateDir}/site"
          # The site is replaced atomically at the same URLs. The server's
          # default one-day cache otherwise leaves open browser tabs on the old
          # home page after a news deployment.
          "--cache-control-headers false"
          "--log-level warn"
        ];

        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallFilter = ["@system-service" "~@privileged"];
        SystemCallArchitectures = "native";
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
        UMask = "0077";
      };
    };

    systemd.services.mrnews-deploy = {
      description = "Deploy signed mrnews master to the live site";
      after = ["network-online.target" "nix-daemon.socket"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "mrnews-deploy";
        Group = "mrnews-deploy";
        ExecStart = "${deployScript}/bin/mrnews-deploy-run";
        ExecStartPost = "+${restartIfChanged}";
        TimeoutStartSec = "15min";
        ReadWritePaths = [stateDir];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        SystemCallArchitectures = "native";
        UMask = "0022";
      };
    };

    systemd.timers.mrnews-deploy = {
      description = "Backstop deploy of signed mrnews master";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "*:0/15";
        RandomizedDelaySec = "60";
      };
    };

    security.polkit.enable = true;
    security.polkit.extraConfig = ''
      // mrnews: deploy users may start (only) mrnews-deploy.service.
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "mrnews-deploy.service" &&
            action.lookup("verb") == "start" &&
            (${polkitUsers})) {
          return polkit.Result.YES;
        }
      });
    '';

    environment.systemPackages = [deployCommand];

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    homelab.monitoring = {
      monitors = [
        {
          name = "Margaret River News";
          url = "https://${cfg.fqdn}/";
        }
      ];
      deepProbes = [];
      errorPatterns = [];
    };
  };
}
