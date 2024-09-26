{
  description = "My first flake!";

  inputs = {
    # use the following for unstable:
    nixpkgs.url = "nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager/master";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};

      #define our hosts
      hosts = {

        asus = {

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


      };
    in
    {
      nixosConfigurations =
        (lib.mapAttrs
          (hostname: config: lib.nixosSystem {
            inherit system;
            modules = [ config.configurationFile ];
          })
          hosts);

      homeConfigurations =
        (lib.mapAttrs
          (hostname: config: home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              config.homeFile

              {
                home.username = config.user;
                home.homeDirectory = config.homeDirectory;
              }

            ];
          })
          hosts);
    };
}
