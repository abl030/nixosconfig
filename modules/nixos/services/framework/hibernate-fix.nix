{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.homelab.framework.hibernateFix;
in {
  options.homelab.framework.hibernateFix = {
    enable = lib.mkEnableOption "Framework Mediatek WiFi hibernate fix";
  };

  config = lib.mkIf cfg.enable {
    boot.kernelParams = [
      # Prevents the WiFi card from entering deep PCIe power states.
      "mt7921e.disable_aspm=1"

      # "pcie_aspm=off"
    ];

    systemd.services.wifi-hibernate-fix = {
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
}
