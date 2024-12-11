{ pkgs, ... }:
{
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      # your Open GL, Vulkan and VAAPI drivers
      # vpl-gpu-rt # for newer GPUs on NixOS >24.05 or unstable
      # onevpl-intel-gpu  # for newer GPUs on NixOS <= 24.05
      intel-media-driver
      # intel-media-sdk   # for older GPUs
      # libvdpau-va-gl
      intel-vaapi-driver
    ];
  };
  environment.sessionVariables = { LIBVA_DRIVER_NAME = "iHD"; }; # Optionally, set the environment variable
  environment.systemPackages = [
    pkgs.nvtopPackages.intel
  ];
}

