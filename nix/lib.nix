# Library Entry Point for NixOS and Home Manager Configuration Factory
# ==================================================================
#
# This file centralizes the logic for transforming `hosts.nix` definitions
# into actual NixOS systems or Standalone Home Manager configurations.
#
# It automatically injects:
# - Standard Module Sets (NixOS, Home Manager, Sops, etc.)
# - Special Arguments (inputs, hostname, allHosts, system)
# - Overlays and Registry Settings
#
{
  inputs,
  overlays,
}: let
  inherit (inputs.nixpkgs) lib;
  system = "x86_64-linux"; # Standard system for this fleet
in {
  # Generator for full NixOS Systems
  # --------------------------------
  mkNixosSystem = hostname: cfg: allHosts:
    lib.nixosSystem {
      # REMOVED: inherit system; (Deprecated legacy argument)

      # Pass host metadata to NixOS modules
      specialArgs = {
        inherit inputs system hostname allHosts;
        hostConfig = cfg; # Inject the specific host config
      };

      modules = [
        # NEW: Set the host platform via module option
        {nixpkgs.hostPlatform = system;}

        cfg.configurationFile
        ../modules/nixos
        inputs.sops-nix.nixosModules.sops
        {
          nix.nixPath = ["nixpkgs=${inputs.nixpkgs}"];
          nix.registry.nixpkgs.flake = inputs.nixpkgs;
          nixpkgs.overlays = overlays;
        }
        inputs.home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = {
              inherit inputs system hostname allHosts;
              hostConfig = cfg; # Inject into HM modules as well
            };
            users.${cfg.user} = {
              imports = [
                inputs.home-manager-diff.hmModules.default
                inputs.sops-nix.homeManagerModules.sops
                cfg.homeFile
                ../modules/home-manager
              ];
            };
          };
        }
      ];
    };

  # Generator for Standalone Home Manager Configurations
  # --------------------------------------------------
  mkHomeConfiguration = hostname: cfg: allHosts: pkgs:
    inputs.home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      extraSpecialArgs = {
        inherit inputs system hostname allHosts;
        hostConfig = cfg; # Inject the specific host config
      };
      modules = [
        inputs.home-manager-diff.hmModules.default
        inputs.sops-nix.homeManagerModules.sops
        cfg.homeFile
        ../modules/home-manager
        {
          home.username = cfg.user;
          home.homeDirectory = cfg.homeDirectory;
          nixpkgs.overlays = overlays;
        }
      ];
    };
}
