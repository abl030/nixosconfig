# Bootstrap pkgs (with overlays) for all perSystem consumers (devShells, formatter, checks).
# Rationale:
# - flake-parts does not auto-init pkgs; we import nixpkgs here so everything
#   inside perSystem sees the same overlayed package set as your NixOS/HM builds.
{inputs, ...}: {
  perSystem = {system, ...}: {
    _module.args.pkgs = import inputs.nixpkgs {
      inherit system;
      overlays = import ./overlay.nix {inherit inputs;};
      config = {};
    };
  };
}
