# Terranix/OpenTofu integration
# This is a top-level flake-parts module that has access to inputs
{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    # Generate the terranix configuration
    terranixConfig = inputs.terranix.lib.terranixConfiguration {
      inherit pkgs;
      modules = [../vms/tofu];
    };
  in {
    # Expose terranixConfig to other perSystem modules
    _module.args.terranixConfig = terranixConfig;
  };
}
