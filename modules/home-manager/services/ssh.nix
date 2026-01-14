{
  config,
  lib,
  allHosts,
  ...
}: let
  cfg = config.homelab.ssh;
in {
  options.homelab.ssh = {
    enable = lib.mkEnableOption "SSH configuration";
  };

  config = lib.mkIf cfg.enable {
    # sops = {
    #   # Make HM's sops-nix happy (HM reads its own sops.* options)
    #   # age.keyFile = lib.mkDefault "${config.xdg.configHome}/sops/age/keys.txt";
    #   # age.generateKey = lib.mkDefault true;
    #
    #   # 1. Inject the Master Private Key via Sops
    #   # This makes this user the "Master Identity" capable of decrypting secrets and SSHing to others.
    #
    #   defaultSopsFile = ../../secrets/secrets/ssh_key_abl030;
    #   defaultSopsFormat = "binary";
    #
    #   secrets.ssh_key_abl030 = {
    #     path = "${config.home.homeDirectory}/.ssh/id_ed25519";
    #     mode = "0600";
    #   };
    # };

    # 2. Clean SSH Client Config
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false; # We control the config

      # Generate matchBlocks dynamically from hosts.nix
      matchBlocks = let
        # Helper to generate blocks for every host defined in hosts.nix
        # We use mapAttrs' (prime) to rename the key from the internal ID (e.g. "epimetheus")
        # to the sshAlias (e.g. "epi").
        # Filter out entries starting with "_" (e.g., _proxmox config block)
        actualHosts = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) allHosts;
        generatedHosts =
          lib.mapAttrs' (_: hostConfig: {
            name = hostConfig.sshAlias;
            value = {
              inherit (hostConfig) hostname user;
            };
          })
          actualHosts;
      in
        generatedHosts
        // {
          # Global Defaults (merged at the end)
          "*" = {
            forwardAgent = true; # Useful for git
            setEnv = {TERM = "xterm-256color";};

            # Explicitly disable X11
            forwardX11 = false;
            forwardX11Trusted = false;
          };
        };
    };
  };
}
