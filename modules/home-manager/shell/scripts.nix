# modules/home-manager/shell/scripts.nix
{
  pkgs,
  lib,
  ...
}: let
  scriptsLib = import ./scripts-lib.nix {inherit pkgs;};

  # Helper to build a writeShellApplication from the definition
  mkScript = name: attr:
    pkgs.writeShellApplication {
      inherit name;
      inherit (attr) runtimeInputs text;
    };

  # Build all scripts
  scriptPackages = lib.mapAttrsToList mkScript scriptsLib;
in {
  home.packages = scriptPackages;
}
