{
  description = "My first flake!";

  inputs = {
    # use the following for unstable:
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    #NVCHAD is best chad.
    nvchad4nix = {
      url = "github:nix-community/nix4nvchad";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs:
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
        family = {

          configurationFile = ./configuration_asus.nix;
          homeFile = ./home.nix;
          user = "family";
          homeDirectory = "/home/family";
        };

        testvm = {
          configurationFile = ./configuration.nix;
          homeFile = ./home.nix;
          user = "testvm";
          homeDirectory = "/home/testvm";
        };

        epimetheus = {
          configurationFile = ./configuration.nix;
          homeFile = ./home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
        };

        caddy = {
          homeFile = ./home.nix;
          user = "abl030";
          homeDirectory = "/home/abl030";
        };

        framework = {
          homeFile = ./home.nix;
          user = "abl030";
          homeDirectory = /home/abl030;
        };

      };
    in
    {
      nixosConfigurations =
        (lib.mapAttrs
          (hostname: config: lib.nixosSystem {
            inherit system;
            modules = [
              config.configurationFile
            ];
          })
          hosts);

      homeConfigurations =
        (lib.mapAttrs
          (hostname: config: home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            inherit extraSpecialArgs;
            modules = [
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
