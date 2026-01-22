{
  lib,
  config,
  hostConfig,
  ...
}: let
  cfg = config.homelab.gotify;
in {
  options.homelab.gotify = {
    enable = lib.mkEnableOption "Gotify token provisioning for agent pings";

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
  };

  config = lib.mkIf cfg.enable {
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
