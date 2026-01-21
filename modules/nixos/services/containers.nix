{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.containers;
  inherit (config.homelab) user userHome;
  userUid = config.users.users.${user}.uid or 1000;
  podmanBin = "${pkgs.podman}/bin/podman";
  autoUpdateScript = pkgs.writeShellScript "podman-auto-update" ''
    set -euo pipefail
    ${podmanBin} auto-update --cleanup
  '';
  podmanServiceScript = pkgs.writeShellScript "podman-system-service" ''
    set -euo pipefail
    exec ${podmanBin} system service --time=0 unix:///run/user/$(id -u)/podman/podman.sock
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
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman = {
      enable = true;
      dockerCompat = false;
      defaultNetwork.settings.dns_enabled = true;
    };

    security.unprivilegedUsernsClone = true;

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

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [
      podman
      podman-compose
      buildah
      skopeo
      fuse-overlayfs
      slirp4netns
      netavark
      aardvark-dns
    ]);

    environment.etc."containers/storage.conf".source = storageConf;

    systemd.tmpfiles.rules = lib.mkAfter [
      "d ${cfg.dataRoot} 0750 ${user} ${user} -"
      "d ${cfg.dataRoot}/containers 0750 ${user} ${user} -"
    ];

    systemd = {
      services.podman-system-service = {
        description = "Rootless Podman API service";
        serviceConfig = {
          Type = "simple";
          ExecStart = podmanServiceScript;
          Restart = "on-failure";
          RestartSec = "10s";
          User = user;
          Environment = [
            "HOME=${userHome}"
            "XDG_RUNTIME_DIR=/run/user/%U"
          ];
        };
        wantedBy = ["multi-user.target"];
      };

      services.podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
        description = "Podman auto-update (rootless)";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = autoUpdateScript;
          User = user;
          Environment = [
            "HOME=${userHome}"
            "XDG_RUNTIME_DIR=/run/user/%U"
          ];
        };
      };

      timers.podman-auto-update = lib.mkIf cfg.autoUpdate.enable {
        description = "Podman auto-update timer (rootless)";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.autoUpdate.schedule;
          Persistent = true;
        };
      };
    };
  };
}
