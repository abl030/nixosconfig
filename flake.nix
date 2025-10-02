{
  description = "My first flake!";

  inputs = {
    # use the following for unstable:
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    # nixos-hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    # NVCHAD is best chad.
    nvchad4nix = {
      url = "github:nix-community/nix4nvchad";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # sops-nix for secrets
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # plasma-manager = {
    #   url = "github:nix-community/plasma-manager";
    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.home-manager.follows = "home-manager";
    # };

    # wezterm = {
    #   url = "github:wez/wezterm/main?dir=nix";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    nixos-wsl.url = "github:nix-community/NixOS-WSL/main";
    home-manager-diff.url = "github:pedorich-n/home-manager-diff";

    fzf-preview.url = "github:niksingh710/fzf-preview";
    fzf-preview.inputs.nixpkgs.follows = "nixpkgs";

    isd.url = "github:isd-project/isd";

    gaj-shared = {
      url = "gitlab:gaj-nixos/shared"; # Shorthand for gitlab.com/gaj-nixos/shared
      # By default, it tracks the default branch (e.g., main)
      # You can add flake = false; if it's not a flake itself but you want to use its files
      flake = false;
    };

    yt-dlp-src = {
      url = "github:yt-dlp/yt-dlp";
      flake = false;
    };
  };

  # NOTE: Keep the same calling style; we bind the whole set to `inputs` for overlays, etc.
  outputs = { self, nixpkgs, home-manager, home-manager-diff, ... }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      # Pass commonly-needed things to modules and home
      extraSpecialArgs = { inherit system; inherit inputs; };

      # ⬇️ Minimal change: import hosts attrset from a separate file.
      #    This isolates host topology without touching consumers.
      hosts = import ./hosts.nix;
    in
    {
      nixosConfigurations =
        (lib.mapAttrs
          (hostname: config:
            lib.nixosSystem {
              inherit system;
              specialArgs = extraSpecialArgs; # Pass extraSpecialArgs here
              modules = [
                config.configurationFile
                {
                  nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
                  # Optional: Set registry for consistency
                  nix.registry.nixpkgs.flake = inputs.nixpkgs;
                }
              ];
            }
          )
          hosts
        );

      homeConfigurations =
        (lib.mapAttrs
          (hostname: config:
            home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              # Pass hostname + allHosts; consumers unchanged
              extraSpecialArgs = extraSpecialArgs // {
                inherit hostname;
                allHosts = hosts;
              };
              modules = [
                home-manager-diff.hmModules.default
                config.homeFile
                ./modules/home-manager
                {
                  home.username = config.user;
                  home.homeDirectory = config.homeDirectory;

                  nixpkgs = {
                    overlays = [
                      # Expose nvchad from the nvchad4nix flake
                      (final: prev: {
                        nvchad = inputs.nvchad4nix.packages."${pkgs.system}".nvchad;
                      })

                      # Track yt-dlp master from flake input; stamp version with short rev
                      (final: prev:
                        let
                          rev = inputs.yt-dlp-src.rev or null;
                          short = if rev == null then "unknown" else builtins.substring 0 7 rev;
                        in
                        {
                          yt-dlp = prev.yt-dlp.overrideAttrs (old: {
                            # track master tree from the flake input
                            src = inputs.yt-dlp-src;

                            # optional: stamp the version for clarity (safe to omit entirely)
                            version = "master-${short}";

                            # If upstream flips tests and it blocks you, you can temporarily uncomment:
                            # doCheck = false;
                          });
                        }
                      )
                    ];
                  };
                }
              ];
            }
          )
          hosts
        );
    };
}

