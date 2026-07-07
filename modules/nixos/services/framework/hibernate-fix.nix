{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.framework.hibernateFix;
in {
  options.homelab.framework.hibernateFix = {
    enable = lib.mkEnableOption "Framework hibernate RAM exhaustion fix";
  };

  config = lib.mkIf cfg.enable {
    # =======================================================================
    # Hibernate RAM Exhaustion Fix
    # =======================================================================
    # Problem: Hibernate fails with ENOSPC (-28) despite having free swap.
    # Root cause: Kernel runs out of RAM during the hibernate write phase
    # for compression buffers and swap tracking structures.
    # See: https://github.com/abl030/nixosconfig commit history for analysis
    # =======================================================================

    boot.kernelParams = [
      # Disable zswap - it uses RAM for its compressed page pool, which
      # competes with hibernate's need for free RAM during write phase.
      "zswap.enabled=0"
    ];

    # Force smallest possible hibernate image. This tells the kernel to
    # aggressively free memory (drop caches, push to swap) BEFORE taking
    # the snapshot, leaving more free RAM for the write phase.
    systemd.tmpfiles.rules = ["w /sys/power/image_size - - - - 0"];

    systemd.services = {
      # Free RAM before hibernate to prevent ENOSPC during write phase
      pre-hibernate = {
        description = "Free RAM before hibernate";
        wantedBy = ["hibernate.target" "suspend-then-hibernate.target"];
        before = ["systemd-hibernate.service" "systemd-suspend-then-hibernate.service"];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        serviceConfig.NoNewPrivileges = true; # sync + drop_caches as root; no setuid (#232)
        script = ''
          # Sync filesystems
          ${pkgs.coreutils}/bin/sync
          # Drop page cache, dentries, inodes
          echo 3 > /proc/sys/vm/drop_caches
          # Brief pause for memory to settle
          ${pkgs.coreutils}/bin/sleep 2
        '';
      };
    };
  };
}
