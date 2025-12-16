{
  lib,
  config,
  ...
}: let
  cfg = config.homelab.ssh;
in {
  imports = [
    ../../../hosts/common/user_keys.nix
    ../../../hosts/services/system/ssh_nosleep.nix
  ];

  options.homelab.ssh = {
    enable = lib.mkEnableOption "Standard SSH Configuration";
    secure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "If true, disable password auth and root login. Set false for new installs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Enable OpenSSH
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

    # 2. Decrypt the Master Identity (System Level)
    # We do this here because only root can read the Host Key needed to decrypt it
    sops.secrets.ssh_key_abl030 = {
      sopsFile = ../../../secrets/secrets/ssh_key_abl030;
      format = "binary";
      owner = "abl030"; # We set the owner to your user
      path = "/home/abl030/.ssh/id_ed25519"; # We force the path to your SSH dir
      mode = "0600";
    };
  };
}
