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
      # You can add `flake = false;` if it's not a flake itself but you want to use its files
      flake = false;
    };
  };

  outputs = { self, nixpkgs, home-manager, home-manager-diff, ... }@inputs:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      extraSpecialArgs = { inherit system; inherit inputs; };

      #define our hosts
      hosts = {
        #Our hostkey must match our hostname so that NIXD home completions work. 
        #Note this does mean at the moment we are limited to one user per host. 
        #In NVIM/lspconfig.lua you can see we pull in our home_manager completions
        #programatticaly and this was the easiest way. Note that this is does not have to be the 'hostname' per se 
        #but merely this host key and the username must be the same. 
        epimetheus = {
          configurationFile = ./hosts/epi/configuration.nix;
          homeFile = ./hosts/epi/home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
          hostname = "epimetheus";
        };

        caddy = {
          homeFile = ./hosts/caddy/home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
        };

        framework = {
          configurationFile = ./hosts/framework/configuration.nix;
          homeFile = ./hosts/framework/home.nix;
          user = "abl030";
          homeDirectory = /home/abl030;
        };
        wsl = {
          configurationFile = ./hosts/wsl/configuration.nix;
          homeFile = ./hosts/wsl/home.nix;
          user = "nixos";
          homeDirectory = "/home/nixos/";
        };

        proxmox-vm = {
          configurationFile = ./hosts/proxmox-vm/configuration.nix;
          homeFile = ./hosts/proxmox-vm/home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
        };
        igpu = {
          configurationFile = ./hosts/igpu/configuration.nix;
          homeFile = ./hosts/igpu/home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
        };

      };
    in
    {
      nixosConfigurations =
        (lib.mapAttrs
          (hostname: config: lib.nixosSystem {
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
          })
          hosts);

      homeConfigurations =
        (lib.mapAttrs
          (hostname: config: home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            extraSpecialArgs = extraSpecialArgs // { inherit hostname; }; # Pass hostname here
            modules = [
              home-manager-diff.hmModules.default
              config.homeFile

              {
                home.username = config.user;
                home.homeDirectory = config.homeDirectory;
                nixpkgs = {
                  overlays = [
                    (final: prev: {
                      nvchad = inputs.nvchad4nix.packages."${pkgs.system}".nvchad;
                    })
                  ];
                };
              }

            ];
          })
          hosts);
    };
}
