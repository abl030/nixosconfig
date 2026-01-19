{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.gpu.intel;
in {
  options.homelab.gpu.intel = {
    enable = mkEnableOption "Intel GPU support";
  };

  config = mkIf cfg.enable {
    hardware.graphics = {
      enable = true;
      extraPackages = lib.mkOrder 2100 (with pkgs; [
        # vpl-gpu-rt # for newer GPUs on NixOS >24.05 or unstable
        # onevpl-intel-gpu  # for newer GPUs on NixOS <= 24.05
        intel-media-driver
        # intel-media-sdk   # for older GPUs
        # libvdpau-va-gl
        # intel-vaapi-driver
      ]);
    };

    environment.sessionVariables = {LIBVA_DRIVER_NAME = "iHD";};
    environment.systemPackages = lib.mkOrder 2100 (with pkgs; [
      nvtopPackages.intel
      intel-gpu-tools
    ]);
  };
}
