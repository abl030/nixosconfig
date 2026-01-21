{
  hostConfig,
  lib,
  ...
}: {
  options.homelab = {
    user = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = hostConfig.user;
      description = "Primary homelab user name derived from hosts.nix.";
    };

    userHome = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = hostConfig.homeDirectory or "/home/${hostConfig.user}";
      description = "Primary homelab user home directory derived from hosts.nix.";
    };
  };
}
