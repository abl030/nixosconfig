{
  lib,
  pkgs,
  config,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    ../../modules/nixos/services/podcast.nix
  ];

  # Forgejo push token for the rolling-flake-update bot (nixbot). Decryptable by
  # doc1 only (per-host sops scope, #234); read by the bot service (User=abl030)
  # and sent as an Authorization header on push. See
  # docs/wiki/infrastructure/signed-fleet-deploys.md.
  sops.secrets."forgejo/nixbot-token" = {
    sopsFile = config.homelab.secrets.sopsFile "forgejo-nixbot-token";
    format = "binary";
    owner = "abl030";
    mode = "0400";
  };

  homelab = {
    mounts = {
      nfsLocal.enable = true;
      nfsLocal.readOnly = false; # Safety during podman testing
      mumNfs.enable = true;
      fuse.enable = true;
    };
    # Bastion front door is key-only (#270 step 4): no password auth, no root
    # login. Entry is via the from=-pinned bastionKeys only. Break-glass if ever
    # locked out: Proxmox console on prom (console login is unaffected by this).
    ssh.secure = true;

    # doc1 is the bastion: the ONLY host that holds the fleet identity private
    # key (deployIdentity defaults to false everywhere else now). This is what
    # lets doc1 reach the keyless siblings. See issue #270.
    ssh.deployIdentity = true;

    # forgejo#2: doc1 is the ONE bastion. role = "bastion" gives it passwordless
    # sudo (base.nix), the passwordless diagnostic tools, the deploy-trigger
    # private key, and the `fleet-deploy <host>` wrapper to kick a sibling's
    # verified rebuild over a forced-command key (no sudo on the sibling). Every
    # other host defaults to role = "locked"; fleetBastionRoleCheck asserts this
    # is the only host that sets "bastion".
    fleetDeploy.role = "bastion";

    # MCP agent creds live ONLY here (#234): doc1 is the sole host the
    # pfsense/unifi/HA/slskd/vinsight/abs/paperless control agents run from.
    # Base default is now false everywhere.
    mcp = {
      enable = true;
      pfsense.enable = true;
      unifi.enable = true;
      homeassistant.enable = true;
      slskd.enable = true;
      vinsight.enable = true;
      audiobookshelf.enable = true;
      paperless.enable = true;
    };

    # Base.nix enables tailscale=true.

    # Base.nix enables update=true.
    # We just add specific timing/dates here.
    update = {
      updateDates = "03:00";
      gcDates = "03:30";
      rebootOnKernelUpdate = true;
    };

    cache = {
      enable = true;
      mirrorHost = "nix-mirror.ablz.au";
      localHost = "nixcache.ablz.au";
      nixServeSecretKeyFile = "/var/lib/nixcache/secret.key";
    };

    # Override profile from "internal" (base default) to "server"
    nixCaches.profile = "server";

    ci.rollingFlakeUpdate = {
      enable = true;
      repoDir = "/home/abl030/nixosconfig";
      onCalendar = "23:00"; # AWST (15:00 UTC) — out of the way of interactive coding
      # Push to Forgejo (write root, #235). remoteUrl defaults to git.ablz.au;
      # clone is anonymous (public repo), push uses this token via a header.
      pushTokenFile = config.sops.secrets."forgejo/nixbot-token".path;
    };
    services = {
      # Immich moved to doc2 (2026-02-25)
      immich.enable = false;

      # SSE bridge that streams this host's Claude transcripts to the phone.
      # Tailnet-only via homelab.localProxy.tailscaleOnly; bound to
      # voice.ablz.au which Cloudflare resolves to the Tailscale IP.
      claude-voice = {
        enable = true;
        user = "abl030";
      };
      # doc1 is the launch point for the Hermes full-operator TUI (only host that
      # can reach hermes + decrypt the operator keys). Installs `hermes-operator`.
      hermesOperatorLauncher.enable = true;
    };
  };

  # Base.nix enables NetworkManager.
  # We just set interface specifics here.
  networking = {
    interfaces.ens18.mtu = 1400;
    firewall = {
      enable = true;
      allowedTCPPorts = [8096];
    };
  };

  boot.kernel.sysctl = {
    # Allow rootless containers to use ping (required by smokeping/fping).
    "net.ipv4.ping_group_range" = "0 2147483647";
  };

  # VM Specifics
  services.qemuGuest.enable = true;

  # Workloads
  virtualisation.docker = {
    enable = false;
    liveRestore = false;
  };

  # ADD ONLY HOST SPECIFIC GROUPS
  users.users.abl030 = {
    extraGroups = ["libvirtd" "vboxusers"];
  };

  environment.systemPackages = lib.mkOrder 3000 (with pkgs; [
    butane
  ]);

  # NOTE: doc1 is the bastion (homelab.fleetDeploy.role = "bastion") →
  # `wheelNeedsPassword = false`, so abl030 already has GLOBAL passwordless sudo
  # and this allowlist is currently redundant. It's kept as the *explicit
  # deploy/debug allowlist* — the set we'd keep NOPASSWD if doc1 were ever
  # flipped to password-required (role = "locked"). The
  # unbounded `cat` and `rm` primitives were removed 2026-06-19 (#232): they let
  # any abl030-context process read the fleet key / delete audit logs with no
  # auth, and `cat`/`rm` are NOT something the deploy/debug path needs as a
  # blanket grant. (doc1 staying globally passwordless is the accepted
  # bastion/automation-host posture — same risk profile as the nightly agent.)
  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/systemctl";
          options = ["NOPASSWD"];
        }
        {
          command = "/run/current-system/sw/bin/journalctl";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
    };
    "/boot" = {
      device = "/dev/disk/by-label/BOOT";
      fsType = "vfat";
    };
    # Virtiofs mount — persistent service state on ZFS on the Proxmox host
    "/mnt/virtio" = {
      device = "containers";
      fsType = "virtiofs";
      options = ["rw" "relatime"];
    };
  };

  systemd.tmpfiles.rules = [
    "d /mnt/virtio 0755 root root - -"
  ];

  system.stateVersion = "24.05";
}
