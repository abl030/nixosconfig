{
  config,
  hostConfig,
  hostname,
  lib,
  ...
}: let
  secretsRoot = ../../../secrets;
in {
  options.homelab.secrets = {
    root = lib.mkOption {
      type = lib.types.path;
      default = secretsRoot;
      description = "Root directory for encrypted secrets.";
    };
    hostDir = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "Host-specific secrets directory.";
    };
    userDir = lib.mkOption {
      type = lib.types.path;
      readOnly = true;
      description = "User-specific secrets directory.";
    };
    sopsFile = lib.mkOption {
      type = lib.types.anything;
      readOnly = true;
      description = "Resolve a secret file path with host/user fallbacks.";
    };
  };

  config = let
    inherit (config.homelab.secrets) root;
    hostDir = root + "/hosts/${hostname}";
    userDir = root + "/users/${hostConfig.user}";
    resolve = name: let
      hostPath = hostDir + "/${name}";
      userPath = userDir + "/${name}";
      rootPath = root + "/${name}";
      resolvedPath =
        if builtins.pathExists hostPath
        then hostPath
        else if builtins.pathExists userPath
        then userPath
        else rootPath;
    in
      builtins.path {
        path = resolvedPath;
        name = builtins.baseNameOf resolvedPath;
      };
  in {
    homelab.secrets = {
      inherit hostDir userDir;
      sopsFile = resolve;
    };
  };
}
