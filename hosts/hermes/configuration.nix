# hermes — dedicated, locked-down VM on prom (VMID 115) whose sole job is to run
# the Hermes Agent (Nous Research) OCI container. Cloned from the NixOS template
# 9003 (seabios + GRUB, ext4 root on /dev/vda, single MBR partition).
#
# Security posture (see modules/nixos/services/hermes-agent.nix header for the
# full threat model): this host holds NO fleet key — it is keyless re: its
# siblings (hosts.nix → authorizedKeys = fleetKeys), so only the doc1 bastion can
# SSH in and a compromised agent cannot move laterally. The VM is the blast-radius
# boundary for an agent that executes LLM-generated code.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
  ];

  # Match template 9003 bootloader (seabios + GRUB), same as doc2/cache.
  boot.loader = {
    systemd-boot.enable = false;
    efi.canTouchEfiVariables = false;
    grub = {
      enable = true;
      devices = ["nodev"];
    };
  };

  homelab = {
    ssh = {
      enable = true;
      secure = true;
    };
    tailscale.enable = true;

    nixCaches = {
      enable = true;
      profile = "internal";
    };

    # Unattended appliance: auto-update from Forgejo (signed) and reboot on
    # kernel updates. The Hermes gateway reconnects to Telegram on restart.
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
      updateDates = "04:00";
      gcDates = "04:30";
    };

    # Single-purpose box — shed everything not needed. (Base still gives us
    # ssh/tailscale/signed-updates/loki/prometheus/gotify; we keep those for
    # management + observability of the agent.)
    syncthing.enable = false;

    # The Hermes Agent itself, with the web dashboard exposed tailnet-only.
    services.hermes-agent = {
      enable = true;
      dashboard = {
        enable = true;
        publicUrl = "https://hermes.ablz.au";
        user = "abl030";
      };
    };

    # Dashboard served ONLY on the tailnet at hermes.ablz.au (no LAN, no public),
    # gated by HTTP Basic Auth. Dedicated tailnet node "hermes-ui" — the host
    # itself is already "hermes". authKeySecret = null → the ts sidecar logs an
    # interactive login URL on first run (approve once, like the host did).
    tailscaleShare.hermes-dashboard = {
      enable = true;
      fqdn = "hermes.ablz.au";
      upstream = "http://host.docker.internal:9119";
      dataDir = "/var/lib/tailscale-share/hermes-dashboard";
      hostname = "hermes-ui";
      firewallPorts = [9119];
      authKeySecret = null;
      # No Uptime Kuma monitor: keep this locked-down VM free of the Kuma API
      # credential (it can edit/delete ALL monitors). The agent self-alerts via
      # gotify/Telegram; add an external monitor from a monitor-running host if
      # ever wanted.
      monitorEnable = false;
    };
  };

  # Cloudflare DNS-01 token for the tailscaleShare ACME cert + A-record sync
  # (hermes.ablz.au). Mirrors nginx.nix; hermes runs no nginx so it declares its
  # own. Whole-file dotenv (CLOUDFLARE_DNS_API_TOKEN=...) for the environmentFile.
  sops.secrets."acme/cloudflare" = {
    sopsFile = config.homelab.secrets.sopsFile "acme-cloudflare.env";
    format = "dotenv";
    key = "";
    mode = "0400";
  };

  # QEMU guest agent — IP reporting + clean shutdown from Proxmox.
  services.qemuGuest.enable = true;

  # Fresh-host fix: sops-nix materialises the base atuin secret under
  # ~/.local/share/atuin/ during activation and creates the intermediate dirs
  # as ROOT, which then blocks home-manager from creating
  # ~/.local/state/nix/profiles (home-manager-abl030.service fails → the whole
  # switch fails, which would page nightly fleet-update). Existing fleet hosts
  # dodged this because ~/.local was created abl030-owned long before sops ran;
  # on a brand-new host sops wins the race. Pre-own the tree so HM always wins.
  systemd.tmpfiles.rules = [
    "d /home/abl030/.local 0755 abl030 users - -"
    "d /home/abl030/.local/share 0755 abl030 users - -"
  ];

  # Derive the age key from the SSH host key for SOPS decryption (per-host, as on
  # doc2/igpu). Required for the base secrets (nix-netrc/atuin/gotify) and the
  # per-host hermes.env (LLM key + Telegram token).
  sops.age = {
    keyFile = "/var/lib/sops-nix/key.txt";
    sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  };
  system = {
    activationScripts.sopsAgeKey = {
      deps = ["specialfs"];
      text = ''
        if [ ! -s /var/lib/sops-nix/key.txt ]; then
          install -d -m 0700 /var/lib/sops-nix
          ${pkgs.ssh-to-age}/bin/ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key > /var/lib/sops-nix/key.txt
          chmod 600 /var/lib/sops-nix/key.txt
        fi
      '';
    };
    activationScripts.setupSecrets.deps = lib.mkBefore ["sopsAgeKey"];
    stateVersion = "25.05";
  };
}
