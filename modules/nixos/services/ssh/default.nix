{
  lib,
  config,
  pkgs,
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
      sopsFile = config.homelab.secrets.sopsFile cfg.identitySecretName;
      format = "binary";
      owner = user; # Dynamically set to the host user (e.g., abl030 or nixos)
      path = "${homeDirectory}/.ssh/id_ed25519"; # Dynamically set path to the correct home
      mode = "0600";
    };

    # 3b. Mirror the fleet identity into root's ~/.ssh so `nixos-rebuild`
    # (which runs as root during auto-upgrade) can fetch `git+ssh://` flake
    # inputs like vinsight-mcp. See issue #210 and
    # docs/wiki/infrastructure/github-pat-and-private-inputs.md.
    system.activationScripts.rootFleetIdentity = lib.mkIf cfg.deployIdentity {
      deps = ["setupSecrets" "users"];
      text = ''
        src="${homeDirectory}/.ssh/id_ed25519"
        if [ -r "$src" ]; then
          ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root /root/.ssh
          ${pkgs.coreutils}/bin/install -m 0400 -o root -g root "$src" /root/.ssh/id_ed25519
        fi
      '';
    };

    # 3c. System-wide SSH client config: route github.com through the fleet
    # identity — but ONLY for root, so regular users' `git push` continues to
    # work with their own ~/.ssh/config (or default identity handling).
    # Pin algorithms and disable agent/pubkey fallback so a misplaced agent
    # socket or stray key can't authenticate as someone else.
    programs.ssh.extraConfig = lib.mkIf cfg.deployIdentity ''
      Match User root Host github.com
        User git
        IdentityFile /root/.ssh/id_ed25519
        IdentitiesOnly yes
        HostKeyAlgorithms ssh-ed25519
        PubkeyAcceptedAlgorithms ssh-ed25519
    '';

    # 4. Declarative Known Hosts
    # Automatically trust all other hosts in the fleet defined in hosts.nix
    # plus GitHub (pinned so `git+ssh://` fetches never TOFU).
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
              # Trust the hostname and the sshAlias.
              # Note: IP addresses are not currently in hosts.nix, so they are not added here.
              hostNames = [host.hostname host.sshAlias];
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
