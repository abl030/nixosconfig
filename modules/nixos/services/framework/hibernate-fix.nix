{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.framework.hibernateFix;
in {
  options.homelab.framework.hibernateFix = {
    enable = lib.mkEnableOption "Framework hibernate fixes (WiFi driver + RAM exhaustion)";
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
      # Prevents the WiFi card from entering deep PCIe power states.
      "mt7921e.disable_aspm=1"

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
        script = ''
          # Sync filesystems
          ${pkgs.coreutils}/bin/sync
          # Drop page cache, dentries, inodes
          echo 3 > /proc/sys/vm/drop_caches
          # Brief pause for memory to settle
          ${pkgs.coreutils}/bin/sleep 2
        '';
      };

      wifi-hibernate-fix = {
        description = "Unload Mediatek WiFi drivers before sleep to prevent kernel hang";
        wantedBy = [
          "suspend.target"
          "hibernate.target"
          "suspend-then-hibernate.target"
          "hybrid-sleep.target"
        ];
        before = [
          "systemd-suspend.service"
          "systemd-hibernate.service"
          "systemd-suspend-then-hibernate.service"
          "systemd-hybrid-sleep.service"
        ];
        partOf = [
          "suspend.target"
          "hibernate.target"
          "suspend-then-hibernate.target"
          "hybrid-sleep.target"
        ];

        unitConfig.DefaultDependencies = "no";

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutSec = "15s";

          ExecStart = [
            "-${pkgs.kmod}/bin/modprobe -r mt7921e mt7921_common mt76_connac_lib mt76"
            "${pkgs.coreutils}/bin/sleep 1"
          ];

          ExecStop = [
            "${pkgs.kmod}/bin/modprobe mt7921e"
            "${pkgs.coreutils}/bin/sleep 2"
          ];
        };
      };
    };
  };
}
