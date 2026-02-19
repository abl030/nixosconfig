# Library Entry Point for NixOS and Home Manager Configuration Factory
# ==================================================================
#
# This file centralizes the logic for transforming `hosts.nix` definitions
# into actual NixOS systems or Standalone Home Manager configurations.
#
# It automatically injects:
# - Standard Module Sets (NixOS, Home Manager, Sops, etc.)
# - Special Arguments (inputs, hostname, allHosts, system, flake-root)
# - Overlays and Registry Settings
#
{
  inputs,
  overlays,
  flake-root,
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
        inherit inputs system hostname allHosts flake-root;
        hostConfig = cfg; # Inject the specific host config
      };

      modules = [
        # NEW: Set the host platform via module option
        {nixpkgs.hostPlatform = system;}

        # 1. The Host Specific Config
        cfg.configurationFile

        # 2. The Global Base Profile (Phase A)
        ../modules/nixos/profiles/base.nix

        # 3. The Custom Module Library
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
              inherit inputs system hostname allHosts flake-root;
              hostConfig = cfg; # Inject into HM modules as well
            };
            users.${cfg.user} = {
              imports = [
                inputs.sops-nix.homeManagerModules.sops
                ../modules/home-manager/profiles/base.nix
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
        inherit inputs system hostname allHosts flake-root;
        hostConfig = cfg; # Inject the specific host config
      };
      modules = [
        inputs.sops-nix.homeManagerModules.sops
        ../modules/home-manager/profiles/base.nix
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
