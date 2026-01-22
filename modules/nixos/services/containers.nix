{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.containers;
  inherit (config.homelab) user userHome;
  # UID may be dynamically assigned; fall back to 1000 if unset/null.
  userUid = let
    uid = config.users.users.${user}.uid or null;
  in
    if uid == null
    then 1000
    else uid;
  podmanBin = "${pkgs.podman}/bin/podman";
  autoUpdateScript = pkgs.writeShellScript "podman-auto-update" ''
    set -euo pipefail
    ${podmanBin} auto-update --cleanup
  '';
  podmanServiceScript = pkgs.writeShellScript "podman-system-service" ''
    set -euo pipefail
    exec ${podmanBin} system service --time=0 "unix://$XDG_RUNTIME_DIR/podman/podman.sock"
  '';
  storageConf = pkgs.writeTextFile {
    name = "containers-storage.conf";
    text = ''
      [storage]
      driver = "overlay"
      graphroot = "${cfg.dataRoot}/containers"
      runroot = "/run/user/${toString userUid}/containers"

      [storage.options]
      mount_program = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs"
    '';
  };
in {
  options.homelab.containers = {
    enable = lib.mkEnableOption "Rootless Podman stack management";

    dataRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/docker";
      description = "Root directory for container persistent data.";
    };

    autoUpdate = {
      enable = lib.mkEnableOption "Enable Podman auto-update via systemd user timer";

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = "Systemd OnCalendar schedule for podman auto-update.";
      };
    };

    cleanup = {
      enable = lib.mkEnableOption "Prune stopped rootless podman containers/pods";

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "Systemd OnCalendar schedule for podman prune.";
      };

      maxAge = lib.mkOption {
        type = lib.types.str;
        default = "168h";
        description = "Only prune stopped containers older than this duration (podman filter until=...).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    security.unprivilegedUsernsClone = true;
    security.wrappers = {
      newuidmap = {
        source = "${pkgs.shadow}/bin/newuidmap";
        owner = "root";
        group = "root";
        setuid = true;
      };
      newgidmap = {
        source = "${pkgs.shadow}/bin/newgidmap";
        owner = "root";
        group = "root";
        setuid = true;
      };
    };

    users.users.${user} = {
      linger = true;
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };

    environment = {
      systemPackages = lib.mkOrder 1600 (with pkgs; [
        podman
        podman-compose
        buildah
        skopeo
        shadow
        fuse-overlayfs
        slirp4netns
        netavark
        aardvark-dns
      ]);

      # Override upstream containers.nix storage.conf to ensure rootless graphroot/runroot.
      etc."containers/storage.conf".source = lib.mkForce storageConf;

      sessionVariables = {
        DOCKER_HOST = lib.mkDefault "unix:///run/user/${toString userUid}/podman/podman.sock";
      };
    };

    systemd.tmpfiles.rules = lib.mkAfter [
      "d ${cfg.dataRoot} 0750 ${user} ${user} -"
      "d ${cfg.dataRoot}/containers 0750 ${user} ${user} -"
    ];

    systemd = {
      services = {
        podman-system-service = {
          description = "Rootless Podman API service";
          # Wait for user@1000.service which creates /run/user/1000
          after = ["user@${toString userUid}.service"];
          requires = ["user@${toString userUid}.service"];
          serviceConfig = {
            Type = "simple";
            ExecStartPre = "/run/current-system/sw/bin/mkdir -p /run/user/${toString userUid}/podman";
            ExecStart = podmanServiceScript;
            Restart = "on-failure";
            RestartSec = "10s";
            User = user;
            Environment = [
              "HOME=${userHome}"
              "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
              "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
            ];
          };
          wantedBy = ["multi-user.target"];
        };

        podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
          description = "Podman auto-update (rootless)";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = autoUpdateScript;
            User = user;
            Environment = [
              "HOME=${userHome}"
              "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
              "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
            ];
          };
        };

        podman-rootless-prune = lib.mkIf cfg.cleanup.enable {
          description = "Podman prune (rootless) for stopped containers/pods";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = pkgs.writeShellScript "podman-rootless-prune" ''
              set -euo pipefail
              ${podmanBin} container prune -f --filter "until=${cfg.cleanup.maxAge}"
              ${podmanBin} pod prune -f
            '';
            User = user;
            Environment = [
              "HOME=${userHome}"
              "XDG_RUNTIME_DIR=/run/user/${toString userUid}"
              "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
            ];
          };
        };
      };

      timers = {
        podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
          description = "Podman auto-update timer (rootless)";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.autoUpdate.schedule;
            Persistent = true;
          };
        };

        podman-rootless-prune = lib.mkIf cfg.cleanup.enable {
          description = "Podman prune timer (rootless)";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = cfg.cleanup.schedule;
            Persistent = true;
          };
        };
      };
    };
  };
}
