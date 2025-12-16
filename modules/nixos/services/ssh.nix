{
  lib,
  config,
  ...
}: let
  cfg = config.homelab.ssh;
in {
  # FIX: Go up 3 levels because this file is in modules/nixos/services/
  imports = [
    ../../../hosts/common/user_keys.nix
    ../../../hosts/services/system/ssh_nosleep.nix
  ];

  options.homelab.ssh = {
    enable = lib.mkEnableOption "Standard SSH Configuration";
    secure = lib.mkOption {
      type = lib.types.Bool;
      default = true;
      description = "If true, disable password auth and root login. Set false for new installs.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.openssh = {
      enable = true;
      openFirewall = true;

      settings = {
        PermitRootLogin =
          if cfg.secure
          then "no"
          else "prohibit-password";
        PasswordAuthentication = !cfg.secure;
        KbdInteractiveAuthentication = !cfg.secure;
        X11Forwarding = false;
      };
    };
  };
}
