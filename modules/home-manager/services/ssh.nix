# SSH client config + the per-host 1h-TTL ssh-agent (homelab.ssh.localAgent).
# Model, the IdentityFile lock-out trap, and the wsl finding:
# docs/wiki/infrastructure/ssh-bastion-model.md ("Passphrase caching" section).
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

    # Opt-in, per host. Runs a plain OpenSSH ssh-agent that hard-caps every
    # cached identity at 1h (`ssh-agent -t 3600`), so a passphrase-protected
    # key is re-prompted at most once an hour. This is our replacement for
    # GNOME's gcr-ssh-agent, which caches for the whole login session (no TTL).
    #
    # Turn ON for GNOME hosts (epi, framework) — and ALSO set
    # `services.gnome.gcr-ssh-agent.enable = false` in their *system* config so
    # the plain agent is the only SSH agent in play.
    #
    # Leave OFF on wsl: there $SSH_AUTH_SOCK is a Windows-side agent bridged in
    # by the WSL / Windows-Terminal launch (socket under ~/.ssh/agent, with no
    # $SSH_CONNECTION set), and the upstream ssh-agent module's shell hook would
    # clobber it. Headless servers don't need a local agent either.
    localAgent.enable =
      lib.mkEnableOption "a local 1h-TTL ssh-agent (replaces gcr-ssh-agent; opt-in per host)";
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
    #   defaultSopsFile = ../../secrets/ssh_key_abl030;
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
        # Defensive: filter out any entries starting with "_" (reserved for future non-host config blocks).
        actualHosts = lib.filterAttrs (name: _: !lib.hasPrefix "_" name) allHosts;
        generatedHosts =
          lib.mapAttrs' (_: hostConfig: {
            name = hostConfig.sshAlias;
            value = {
              # A host reachable at a name other than its system hostname (e.g.
              # wsl, fronted by the Windows host's Tailscale port-forward) sets
              # `sshHostName`; everyone else just uses their hostname.
              hostname = hostConfig.sshHostName or hostConfig.hostname;
              inherit (hostConfig) user;
            };
          })
          actualHosts;
      in
        generatedHosts
        // {
          # Termux on Galaxy A55 — joins the tailnet, sshd on 8022, Android-assigned UID user.
          phone = {
            hostname = "s-a55";
            user = "u0_a357";
            port = 8022;
            extraOptions = {
              ServerAliveInterval = "30";
              ServerAliveCountMax = "3";
            };
          };

          # Termux on the Boox e-reader. LAN-only for now (no tailnet); change
          # `hostname` to the tailnet name if the Boox ever joins Tailscale.
          boox = {
            hostname = "192.168.1.113";
            user = "u0_a133";
            port = 8022;
            extraOptions = {
              ServerAliveInterval = "30";
              ServerAliveCountMax = "3";
            };
          };

          # Global Defaults (merged at the end)
          "*" =
            {
              forwardAgent = true; # Useful for git
              setEnv = {TERM = "xterm-256color";};

              # Cache a passphrase-unlocked key in the agent, then drop it after
              # 1h and re-prompt. No-op where no agent runs; on hosts with
              # homelab.ssh.localAgent it is also enforced agent-side (-t 3600).
              addKeysToAgent = "1h";

              # Explicitly disable X11
              forwardX11 = false;
              forwardX11Trusted = false;
            }
            // lib.optionalAttrs cfg.localAgent.enable {
              # The personal key is non-default-named (~/.ssh/id_doc1). GNOME's
              # gcr-ssh-agent auto-loaded it; a plain ssh-agent does NOT, and
              # there is no default-named key for ssh to fall back on. So once
              # gcr is gone we must point ssh at the key explicitly — otherwise
              # it would offer nothing and lock us out. ssh loads it from disk,
              # prompts once, then AddKeysToAgent caches it for 1h.
              identityFile = "~/.ssh/id_doc1";
            };
        };
    };

    # Local ssh-agent with a hard 1h identity cap. Opt-in per host; see the
    # homelab.ssh.localAgent option above for the wsl carve-out and the
    # required gcr-ssh-agent disable on GNOME hosts.
    services.ssh-agent = lib.mkIf cfg.localAgent.enable {
      enable = true;
      defaultMaximumIdentityLifetime = 3600; # ssh-agent -t 3600
    };
  };
}
