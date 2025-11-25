{
  lib,
  config,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.vnc;
in {
  options.homelab.vnc = {
    enable = mkEnableOption "Enable WayVNC User Service";
    secure = mkEnableOption "Enable Secure Mode (PAM Auth & TLS Encryption)";
  };

  config = mkIf cfg.enable {
    home.packages = [pkgs.wayvnc];

    # Create wayvnc config file based on secure flag
    xdg.configFile."wayvnc/config" = {
      text =
        if cfg.secure
        then ''
          address=0.0.0.0
          port=5900
          enable_auth=true
          enable_pam=true
          private_key_file=/run/secrets/wayvnc_key
          certificate_file=/run/secrets/wayvnc_cert
        ''
        else ''
          address=0.0.0.0
          port=5900
          enable_auth=false
          enable_pam=false
        '';
      # Trigger a restart of the service if config changes (if using systemd service)
      # onChange = ...
    };
  };
}
