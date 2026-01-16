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
    deployIdentity = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "If true, deploy the fleet identity key from SOPS secrets. Set false for isolated/sandbox VMs.";
    };
    identitySecretName = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.sshKeyName or "ssh_key_abl030";
      description = "The name of the SOPS secret file. Defaults to the value in hosts.nix.";
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
    # Can be disabled for isolated/sandbox VMs via deployIdentity = false
    sops.secrets."${cfg.identitySecretName}" = lib.mkIf cfg.deployIdentity {
      # Path is dynamically constructed based on the identitySecretName option
      sopsFile = ../../../../secrets/secrets/${cfg.identitySecretName};
      format = "binary";
      owner = user; # Dynamically set to the host user (e.g., abl030 or nixos)
      path = "${homeDirectory}/.ssh/id_ed25519"; # Dynamically set path to the correct home
      mode = "0600";
    };

    # 4. Declarative Known Hosts
    # Automatically trust all other hosts in the fleet defined in hosts.nix
    programs.ssh.knownHosts = let
      # Filter to find other hosts that have a valid public key
      otherHostsWithKeys =
        lib.filterAttrs (
          name: host:
            name != hostname && (host ? publicKey) && host.publicKey != ""
        )
        allHosts;
    in
      lib.mapAttrs' (
        name: host:
          lib.nameValuePair "homelab-${name}" {
            # Trust the hostname and the sshAlias.
            # Note: IP addresses are not currently in hosts.nix, so they are not added here.
            hostNames = [host.hostname host.sshAlias];
            inherit (host) publicKey;
          }
      )
      otherHostsWithKeys;
  };
}
