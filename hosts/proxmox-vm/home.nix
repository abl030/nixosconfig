{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  homelab.beets.enable = true;
}
