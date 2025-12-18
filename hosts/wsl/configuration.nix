{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    inputs.nixos-wsl.nixosModules.default
  ];

  homelab = {
    nixCaches = {
      enable = true;
      profile = "internal"; # or "external"
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
    };
  };

  # 2. FIX: Satisfy User Assertion
  users.users.abl030 = {
    isNormalUser = true;
    description = "Admin User (Fleet Identity)";
    extraGroups = ["wheel" "docker"];
    shell = pkgs.bash;
  };

  # 3. Standard WSL Configuration
  wsl.enable = true;
  wsl.defaultUser = "nixos";

  networking.hostName = "wsl";
  time.timeZone = "Australia/Perth";

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = ["nix-command" "flakes"];

  # Basic packages
  environment.systemPackages = [
    pkgs.neovim
    pkgs.git
    pkgs.home-manager
    pkgs.wget
    pkgs.gh
  ];

  programs.bash.blesh.enable = true;

  system.stateVersion = "25.05";
}
