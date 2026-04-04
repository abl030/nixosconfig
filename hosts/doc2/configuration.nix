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
    # Bindfs FUSE over NFS Music dir — generates local inotify events
    mounts.bindfsMusic.enable = false; # Migrated to downloader (192.168.1.4)
    # NFS Music export moved to prom (ZFS-direct) — virtiofs lacks
    # FUSE_EXPORT_SUPPORT causing stale NFS file handles for subdirs.
    mounts.nfsMusicServer.enable = false;

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
        musicPath = "/mnt/virtio/music/lidarr";
      };
      inotify-receiver = {
        enable = false;
        musicDir = "/mnt/virtio/music/lidarr";
      };
      slskd = {
        enable = true;
        downloadDir = "/mnt/virtio/music/slskd";
        musicDir = "/mnt/virtio/music/lidarr";
      };
      soularr = {
        enable = true;
        downloadDir = "/mnt/virtio/music/slskd";
        beetsValidation = {
          enable = true;
          stagingDir = "/mnt/virtio/Music/Incoming";
          opusConversion = true;
        };
        pipelineDb = {
          enable = true;
        };
        web = {
          enable = true;
        };
      };
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
      meelo.enable = false;
      domain-monitor.enable = true;
      rtrfm-nowplaying.enable = true;
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
            runAsRoot = true;
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
            runAsRoot = true;
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

  # No tmpfiles rules for virtiofs directories — they already exist on
  # persistent ZFS storage (nvmeprom/containers) shared between VMs.
  # Service modules create their own dirs; re-asserting ownership here
  # risks clobbering permissions on shared storage.

  services = {
    # Immich ML cache on virtiofs
    immich.machine-learning.environment = {
      MACHINE_LEARNING_CACHE_FOLDER = lib.mkForce "/mnt/virtio/immich/ml-cache";
    };

    # QEMU guest agent
    qemuGuest.enable = true;
  };

  # Static IPs — previously set manually, NM would drop them after ~2h
  networking = {
    useDHCP = false;
    interfaces = {
      ens18 = {
        ipv4.addresses = [
          {
            address = "192.168.1.35";
            prefixLength = 24;
          }
        ];
      };
      ens19 = {
        ipv4.addresses = [
          {
            address = "192.168.1.36";
            prefixLength = 24;
          }
        ];
      };
    };
    defaultGateway = {
      address = "192.168.1.1";
      interface = "ens18";
    };
    nameservers = ["192.168.1.1"];
    firewall.enable = true;
  };

  # 16GB swapfile — no swap partition in disko layout, and 16GB RAM is tight
  # for this workload (MusicBrainz Solr+PG alone is ~5GB)
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 16 * 1024; # 16 GiB in MiB
    }
  ];

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
