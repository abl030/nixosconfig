# Check entry point. FULL_CHECK/HOST_CHECKS retain the optional host-build contract.
{
  self,
  lib,
  pkgs,
  system,
  hosts,
  inputs,
  signing,
}: let
  fullCheck = builtins.getEnv "FULL_CHECK" == "1";

  hostFilterRaw = builtins.getEnv "HOST_CHECKS";

  hostFilter =
    if hostFilterRaw == ""
    then null
    else
      lib.filter (name: name != "")
      (lib.splitString "," (lib.replaceStrings [" "] [","] hostFilterRaw));

  hostChecks =
    lib.mapAttrs
    (name: cfg:
      pkgs.runCommand "check-nixos-${name}" {} ''
        echo "Checking NixOS config: ${name}"
        echo "System name: ${cfg.config.system.name}"
        echo "Toplevel: ${cfg.config.system.build.toplevel}"
        touch $out
      '')
    self.nixosConfigurations
    // lib.mapAttrs
    (name: cfg:
      pkgs.runCommand "check-home-${name}" {} ''
        echo "Checking Home Manager config: ${name}"
        echo "Activation package: ${cfg.activationPackage}"
        touch $out
      '')
    self.homeConfigurations;
in
  import ./security.nix {inherit self lib pkgs;}
  // import ./fleet.nix {inherit self lib pkgs hosts signing;}
  // import ./services.nix {inherit self inputs lib pkgs system;}
  // import ./unifi.nix {inherit self lib pkgs;}
  // import ./repository.nix {inherit pkgs;}
  // import ./gnome-shell-libgvc.nix {inherit pkgs;}
  // import ./rolling-runtime.nix {inherit self lib pkgs;}
  // (
    if !fullCheck
    then {}
    else if hostFilter == null
    then hostChecks
    else lib.filterAttrs (name: _: lib.elem name hostFilter) hostChecks
  )
