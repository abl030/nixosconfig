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

    # Rootful podman for OCI containers, native NixOS services for the rest
    # No CI, no cache server, no github runner — that stays on doc1
    # No syncthing — this is a headless appliance
    syncthing.enable = false;

    # Services
    services = {
      immich = {
        enable = true;
        dataDir = "/mnt/virtio/immich";
      };
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
      atuin = {
        enable = true;
        dataDir = "/mnt/virtio/atuin";
      };
      lidarr = {
        enable = true;
        dataDir = "/mnt/virtio/lidarr";
      };
      slskd.enable = true;
      soularr.enable = true;
      paperless = {
        enable = true;
        dataDir = "/mnt/virtio/paperless";
      };
      mealie = {
        enable = true;
        dataDir = "/mnt/virtio/mealie";
      };
      stirlingpdf.enable = true;
      webdav.enable = true;
      smokeping.enable = true;
      uptime-kuma = {
        enable = true;
        dataDir = "/mnt/virtio/uptime-kuma";
      };
      jdownloader2 = {
        enable = true;
        dataDir = "/mnt/virtio/jdownloader2";
      };
      netboot = {
        enable = true;
        dataDir = "/mnt/virtio/netboot";
      };
      youtarr = {
        enable = true;
        dataDir = "/mnt/virtio/youtarr";
      };
      musicbrainz = {
        enable = true;
        dataDir = "/mnt/virtio/musicbrainz";
        mirrorDir = "/mnt/mirrors/musicbrainz";
      };
      kopia = {
        enable = true;
        dataDir = "/mnt/virtio/kopia";
        instances = {
          photos = {
            port = 51515;
            configDir = "/mnt/virtio/kopia/photos";
            sources = ["/mnt/data/Life/Photos"];
            proxyHost = "kopiaphotos.ablz.au";
            # Match container identity so existing snapshot policies/schedules work
            overrideHostname = "kopia";
            overrideUsername = "root";
          };
          mum = {
            port = 51516;
            configDir = "/mnt/virtio/kopia/mum";
            sources = ["/mnt/data"];
            readWriteSources = ["/mnt/mum"];
            proxyHost = "kopiamum.ablz.au";
            verifyPercent = 2;
            overrideHostname = "kopia";
            overrideUsername = "root";
          };
        };
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

  # Mirrors virtiofs mount — re-downloadable data (MusicBrainz, etc.), NOT backed up
  fileSystems."/mnt/mirrors" = {
    device = "mirrors";
    fsType = "virtiofs";
    options = ["rw" "relatime"];
  };

  systemd.tmpfiles.rules = [
    "d /mnt/virtio 0755 root root - -"
    "d /mnt/mirrors 0755 root root - -"
    "d /mnt/virtio/immich 0755 root root - -"
    "d /mnt/virtio/immich/postgres 0700 postgres postgres - -"
    "d /mnt/virtio/immich/ml-cache 0755 immich immich - -"
    # Gotify state on virtiofs — static user owns data directly
    "d /mnt/virtio/gotify 0700 gotify gotify - -"
    # Tautulli state on virtiofs — upstream uses static plexpy user
    "d /mnt/virtio/tautulli 0700 plexpy nogroup - -"
    # Audiobookshelf state on virtiofs — static user owns data directly
    "d /mnt/virtio/audiobookshelf 0700 audiobookshelf audiobookshelf - -"
    # Atuin PG container — parent dir for bind mount; initdb creates contents
    "d /mnt/virtio/atuin 0755 root root - -"
    "d /mnt/virtio/atuin/postgres 0700 postgres postgres - -"
    # Lidarr music management — config/database on virtiofs
    "d /mnt/virtio/lidarr 0700 lidarr lidarr - -"
    # Paperless document management — app state + postgres on virtiofs
    "d /mnt/virtio/paperless 0750 paperless paperless - -"
    "d /mnt/virtio/paperless/postgres 0700 postgres postgres - -"
    # Mealie recipe manager — static user for predictable file ownership on virtiofs
    "d /mnt/virtio/mealie 0750 mealie mealie - -"
    "d /mnt/virtio/mealie/postgres 0700 postgres postgres - -"
    # Uptime Kuma monitoring — SQLite DB on virtiofs
    "d /mnt/virtio/uptime-kuma 0700 uptime-kuma uptime-kuma - -"
    "d /mnt/virtio/uptime-kuma/upload 0700 uptime-kuma uptime-kuma - -"
    # JDownloader2 — OCI container config on virtiofs
    "d /mnt/virtio/jdownloader2 0755 root root - -"
    # netboot.xyz — PXE boot server config and assets on virtiofs
    "d /mnt/virtio/netboot 0755 root root - -"
    # Youtarr — app state + MariaDB on virtiofs
    "d /mnt/virtio/youtarr 0755 root root - -"
    # Kopia backup server — repository configs on virtiofs
    # Symlinks match container mount paths so existing snapshot policies work
    "L /photos - - - - /mnt/data/Life/Photos"
    "L /data - - - - /mnt/data"
    "L /mum - - - - /mnt/mum"
    "d /mnt/virtio/kopia 0750 kopia kopia - -"
    "d /mnt/virtio/kopia/photos 0750 kopia kopia - -"
    "d /mnt/virtio/kopia/mum 0750 kopia kopia - -"
  ];

  services = {
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
