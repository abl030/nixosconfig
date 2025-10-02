{
  description = "My first flake!";

  inputs = {
    # use the following for unstable:
    nixpkgs.url = "nixpkgs/nixpkgs-unstable";

    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    #nixos-hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

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

    # Structure helper: gives us a standard layout for dev shells, formatter, checks.
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  # We keep explicit, readable outputs and add a perSystem section for developer UX.
  # perSystem: defines the toolchain for contributors (nix develop, nix fmt, checks).
  # flake:     keeps host builds (NixOS + Home Manager) as first-class outputs.
  outputs = inputs@{ self, nixpkgs, home-manager, home-manager-diff, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # Target platforms for perSystem (devShells/formatter/checks).
      systems = [ "x86_64-linux" ];

      perSystem = { system, lib, pkgs, ... }: {
        # Initialise pkgs WITH global overlays so devShells/formatter/checks see the
        # exact same package universe as our NixOS/HM builds.
        _module.args.pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = import ./nix/overlay.nix { inherit inputs; };
          config = { };
        };

        # Repo-wide formatter so `nix fmt` is consistent locally and in CI.
        # We use nixfmt (requested) instead of alejandra.
        formatter = pkgs.nixfmt;

        # Developer shell: the standard tools used when editing this repo.
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.git
            pkgs.home-manager
            pkgs.nixd
            pkgs.nixfmt
          ];
        };

        # Example check wiring (leave commented until you want it in CI):
        # checks.format = pkgs.runCommand "fmt-check" { } ''
        #   ${pkgs.nixfmt}/bin/nixfmt --check .
        #   touch $out
        # '';
      };

      # Flake outputs for NixOS and Home Manager.
      # We apply the same overlays here so system + user environments match perSystem.
      flake =
        let
          system = "x86_64-linux";
          lib = nixpkgs.lib;

          # Global overlays used everywhere in this flake (system builds, HM, dev shells).
          overlays = import ./nix/overlay.nix { inherit inputs; };

          # pkgs for any top-level evaluation needs (rarely used directly below).
          pkgs = import nixpkgs { inherit system; overlays = overlays; };

          # Host topology lives in a separate file to keep this one focused on wiring.
          hosts = import ./hosts.nix;

          # Pass inputs/system/host context to modules (for host-aware HM bits, etc.).
          extraSpecialArgs = { inherit system inputs; };
        in
        {
          nixosConfigurations =
            lib.mapAttrs
              (hostname: cfg:
                lib.nixosSystem {
                  inherit system;
                  specialArgs = extraSpecialArgs;

                  modules = [
                    cfg.configurationFile
                    {
                      # Keep nixpkgs channel and registry consistent across hosts.
                      nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
                      # Optional: Set registry for consistency
                      nix.registry.nixpkgs.flake = inputs.nixpkgs;

                      # Make overlays global for the system.
                      nixpkgs.overlays = overlays;
                    }
                  ];
                }
              )
              hosts;

          homeConfigurations =
            lib.mapAttrs
              (hostname: cfg:
                home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;

                  # Provide host context and inputs to HM modules.
                  extraSpecialArgs = extraSpecialArgs // { inherit hostname; allHosts = hosts; };

                  # Apply overlays at the HM level so user packages match system/dev shells.
                  modules = [
                    home-manager-diff.hmModules.default
                    cfg.homeFile
                    ./modules/home-manager
                    {
                      home.username = cfg.user;
                      home.homeDirectory = cfg.homeDirectory;

                      # Make overlays global for Home Manager as well.
                      nixpkgs.overlays = overlays;
                    }
                  ];
                }
              )
              hosts;
        };
    };
}

