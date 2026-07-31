{
  nixpkgs,
  upstreamNixpkgs,
  system,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config.allowUnfree = true;
  };
  upstreamPkgs = import upstreamNixpkgs {
    inherit system;
    config.allowUnfree = true;
  };

  # Ask the fleet's current upstream UniFi module which MongoDB series it wants,
  # then take that series from the isolated package set. This follows a future
  # upstream migration without tying today's MongoDB derivation to every fleet
  # nixpkgs commit.
  upstream = upstreamPkgs.lib.evalModules {
    specialArgs.pkgs = upstreamPkgs;
    modules = [
      (upstreamNixpkgs.outPath + "/nixos/modules/services/networking/unifi.nix")
      {_module.check = false;}
    ];
  };
  upstreamDefault = upstream.options.services.unifi.mongodbPackage.default;

  seriesAttrs = packages:
    builtins.filter (
      name: (builtins.tryEval packages.${name}.outPath).success
    ) (builtins.attrNames (packages.lib.filterAttrs (
        name: _: builtins.match "mongodb-[0-9]+_[0-9]+" name != null
      )
      packages));
  upstreamSeries = seriesAttrs upstreamPkgs;
  upstreamMatches =
    builtins.filter (
      name: upstreamPkgs.${name}.outPath == upstreamDefault.outPath
    )
    upstreamSeries;
  packageAttr =
    if builtins.length upstreamMatches == 1
    then builtins.head upstreamMatches
    else throw "could not identify exactly one versioned MongoDB attribute selected by upstream UniFi";
  package =
    if builtins.hasAttr packageAttr pkgs
    then pkgs.${packageAttr}
    else throw "isolated MongoDB nixpkgs does not provide upstream UniFi requirement ${packageAttr}";

  # Retain awareness of newly introduced MongoDB series so the isolated pin can
  # advance before UniFi starts requiring one that an old pin cannot evaluate.
  availableSeries = seriesAttrs pkgs;
in {
  inherit package;
  fingerprint = import ./mongodb-fingerprint.nix {
    inherit packageAttr package availableSeries;
  };
}
