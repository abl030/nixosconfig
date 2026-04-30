{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.beancount;
  bookRepoSsh = "ssh://forgejo@git.ablz.au:2222/abl030/books.git";
  cloneDir = "${cfg.dataDir}/books";
  sshKey = config.sops.secrets."beancount/deploy-key".path;
  knownHosts = pkgs.writeText "fava-known-hosts" ''
    [git.ablz.au]:2222 ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDD0eMvDPHW7Zqd1HKUhTRwAadPk6Brg98/SDPeAGRF8ptuuOh+1tlQB0f7tmA2mYcMEk557yhZIUT4WEQCRlW09r4CyZYccRgQU6gxvbfehf+/kdcrVt4JocgrZ78t2XD5H81A8ufC4qoJK3LAwmhvDnxPV4mcO2Y7Fn92pdcuhMnFoPLOYPUoznhjy5QAqjOh1fxa0e0SGVoSXUYEr4zXPZsX68bC7k9T84p3aRvY/afdVKupHLcMRNOYTSUuUVLxEHG5aCh3CodQkHUiXIWpFMtALCQL3u7b/kXaM/IV7OtK9bQ8TRafMasK4MHMc2q1x+s49OCQSrAT49u9jji/2rRiHP+yDZxT6WYwqn5tUdOxmBjYfbPnb1pdCqM+iHpndJM/s2LukXBs7Va5EQNCn5LwXTsDwgWN+4k8d0Dbmq8k45l1ACTTqe8XhVwfWR8NckTPMLmxsa/ba7HasL0ll8XarcuKtOgwd3U+XyPamSQtWEr8/thnmvnZLBmwM/kx8uuDTEdqWDdyC9is/NtKt+BhvvX6z76/MvbwwcFAvYIpRg0q2UMnul9R0AlZ13Krm5rmCxCgHJmlIf1yjp8V9ZlKto5bRPvclVV7UCjRltcFwipKSsbOw/mxiAZ7lyimEsD2FMbsCzoUwym+LZQqj6IvHBn+9wt7YeQLjqYYiw==
  '';
  gitSshCommand = "${pkgs.openssh}/bin/ssh -i ${sshKey} -o UserKnownHostsFile=${knownHosts} -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes";
in {
  options.homelab.services.beancount = {
    enable = lib.mkEnableOption "Beancount + Fava (household accounting journal viewer)";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/beancount";
      description = "State directory; books repo gets cloned to ${cfg.dataDir}/books.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 5023;
      description = "Loopback port for Fava (behind nginx via localProxy).";
    };
    journalFile = lib.mkOption {
      type = lib.types.str;
      default = "main.beancount";
      description = "Journal entrypoint, relative to the books repo root.";
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."beancount/deploy-key" = {
      sopsFile = config.homelab.secrets.sopsFile "beancount-deploy-key";
      format = "binary";
      owner = "fava";
      mode = "0400";
    };

    users.users.fava = {
      isSystemUser = true;
      group = "fava";
      home = cfg.dataDir;
    };
    users.groups.fava = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 fava fava - -"
    ];

    # Initial clone — runs once. After this the working tree exists; pulls keep it fresh.
    # GIT_SSH_COMMAND is exported inside the script body, not via Environment=,
    # because systemd splits unquoted Environment= values on whitespace and
    # nix's default rendering doesn't add quotes.
    systemd.services.beancount-clone = {
      description = "Clone books repo on first run";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      before = ["fava.service"];

      path = [pkgs.git pkgs.openssh];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "fava";
        Group = "fava";
        WorkingDirectory = cfg.dataDir;
      };

      script = ''
        export GIT_SSH_COMMAND='${gitSshCommand}'
        if [ ! -d "${cloneDir}/.git" ]; then
          git clone ${bookRepoSsh} ${cloneDir}
        else
          echo "books repo already cloned"
        fi
      '';
    };

    # Periodic pull — picks up agent commits within ~5 min.
    systemd.services.beancount-pull = {
      description = "Pull books repo from Forgejo";
      after = ["beancount-clone.service"];
      requires = ["beancount-clone.service"];

      path = [pkgs.git pkgs.openssh];

      serviceConfig = {
        Type = "oneshot";
        User = "fava";
        Group = "fava";
        WorkingDirectory = cloneDir;
      };

      script = ''
        export GIT_SSH_COMMAND='${gitSshCommand}'
        git fetch --quiet origin
        git reset --hard origin/master
      '';
    };

    systemd.timers.beancount-pull = {
      description = "Pull books repo every 5 minutes";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };

    # Fava — read-mostly web UI for the journal.
    systemd.services.fava = {
      description = "Fava (Beancount web UI)";
      wantedBy = ["multi-user.target"];
      after = ["beancount-clone.service"];
      requires = ["beancount-clone.service"];

      serviceConfig = {
        ExecStart = "${pkgs.fava}/bin/fava --host 127.0.0.1 --port ${toString cfg.port} ${cloneDir}/${cfg.journalFile}";
        User = "fava";
        Group = "fava";
        WorkingDirectory = cfg.dataDir;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = [cfg.dataDir];
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = "books.ablz.au";
          port = cfg.port;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Fava";
          url = "https://books.ablz.au/";
        }
      ];
    };
  };
}
