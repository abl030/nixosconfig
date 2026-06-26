{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.framework.hibernateFix;

  # Force PCIe ASPM L1 + clock-PM OFF on the mt7921e (MT7922) WiFi card.
  # The `mt7921e.disable_aspm=1` kernel param only disables the *driver's*
  # ASPM handling, NOT the link-level L1 — which resume re-enables, leaving
  # `/sys/.../link/l1_aspm` = 1. Repeated L1 entry/exit slowly wedges the
  # MT7922 firmware → cyclic 25-175ms latency that builds over use after a
  # resume and kills game streams (a full driver reload resets it). This
  # writes l1_aspm=0 at boot AND on every resume (via wifi-hibernate-fix's
  # ExecStop). Targeted to the WiFi PCI device, so everything else keeps its
  # ASPM/battery savings. Ref: https://bbs.archlinux.org/viewtopic.php?id=287846
  wifiAspmOff = pkgs.writeShellScript "wifi-aspm-off" ''
    set -u
    for d in /sys/bus/pci/drivers/mt7921e/0000:*; do
      [ -e "$d/link/l1_aspm" ] && echo 0 > "$d/link/l1_aspm" || true
      [ -e "$d/link/clkpm" ] && echo 0 > "$d/link/clkpm" || true
    done
  '';
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
      # Driver-side ASPM disable. NOTE: this alone is INSUFFICIENT — it does
      # not clear the link-level ASPM L1 (`l1_aspm` stays 1, esp. after resume).
      # The wifi-aspm-off service + the wifi-hibernate-fix ExecStop do the real
      # work; kept here as belt-and-suspenders.
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
      # Disable mt7921e PCIe ASPM L1 at boot (see the wifiAspmOff comment above).
      # Resume is covered by wifi-hibernate-fix's ExecStop re-running it.
      wifi-aspm-off = {
        description = "Disable PCIe ASPM L1 on mt7921e WiFi (latency fix)";
        wantedBy = ["multi-user.target"];
        after = ["network-pre.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${wifiAspmOff}";
        };
      };

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
          # NNP-OK reasoning: modprobe runs as root via CAP_SYS_MODULE (held), not
          # a setuid exec, so NoNewPrivileges doesn't block module (un)loading. (#232)
          NoNewPrivileges = true;
          RemainAfterExit = true;
          TimeoutSec = "15s";

          ExecStart = [
            "-${pkgs.kmod}/bin/modprobe -r mt7921e mt7921_common mt76_connac_lib mt76"
            "${pkgs.coreutils}/bin/sleep 1"
          ];

          ExecStop = [
            "${pkgs.kmod}/bin/modprobe mt7921e"
            "${pkgs.coreutils}/bin/sleep 2"
            # Re-disable ASPM L1 after the resume reload (resume re-enables it).
            "${wifiAspmOff}"
          ];
        };
      };
    };
  };
}
