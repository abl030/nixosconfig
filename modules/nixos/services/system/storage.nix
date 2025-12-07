{
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.homelab.storage;
in {
  options.homelab.storage = {
    enable = mkEnableOption "Enable System Storage Services (UDisks2)";
  };

  config = mkIf cfg.enable {
    # 1. UDisks2: The daemon that handles partitioning and mounting
    # This is required for Dolphin to "see" and mount USB drives.
    services.udisks2.enable = true;

    # 2. GVFS: Optional, but helpful for Dolphin to handle Trash/MTP (Android phones)
    services.gvfs.enable = true;
  };
}
