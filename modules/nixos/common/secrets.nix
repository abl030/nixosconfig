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
    hasSetupSecrets = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      description = ''
        Whether sops-nix defines the `setupSecrets` activation script here.

        It only does so when at least one secret is not `neededForUsers` and
        systemd activation is off. A host that consumes no secrets at all — an
        appliance like imagegen, with privateFlakeAuth and atuinCredentials
        both false — therefore has no such script, and any activation script
        that unconditionally declares `deps = ["setupSecrets"]` fails to
        evaluate with `attribute 'setupSecrets' missing`.

        Gate the dependency on this instead of assuming the script exists.
      '';
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
      # Mirrors sops-nix's own gate for the script (modules/sops/default.nix:
      # `setupSecrets = mkIf (regularSecrets != {} && !useSystemdActivation)`,
      # where regularSecrets drops the neededForUsers ones).
      hasSetupSecrets =
        !config.sops.useSystemdActivation
        && lib.any (s: !s.neededForUsers) (lib.attrValues config.sops.secrets);
    };
  };
}
