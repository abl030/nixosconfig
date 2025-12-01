{
  description = "My first flake!";

  inputs = {
    # use the following for unstable:
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    #nixos-hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    domain-monitor-src = {
      url = "github:Hosteroid/domain-monitor";
      flake = false;
    };

    #NVCHAD is best chad.
    nvchad4nix = {
      url = "github:nix-community/nix4nvchad";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #sops-nix for secrets
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    home-manager-diff.url = "github:pedorich-n/home-manager-diff";

    fzf-preview.url = "github:niksingh710/fzf-preview";
    fzf-preview.inputs.nixpkgs.follows = "nixpkgs";

    isd.url = "github:isd-project/isd";

    gaj-shared = {
      url = "gitlab:gaj-nixos/shared";
      flake = false;
    };

    yt-dlp-src = {
      url = "github:yt-dlp/yt-dlp";
      flake = false;
    };

    # Structure helper
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs @ {
    nixpkgs,
    home-manager,
    home-manager-diff,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      imports = [./nix/pkgs.nix];

      perSystem = {...}: {
        imports = [./nix/devshell.nix];
      };

      flake = let
        system = "x86_64-linux";
        inherit (nixpkgs) lib;

        # Global overlays
        overlays = import ./nix/overlay.nix {inherit inputs;};

        pkgs = import nixpkgs {
          inherit system;
          inherit overlays;
        };

        hosts = import ./hosts.nix;

        extraSpecialArgs = {inherit system inputs;};
      in {
        nixosConfigurations =
          lib.mapAttrs
          (
            _hostname: cfg:
              lib.nixosSystem {
                inherit system;
                specialArgs = extraSpecialArgs;

                modules = [
                  cfg.configurationFile
                  ./modules/nixos
                  inputs.sops-nix.nixosModules.sops
                  {
                    nix.nixPath = ["nixpkgs=${inputs.nixpkgs}"];
                    nix.registry.nixpkgs.flake = inputs.nixpkgs;
                    nixpkgs.overlays = overlays;
                  }
                  home-manager.nixosModules.home-manager
                  {
                    home-manager = {
                      useGlobalPkgs = true;
                      useUserPackages = true;
                      extraSpecialArgs =
                        extraSpecialArgs
                        // {
                          hostname = _hostname;
                          allHosts = hosts;
                        };
                      users.${cfg.user} = {
                        imports = [
                          home-manager-diff.hmModules.default
                          cfg.homeFile
                          ./modules/home-manager
                        ];
                      };
                    };
                  }
                ];
              }
          )
          (lib.filterAttrs (_hostname: cfg: cfg ? "configurationFile") hosts);

        homeConfigurations =
          lib.mapAttrs
          (
            hostname: cfg:
              home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                extraSpecialArgs =
                  extraSpecialArgs
                  // {
                    inherit hostname;
                    allHosts = hosts;
                  };
                modules = [
                  home-manager-diff.hmModules.default
                  cfg.homeFile
                  ./modules/home-manager
                  {
                    home.username = cfg.user;
                    home.homeDirectory = cfg.homeDirectory;
                    nixpkgs.overlays = overlays;
                  }
                ];
              }
          )
          (lib.filterAttrs (_: cfg: !(cfg ? "configurationFile")) hosts);
      };
    };
}
