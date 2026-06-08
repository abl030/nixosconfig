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
      # Keyless by default (#270): the fleet identity private key lives ONLY on
      # the doc1 bastion, which sets this true. Every other host stays false so
      # a popped sibling holds no fleet-trusted key and can't move laterally.
      default = false;
      description = "If true, deploy the fleet identity key from SOPS secrets. ONLY the doc1 bastion should set this; siblings stay keyless (see issue #270).";
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
      sopsFile = config.homelab.secrets.sopsFile cfg.identitySecretName;
      format = "binary";
      owner = user; # Dynamically set to the host user (e.g., abl030 or nixos)
      path = "${homeDirectory}/.ssh/id_ed25519"; # Dynamically set path to the correct home
      mode = "0600";
    };

    # On keyless (non-bastion) hosts, assert the fleet key is GONE from root's
    # ~/.ssh. The old rootFleetIdentity mirror (removed in #270 step 2a) may have
    # left a real copy behind; sops-nix only cleans the user-key symlink it
    # manages, not this. Idempotent `r` — no-op where already absent. See #270.
    systemd.tmpfiles.rules = lib.mkIf (!cfg.deployIdentity) [
      "r /root/.ssh/id_ed25519 - - - -"
    ];

    # (Former 3b/3c removed in #270.) root no longer needs the fleet key
    # mirrored into /root/.ssh, and no longer routes github.com through it:
    # the last `git+ssh://` flake input (vinsight-mcp) now fetches via
    # github: + the nix-netrc PAT, so no fleet host SSHes to GitHub for flake
    # inputs. This is what lets siblings drop the fleet key entirely
    # (deployIdentity = false). See issue #270.

    # 4. Declarative Known Hosts
    # Automatically trust all other hosts in the fleet defined in hosts.nix
    # plus GitHub (pinned so SSH `git push` to github.com never TOFUs).
    programs.ssh.knownHosts = let
      # Filter to find other hosts that have a valid public key
      otherHostsWithKeys =
        lib.filterAttrs (
          name: host:
            name != hostname && (host ? publicKey) && host.publicKey != ""
        )
        allHosts;

      fleetKnownHosts =
        lib.mapAttrs' (
          name: host:
            lib.nameValuePair "homelab-${name}" {
              # Trust the hostname and the sshAlias, plus any sshHostName override
              # (e.g. wsl, reached via the Windows host's Tailscale port-forward —
              # the key presented there is still the VM's own host key).
              # Note: IP addresses are not currently in hosts.nix, so they are not added here.
              hostNames =
                lib.unique ([host.hostname host.sshAlias]
                  ++ lib.optional (host ? sshHostName) host.sshHostName);
              inherit (host) publicKey;
            }
        )
        otherHostsWithKeys;

      # GitHub's documented SSH host keys — see
      # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
      # Update if GitHub rotates (rare; last rotation 2023-03-24 for RSA).
      githubKnownHosts = {
        "github.com-ed25519" = {
          hostNames = ["github.com"];
          publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
        };
      };
    in
      fleetKnownHosts // (lib.optionalAttrs cfg.deployIdentity githubKnownHosts);
  };
}
