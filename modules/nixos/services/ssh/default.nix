{
  lib,
  config,
  allHosts,
  hostname,
  ...
}: let
  cfg = config.homelab.ssh;
  hostConfig = allHosts.${hostname};
  inherit (hostConfig) user homeDirectory authorizedKeys;
in {
  imports = [
    ./inhibitors.nix
  ];

  options.homelab.ssh = {
    enable = lib.mkEnableOption "Standard SSH Configuration";
    secure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "If true, disable password auth and root login. Set false for new installs or internal VMs.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1. Enable OpenSSH
    services.openssh = {
      enable = true;
      ports = [22];
      # Be careful here. You can lock yourself out of a host if tailscale is down.
      openFirewall = true;

      # We bind to 0.0.0.0 as it is only used for proxyjump and we are fine to bind to all IPS.
      listenAddresses = [
        {
          addr = "0.0.0.0";
        }
      ];

      settings = {
        PermitRootLogin =
          if cfg.secure
          then "no"
          else "prohibit-password"; # "no" overrides this if set manually in host config, but logic holds

        PasswordAuthentication = !cfg.secure;
        KbdInteractiveAuthentication = !cfg.secure;

        # Basically as we are all in on tailscale SSH the only reason we need this is for X11 forwarding.
        X11Forwarding = true;
      };
    };

    # 2. Authorized Keys (Sourced from hosts.nix)
    users.users.${user}.openssh.authorizedKeys.keys = authorizedKeys;

    # 3. Decrypt the Master Identity (System Level)
    # We do this here because only root can read the Host Key needed to decrypt it
    sops.secrets.ssh_key_abl030 = {
      # FIXED: Added one more "../" to reach the project root from modules/nixos/services/ssh/
      sopsFile = ../../../../secrets/secrets/ssh_key_abl030;
      format = "binary";
      owner = user; # Dynamically set to the host user (e.g., abl030 or nixos)
      path = "${homeDirectory}/.ssh/id_ed25519"; # Dynamically set path to the correct home
      mode = "0600";
    };
  };
}
