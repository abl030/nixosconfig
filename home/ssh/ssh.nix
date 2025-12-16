{
  config,
  inputs,
  ...
}: {
  # 1. Inject the Master Private Key via Sops
  # This makes this user the "Master Identity" capable of decrypting secrets and SSHing to others.
  sops = {
    defaultSopsFile = ../../secrets/secrets/ssh_key_abl030;
    defaultSopsFormat = "binary";

    secrets.ssh_key_abl030 = {
      path = "${config.home.homeDirectory}/.ssh/id_ed25519";
      mode = "0600";
    };
  };

  # 2. Clean SSH Client Config
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false; # We control the config

    # Standard Aliases (DNS/Tailscale names, no localhots hacks)
    matchBlocks = {
      "epi" = {
        hostname = "epimetheus";
        user = "abl030";
      };
      "cad" = {
        hostname = "caddy";
        user = "abl030";
      };
      "fra" = {
        hostname = "framework";
        user = "abl030";
      };
      "igp" = {
        hostname = "igpu";
        user = "abl030";
      };
      "prox" = {
        hostname = "proxmox-vm";
        user = "abl030";
      };
      "wsl" = {
        hostname = "nixos";
        user = "nixos";
      };

      # Global Defaults
      "*" = {
        ForwardAgent = true; # Useful for git
        SetEnv = {TERM = "xterm-256color";};

        # Explicitly disable X11
        ForwardX11 = false;
        ForwardX11Trusted = false;
      };
    };
  };
}
