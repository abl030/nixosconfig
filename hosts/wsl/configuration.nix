{
  pkgs,
  inputs,
  hostConfig, # NEW: Inject hostConfig
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.default
    ../common/desktop.nix
  ];

  homelab = {
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
    };
    ssh.enable = true;
  };

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = hostConfig.user; # CHANGED: Dynamic from SSOT

  # REMOVED: networking.hostName (Now handled by base.nix)

  environment.systemPackages = [
    pkgs.neovim
    pkgs.gh
  ];

  system.stateVersion = "25.05";
}
