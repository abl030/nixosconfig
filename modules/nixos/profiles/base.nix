# modules/nixos/profiles/base.nix
{
  lib,
  pkgs,
  config,
  hostConfig,
  ...
}: {
  # ---------------------------------------------------------
  # 0. IDENTITY & BOOTSTRAP
  # ---------------------------------------------------------
  networking.hostName = hostConfig.hostname;

  # Default Bootloader (Standard UEFI)
  # WSL and specialty hosts should override this to false
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # ---------------------------------------------------------
  # 1. LOCALES & TIME
  # ---------------------------------------------------------
  time.timeZone = "Australia/Perth";
  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "en_AU.UTF-8";
    LC_IDENTIFICATION = "en_AU.UTF-8";
    LC_MEASUREMENT = "en_AU.UTF-8";
    LC_MONETARY = "en_AU.UTF-8";
    LC_NAME = "en_AU.UTF-8";
    LC_NUMERIC = "en_AU.UTF-8";
    LC_PAPER = "en_AU.UTF-8";
    LC_TELEPHONE = "en_AU.UTF-8";
    LC_TIME = "en_AU.UTF-8";
  };

  # ---------------------------------------------------------
  # 2. NIX SETTINGS
  # ---------------------------------------------------------
  nixpkgs.config.allowUnfree = true;

  nix = {
    settings = {
      experimental-features = ["nix-command" "flakes"];
      download-buffer-size = 256 * 1024 * 1024; # 256 MB
      auto-optimise-store = true;
      netrc-file = config.sops.secrets.nix-netrc.path;
      # Allow the admin user to copy unsigned store paths via SSH
      # (fleet-internal deploys with nixos-rebuild --target-host).
      trusted-users = ["root" hostConfig.user];
    };

    # Include access-tokens at runtime for private flake metadata resolution.
    # The file is derived from nix-netrc by an activation script below.
    extraOptions = ''
      !include /run/secrets/nix-access-tokens
    '';

    # Garbage Collection (Weekly fallback)
    # The homelab.update module below will take precedence if enabled
    gc = {
      automatic = lib.mkDefault true;
      dates = lib.mkDefault "02:00";
      options = lib.mkDefault "--delete-older-than 3d";
    };
  };

  # ---------------------------------------------------------
  # 3. CORE SERVICES & HARDWARE
  # ---------------------------------------------------------
  # Reasonable default for most servers/desktops (SSDs/VirtIO)
  services.fstrim.enable = lib.mkDefault true;

  # Standard Networking
  networking.networkmanager.enable = lib.mkDefault true;

  # Route resolution through systemd-resolved so Tailscale can publish MagicDNS
  # (100.100.100.100 + ts.net search domain) into a real local resolver. Without
  # resolved, NetworkManager owns /etc/resolv.conf directly and tailscale's
  # CorpDNS has nowhere to land — so tailscaled clobbers resolv.conf to point at
  # 100.100.100.100 and falls back to its own (flaky, often upstream-less) DNS,
  # which SERVFAILs/times out while roaming. Staged in via epimetheus then
  # promoted here (GitHub #262). mkDefault so hosts can opt out:
  #   - WSL: NM disabled, manages its own resolv.conf → resolved.enable = false.
  #   - mk-pg/mk-mariadb containers already run resolved in their own netns.
  # See docs/wiki/infrastructure/systemd-resolved-fleet.md (incl. the pfSense
  # :53 lockdown+redirect and the dig-vs-getent diagnosis gotcha).
  services.resolved.enable = lib.mkDefault true;
  networking.networkmanager.dns = lib.mkDefault "systemd-resolved";

  # ---------------------------------------------------------
  # 3b. COREDUMP LIMITS
  # ---------------------------------------------------------
  # Cap coredump storage to prevent crash-looping containers (e.g. Ombi)
  # from filling disk. Keeps recent dumps available for debugging.
  systemd.coredump.settings.Coredump = {
    MaxUse = "100M";
  };

  # ---------------------------------------------------------
  # 4. HOMELAB "BATTERIES INCLUDED" DEFAULTS
  # ---------------------------------------------------------
  # By using mkDefault, we ensure every new machine is manageable
  # immediately, but power users (Epi/Framework) can tune settings.

  homelab = {
    # 1. Access
    ssh = {
      enable = lib.mkDefault true;
      # Default to secure (keys only), override to false for debug/install
      secure = lib.mkDefault true;
    };

    tailscale = {
      enable = lib.mkDefault true;
      # Base server doesn't need TPM override usually, unless it's a VM hopping hosts
      tpmOverride = lib.mkDefault false;
    };

    # 2. Maintenance
    update = {
      enable = lib.mkDefault true;
      collectGarbage = lib.mkDefault true;
      trim = lib.mkDefault true;
      # Don't reboot by default, let specific servers opt-in
      rebootOnKernelUpdate = lib.mkDefault false;
      # claude -p triage of nightly nixos-upgrade failures → Gotify + journal
      # (queried by the triage-overnight skill). One-time bootstrap per host:
      # `sudo -u <user> --login claude` then complete the OAuth flow. Until
      # bootstrapped, falls back to raw-log Gotify (same as pre-diagnose).
      diagnose.enable = lib.mkDefault true;
      # Signed-fleet-deploys enforcement (Phase C, fleet-wide after igpu canary).
      # Every auto-updating host runs the verified fleet-update path nightly.
      # enforce changes only the nightly path — manual `nixos-rebuild` is
      # unaffected. Heartbeat staleness thresholds for the in-deploy freshness
      # check come from checkAcPower (laptop 72h, else 30h); the hourly paging
      # watchdog was removed 2026-06-13 (duplicate alert noise — the rolling
      # update bot already pages on failure).
      # See docs/wiki/infrastructure/signed-fleet-deploys.md.
      verify = {
        enforce = lib.mkDefault true;
        # Forgejo is the write root (#235). Fetch Forgejo first; GitHub stays a
        # configured fallback origin but, with no push-mirror yet, it is FROZEN
        # at the cutover commit — a linear ancestor of Forgejo's tip, so it never
        # wins candidate selection and never diverges (no tamper). writeRoot =
        # forgejo means a target must be contained in Forgejo's master: if
        # Forgejo is unreachable the host cleanly skips ("refusing to deploy from
        # fallback alone") rather than deploying the stale GitHub tip. When the
        # mirror lands later, GitHub silently becomes a hot fallback again.
        origins = lib.mkDefault {
          forgejo = "https://git.ablz.au/abl030/nixosconfig.git";
          github = "https://github.com/abl030/nixosconfig.git";
        };
        writeRoot = lib.mkDefault "forgejo";
      };
    };

    # 3. Caching
    nixCaches = {
      enable = lib.mkDefault true;
      # "internal" is safe for everything inside the LAN
      profile = lib.mkDefault "internal";
    };

    gotify = {
      enable = lib.mkDefault true;
    };

    loki = {
      enable = lib.mkDefault true;
    };

    prometheus = {
      enable = lib.mkDefault true;
    };

    syncthing = {
      enable = lib.mkDefault true;
    };

    mdnsReflector = {
      enable = lib.mkDefault false;
    };

    # MCP control creds → doc1-only (#234). Default OFF fleet-wide; doc1 opts in
    # (the sole host the pfsense/unifi/HA/etc. agents run from). Previously these
    # decrypted to /run/secrets/mcp on every host — three infra-control tokens
    # fleet-wide (#232 Tier-1).
    mcp = {
      enable = lib.mkDefault false;
      pfsense.enable = lib.mkDefault false;
      unifi.enable = lib.mkDefault false;
      homeassistant.enable = lib.mkDefault false;
      slskd.enable = lib.mkDefault false;
      vinsight.enable = lib.mkDefault false;
      audiobookshelf.enable = lib.mkDefault false;
      paperless.enable = lib.mkDefault false;
    };
  };

  # ---------------------------------------------------------
  # 4b. PRIVATE FLAKE AUTH
  # ---------------------------------------------------------
  sops.secrets = {
    nix-netrc = {
      sopsFile = config.homelab.secrets.sopsFile "nix-netrc";
      format = "binary";
    };

    # Atuin sync credentials — deploy session token and encryption key
    # so `atuin sync` works on every host without manual `atuin login`.
    atuin-session = {
      sopsFile = config.homelab.secrets.sopsFile "atuin-session";
      format = "binary";
      owner = hostConfig.user;
      path = "${hostConfig.homeDirectory}/.local/share/atuin/session";
      mode = "0600";
    };
    atuin-key = {
      sopsFile = config.homelab.secrets.sopsFile "atuin-key";
      format = "binary";
      owner = hostConfig.user;
      path = "${hostConfig.homeDirectory}/.local/share/atuin/key";
      mode = "0600";
    };
  };

  # Derive access-tokens from netrc so flake metadata resolution works
  # for public GitHub repos without hitting anonymous rate limits. If the
  # token is definitively 401/403 (rotated/revoked) we fall back to an
  # empty file — a stale token poisons *every* github.com fetch with 401,
  # so absence is strictly better than staleness. Network blips preserve
  # the token (we only invalidate on a definitive GitHub response).
  #
  # The same script runs as an ExecStartPre on nixos-upgrade.service so
  # the next scheduled upgrade refreshes access-tokens BEFORE it fetches
  # the flake, not after. See issue #210,
  # modules/nixos/lib/refresh-access-tokens.nix, and
  # docs/wiki/infrastructure/github-pat-and-private-inputs.md.
  system.activationScripts.nix-access-tokens = {
    deps = ["setupSecrets"];
    text = ''
      ${import ../lib/refresh-access-tokens.nix {inherit pkgs;}}
    '';
  };

  # ---------------------------------------------------------
  # 5. SHELL & ENVIRONMENT
  # ---------------------------------------------------------
  # Enforce Zsh for everything
  environment.pathsToLink = ["/share/zsh"];

  programs = {
    zsh.enable = true;
    bash.blesh.enable = true;
    nix-ld.enable = true;
  };

  environment.systemPackages = lib.mkOrder 1000 (with pkgs; [
    # Core
    git
    openssl
    python3
    uv # uvx for running Python tools (e.g. mcp-nixos)
    vim
    wget
    curl
    home-manager
    nvd # For activation diffs

    # Process & resource
    htop
    btop
    strace
    lsof
    killall

    # Networking
    dnsutils # dig, nslookup
    tcpdump
    nmap
    mtr
    traceroute

    # Disk & filesystem
    cloud-utils # growpart for online partition resizing
    parted
    iotop
    smartmontools # smartctl
    pciutils # lspci
    usbutils # lsusb

    # Hardware & diagnostics
    dmidecode
    lm_sensors # sensors
    hwinfo

    # Memory
    sysstat # vmstat etc.

    # Logs & search
    ripgrep
    jq

    # TUI utilities (auto-updated via flake inputs + rolling-flake-update)
    netwatch # real-time network diagnostics — like htop for your network
    sheets # terminal-based spreadsheet

    # Nix-specific
    nix-diff
    nix-tree
  ]);

  # Pretty diffs on rebuild
  system.activationScripts.diff = ''
    if [[ -e /run/current-system ]]; then
      echo "--- diff to current-system"
      ${pkgs.nvd}/bin/nvd --nix-bin-dir=${config.nix.package}/bin diff /run/current-system "$systemConfig"
      echo "---"
    fi
  '';

  # ---------------------------------------------------------
  # 6. ADMIN USER
  # ---------------------------------------------------------
  # Dynamically configure the user defined in hosts.nix
  users.users.${hostConfig.user} =
    {
      isNormalUser = true;
      description = "Andy";
      shell = pkgs.zsh;

      # Core groups. Hosts can add more (e.g. docker) via extraGroups in their own config
      extraGroups = ["wheel" "networkmanager"];

      # Automatically pull authorized keys from hosts.nix
      openssh.authorizedKeys.keys = hostConfig.authorizedKeys or [];
    }
    // lib.optionalAttrs (hostConfig ? initialHashedPassword) {
      # Optional per-host initial password hash (set in hosts.nix).
      # This allows initial access without passwordless sudo and won't
      # overwrite a password you've already changed on the host.
      inherit (hostConfig) initialHashedPassword;
    };

  # ---------------------------------------------------------
  # 7. SUDO POLICY
  # ---------------------------------------------------------
  # Allow per-host control for automation/test VMs via hosts.nix.
  # forgejo#2 — one knob drives the whole posture: only the bastion (doc1,
  # homelab.fleetDeploy.role = "bastion") gets passwordless sudo + the
  # passwordless diagnostic tools below. Every other host defaults to
  # role = "locked" → wheelNeedsPassword = true, GTFOBins gated off. Reading the
  # module option here is safe: role has a plain default and never depends on
  # security.sudo.*, so there's no eval cycle.
  security.sudo = {
    enable = lib.mkDefault true;
    wheelNeedsPassword = lib.mkDefault (config.homelab.fleetDeploy.role != "bastion");

    # Passwordless tailscale for post-provision automation.
    # Allows `sudo tailscale up --authkey ...` without password prompt.
    #
    # NOTE: the rule MUST name the path the user actually invokes —
    # `/run/current-system/sw/bin/tailscale` — NOT the `${pkgs.tailscale}` store
    # path. Verified empirically: sudo matches the literal command path resolved
    # via secure_path and does NOT canonicalise the `tailscale -> tailscaled`
    # symlink, so a rule naming the store-path binary never matches `sudo
    # tailscale ...` and silently falls through to a password prompt. The
    # `dmesg` rule below uses the same `/run/current-system/sw/bin` form.
    #
    # BLAST RADIUS (least-privilege audit, issue #232): this grants
    # `${hostConfig.user}` passwordless root to the FULL tailscale CLI surface,
    # not just `tailscale up` — e.g. `tailscale up --ssh`, `tailscale set`,
    # `tailscale debug`, `tailscale file`. Accepted deliberately: the user is
    # already in `wheel`, sudoers argument matching is bypassable (so scoping to
    # `tailscale up *` would be false comfort), and the diagnostic `sudo
    # tailscale ...` calls this unblocks are used constantly. The trust boundary
    # is the tailnet ACL, not local sudo.
    #
    # GATED ON role == "bastion" (forgejo#2): these are NOPASSWD ONLY on the
    # bastion (doc1), where ${hostConfig.user} already has passwordless root
    # anyway. On a LOCKED host this block is empty — several entries are GTFOBins
    # (`sudo strace sh`, `sudo tcpdump -z <script>`, `sudo nmap` --interactive →
    # root shell/exec) and would otherwise be a one-line bypass of the whole
    # lockdown. Locked hosts diagnose via the read-only allowlist
    # (homelab.fleetDeploy role = "locked") + Loki, or the host console.
    extraRules = lib.optionals (config.homelab.fleetDeploy.role == "bastion") [
      {
        users = [hostConfig.user];
        commands = [
          {
            command = "/run/current-system/sw/bin/tailscale";
            options = ["NOPASSWD"];
          }
          # Diagnostic tools that require root
          {
            command = "${pkgs.tcpdump}/bin/tcpdump";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.iotop}/bin/iotop";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.smartmontools}/bin/smartctl";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.dmidecode}/bin/dmidecode";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.nmap}/bin/nmap";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/dmesg";
            options = ["NOPASSWD"];
          }
          {
            command = "${pkgs.strace}/bin/strace";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];
  };
}
