{
  config,
  pkgs,
  ...
}: let
  # ── Per-stack knobs ─────────────────────────────────────────
  stackName = "jellyfin-stack";
  stackDir = "/home/abl030/nixosconfig/docker/jellyfinn";
  encEnv = "/home/abl030/nixosconfig/secrets/secrets/jellyfin.env"; # SOPS-encrypted
  ageKey = "/root/.config/sops/age/keys.txt"; # your AGE key

  # Keep your extra requirements (mergerfs + mounts)
  requiresBase = [
    "docker.service"
    "network-online.target"
    "mnt-data.mount"
    "fuse-mergerfs-movies.service"
    "fuse-mergerfs-tv.service"
    "fuse-mergerfs-music.service"
  ];

  # ── Derived ────────────────────────────────────────────────
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  runEnv = "/run/secrets/${stackName}.env";
  afterBase = requiresBase;
in {
  systemd.services.${stackName} = {
    description = "Jellyfin Docker Compose Stack";
    restartIfChanged = false;
    reloadIfChanged = true;
    requires = requiresBase;
    after = afterBase;

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      WorkingDirectory = stackDir;

      # Decrypt env → /run (tmpfs) and lock perms before starting
      ExecStartPre = [
        "/run/current-system/sw/bin/mkdir -p /run/secrets"
        ''/run/current-system/sw/bin/env SOPS_AGE_KEY_FILE=${ageKey} ${pkgs.sops}/bin/sops -d --output ${runEnv} ${encEnv}''
        "/run/current-system/sw/bin/chmod 600 ${runEnv}"
      ];

      # Start / reload with always removing orphans
      ExecStart = "${dockerBin} compose --env-file ${runEnv} up -d --remove-orphans";
      ExecReload = "${dockerBin} compose --env-file ${runEnv} up -d --remove-orphans";

      # Stop the stack cleanly
      ExecStop = "${dockerBin} compose down";

      Restart = "on-failure";
      RestartSec = "30s";
      StandardOutput = "journal";
      StandardError = "journal";
    };

    wantedBy = ["multi-user.target"];
  };
}
