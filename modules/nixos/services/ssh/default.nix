{
  lib,
  config,
  ...
}: let
  cfg = config.homelab.ssh;
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

    # 2. Authorized Keys (Merged from hosts/common/user_keys.nix)
    users.users.abl030.openssh.authorizedKeys.keys = [
      # Master Fleet Identity
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity"
      # Manual Keys (from home/ssh/authorized_keys)
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK9aE9VRI+2to5Iy04f/MvPfbs6E5q0xTjnErPC4pEjR cullenwines\andy.b@CW-PC001"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJnFw/zW4X+1pV2yWXQwaFtZ23K5qquglAEmbbqvLe5g root@pihole"
    ];

    # 3. Decrypt the Master Identity (System Level)
    # We do this here because only root can read the Host Key needed to decrypt it
    sops.secrets.ssh_key_abl030 = {
      # FIXED: Added one more "../" to reach the project root from modules/nixos/services/ssh/
      sopsFile = ../../../../secrets/secrets/ssh_key_abl030;
      format = "binary";
      owner = "abl030"; # We set the owner to your user
      path = "/home/abl030/.ssh/id_ed25519"; # We force the path to your SSH dir
      mode = "0600";
    };
  };
}
