{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];

  # Match template 9003 bootloader (seabios + GRUB)
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

    # NFS for Immich media — same writable mount as doc1
    mounts.nfsLocal.enable = true;

    nixCaches = {
      enable = true;
      profile = "internal";
    };

    # Unattended appliance — auto-update and reboot
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
      updateDates = "04:00";
      gcDates = "04:30";
    };

    # No containers, no podman, no compose — native NixOS services only
    # No CI, no cache server, no github runner — that stays on doc1
    # No syncthing — this is a headless appliance
    syncthing.enable = false;

    # Services
    services = {
      immich.enable = true;
      gotify = {
        enable = true;
        dataDir = "/mnt/virtio/gotify";
      };
      tautulli = {
        enable = true;
        dataDir = "/mnt/virtio/tautulli";
      };
      audiobookshelf = {
        enable = true;
        dataDir = "/mnt/virtio/audiobookshelf";
      };
    };

    pve.enable = true;
  };

  # Virtiofs mount — ALL service state lives here
  # This is the whole point: storage decoupled from compute.
  # VM is disposable, data survives on ZFS on the Proxmox host.
  fileSystems."/mnt/virtio" = {
    device = "containers";
    fsType = "virtiofs";
    options = ["rw" "relatime"];
  };

  systemd.tmpfiles.rules = [
    "d /mnt/virtio 0755 root root - -"
    "d /mnt/virtio/immich 0755 root root - -"
    "d /mnt/virtio/immich/postgres 0700 postgres postgres - -"
    "d /mnt/virtio/immich/ml-cache 0755 immich immich - -"
    # Gotify state on virtiofs — static user owns data directly
    "d /mnt/virtio/gotify 0700 gotify gotify - -"
    # Tautulli state on virtiofs — upstream uses static plexpy user
    "d /mnt/virtio/tautulli 0700 plexpy nogroup - -"
    # Audiobookshelf state on virtiofs — static user owns data directly
    "d /mnt/virtio/audiobookshelf 0700 audiobookshelf audiobookshelf - -"
  ];

  services = {
    # PostgreSQL data on virtiofs
    postgresql.dataDir = lib.mkForce "/mnt/virtio/immich/postgres";

    # Immich ML cache on virtiofs
    immich.machine-learning.environment = {
      MACHINE_LEARNING_CACHE_FOLDER = lib.mkForce "/mnt/virtio/immich/ml-cache";
    };

    # QEMU guest agent
    qemuGuest.enable = true;
  };

  networking.firewall.enable = true;

  # Derive age key from SSH host key for SOPS secret decryption
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
