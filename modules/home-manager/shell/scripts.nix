# modules/home-manager/shell/scripts.nix
{
  pkgs,
  lib,
  flake-root,
  ...
}: let
  scriptsLib = import ./scripts-lib.nix {inherit pkgs;};

  # Helper to build a writeShellApplication from the definition (Legacy/Inline)
  mkScript = name: attr:
    pkgs.writeShellApplication {
      inherit name;
      inherit (attr) runtimeInputs text;
    };

  # Build existing inline scripts
  inlineScriptPackages = lib.mapAttrsToList mkScript scriptsLib;

  # ──────────────────────────────────────────────────────────────────────────────
  #  Dynamic Script Loading from scripts/
  # ──────────────────────────────────────────────────────────────────────────────

  # Path to the scripts directory in the flake root
  scriptsDir = "${flake-root}/scripts";

  # Helper to create a derivation for a script file
  mkFileScript = filename: let
    # Remove .sh extension for the binary name (e.g., bluetooth_restart.sh -> bluetooth_restart)
    name = lib.strings.removeSuffix ".sh" filename;
    path = "${scriptsDir}/${filename}";
  in
    # runCommand copies the script and patches shebangs to work with Nix store paths
    pkgs.runCommand name {
      src = path;
    } ''
      mkdir -p $out/bin
      cp $src $out/bin/${name}
      chmod +x $out/bin/${name}
      patchShebangs $out/bin/${name}
    '';

  # Scan directory for .sh files and create packages
  fileScriptPackages =
    if builtins.pathExists scriptsDir
    then let
      contents = builtins.readDir scriptsDir;
      # Filter for regular files ending in .sh
      isScript = name: type: type == "regular" && lib.strings.hasSuffix ".sh" name;
      scriptNames = lib.attrNames (lib.filterAttrs isScript contents);
    in
      map mkFileScript scriptNames
    else [];
in {
  home.packages = inlineScriptPackages ++ fileScriptPackages;
}
