{
  lib,
  config,
  hostConfig,
  allHosts,
  ...
}: let
  cfg = config.homelab.gotify;
  gotifyHost = allHosts.${cfg.host} or null;
  gotifyIp =
    if gotifyHost != null && gotifyHost ? localIp
    then gotifyHost.localIp
    else cfg.host;
in {
  options.homelab.gotify = {
    enable = lib.mkEnableOption "Gotify token provisioning for agent pings" // {default = true;};

    host = lib.mkOption {
      type = lib.types.str;
      default = "proxmox-vm";
      description = "hosts.nix name for the Gotify server (used to resolve localIp).";
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
