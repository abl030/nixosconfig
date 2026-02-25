{
  lib,
  config,
  hostConfig,
  allHosts,
  ...
}: let
  cfg = config.homelab.gotify;
  gotifyServerHosts = lib.attrNames (
    lib.filterAttrs (_: host: host.gotifyServer or false) allHosts
  );
  managementHosts = lib.attrNames (
    lib.filterAttrs (
      _: host:
        (host ? containerStacks)
        && lib.elem "management" host.containerStacks
    )
    allHosts
  );
  autoHostName =
    if gotifyServerHosts != []
    then builtins.head (lib.sort lib.lessThan gotifyServerHosts)
    else if managementHosts != []
    then builtins.head (lib.sort lib.lessThan managementHosts)
    else "doc2";
  hostName =
    if cfg.host != null
    then cfg.host
    else autoHostName;
  gotifyHost = allHosts.${hostName} or null;
  gotifyIp =
    if gotifyHost != null && gotifyHost ? localIp
    then gotifyHost.localIp
    else hostName;
in {
  options.homelab.gotify = {
    enable = lib.mkEnableOption "Gotify token provisioning for agent pings" // {default = true;};

    host = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "hosts.nix name for the Gotify server (used to resolve localIp). Null picks the first host with gotifyServer = true, then management stack, then doc2.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8050;
      description = "Gotify HTTP port.";
    };

    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = config.homelab.secrets.sopsFile "gotify.env";
      description = "Sops file containing GOTIFY_TOKEN.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User that should be able to read the Gotify token.";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Computed Gotify endpoint (IP-based).";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.gotify.endpoint = "http://${gotifyIp}:${toString cfg.port}";

    sops.secrets."gotify/token" = {
      inherit (cfg) sopsFile;
      format = "dotenv";
      key = "GOTIFY_TOKEN";
      owner = cfg.user;
      mode = "0400";
    };

    environment.sessionVariables.GOTIFY_TOKEN_FILE =
      config.sops.secrets."gotify/token".path;
  };
}
