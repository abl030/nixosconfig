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

  boot = {
    # Match template 9003 bootloader (seabios + GRUB)
    loader = {
      systemd-boot.enable = false;
      efi.canTouchEfiVariables = false;
      grub = {
        enable = true;
        devices = ["nodev"];
      };
    };
    supportedFilesystems = ["zfs"];
    zfs.extraPools = ["pfsensebackup"];
  };

  homelab = {
    ssh = {
      enable = true;
      secure = true;
    };
    tailscale.enable = true;

    # LGTM observability stack — migrated from igpu per #208.
    # Also receive syslog (pfSense, tower) on 1514/udp+tcp.
    loki = {
      syslogReceiver = {
        enable = true;
        sources = [
          {
            ip = "192.168.1.1";
            label = "pfsense";
          }
        ];
      };
      pfsenseExporter.enable = true;
      ntopngExporter = {
        enable = true;
        # Must stay in sync with pfSense's MV_VPN_IPS alias — consumed by the
        # custom ntopng client-traffic dashboard to tag VPN-routed LAN hosts.
        # The pfsense subagent is contractually obliged to update this list
        # (and flag a rebuild) whenever MV_VPN_IPS changes. See
        # .claude/agents/pfsense.md front-matter and
        # docs/wiki/services/lgtm-stack.md §"VPN-routed IP sync contract".
        vpnClientIPs = [
          "192.168.1.4" # downloader2 (Unraid KVM — torrent/PiHole)
          "192.168.1.15"
          "192.168.1.17" # tower nzbget (ipvlan on br0)
          "192.168.1.18" # tower nzbhydra2 (ipvlan on br0)
          "192.168.1.24"
          "192.168.1.34"
          "192.168.1.36" # doc2-vpn (2nd NIC — slskd)
          "192.168.1.118"
        ];
      };
    };

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
      # LGTM observability stack (migrated from igpu per #208).
      # Data on virtiofs so the VM is disposable.
      loki = {
        enable = true;
        dataDir = "/mnt/virtio/loki";
      };
      # Grafana alerting → Gotify (#201). Default rule: alert on
      # unexpected reboots of prom (the canonical case from 2026-02-22).
      alerting.enable = true;
      # pfSense ZFS backup chain — doc2 hosts the receiver natively on its
      # own local ZFS pool (pfsensebackup, backed by a zvol passthrough from
      # prom's nvmeprom). syncoid pulls directly from pfSense; sanoid prunes;
      # kopia-mum walks the local mount tree.
      # Full architecture: docs/wiki/infrastructure/pfsense-backup.md
      syncoidPfsense.enable = true;
      # Watchdog over the syncoid status file in /mnt/backup/pfsense/.
      # Logs "PFSENSE-BACKUP FAIL" on stale/failed/missing-canary;
      # routes through homelab.monitoring.errorPatterns → Gotify.
      pfsenseBackupWatchdog.enable = true;
      # claude-p summary bridge in front of Gotify. When enabled,
      # alerting.nix automatically points Grafana's webhook at the
      # bridge (127.0.0.1:9876) instead of Gotify, and the bridge
      # forwards a summarised push.
      alertBridge.enable = true;
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
      beancount.enable = true;
      slskd = {
        enable = true;
        downloadDir = "/mnt/virtio/music/slskd";
        musicDir = "/mnt/virtio/Music/Beets";
      };
      cratedigger = {
        enable = true;
        downloadDir = "/mnt/virtio/music/slskd";
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
      discogs = {
        enable = true;
        mirrorDir = "/mnt/mirrors/discogs";
      };
      meelo.enable = false;
      overseerr = {
        enable = true;
        dataDir = "/mnt/virtio/overseerr";
      };
      # Jellystat + watchstate live on doc2; jellyfin itself stays on igpu.
      # All three sub-services share the homelab.services.jellyfin module —
      # see modules/nixos/services/jellyfin.nix header.
      jellyfin = {
        jellystat.enable = true;
        watchstate.enable = true;
      };
      domain-monitor.enable = true;
      forgejo.enable = true;
      rtrfm-nowplaying.enable = true;
      gwm-archiver.enable = true;
      komga = {
        enable = true;
        dataDir = "/mnt/virtio/komga";
      };
      komga-sync.enable = true;
      kopia = {
        enable = true;
        dataDir = "/mnt/virtio/kopia";
        instances = {
          photos = {
            port = 51515;
            configDir = "/mnt/virtio/kopia/photos";
            sources = [
              "/mnt/data/Life/Photos/library"
              # pfSense backup is intentionally NOT in kopia-photos: those
              # snapshots will live in a dedicated Wasabi bucket better
              # suited to small high-churn appliance backups. Existing
              # 298-byte snapshots in this repo will be `kopia snapshot
              # delete`d and age out under the 90-day Object Lock window.
              # See docs/wiki/infrastructure/pfsense-backup.md.
            ];
            proxyHost = "kopiaphotos.ablz.au";
            # Match container identity so existing snapshot policies/schedules work
            overrideHostname = "kopia";
            overrideUsername = "root";
            runAsRoot = true;
          };
          mum = {
            port = 51516;
            configDir = "/mnt/virtio/kopia/mum";
            # Three deliberately-narrow subdirs — NOT all of /mnt/data
            # (which would include video media we don't ship offsite).
            # The 2026-02-26 migration silently dropped these from the
            # daemon schedule for 12 weeks (#254); the reconciler in
            # the new module + this declarative list (#255) keeps them
            # synced going forward.
            sources = [
              "/mnt/data/Life"
              "/mnt/data/Media/Books"
              "/mnt/data/Media/Music"
              # pfSense ZFS backup, read-only NFS mount from prom. (Replaces
              # the earlier virtiofs share at /mnt/pfsense-backup — virtiofs
              # does not cross ZFS-submount boundaries reliably, so the
              # 12 child datasets that hold the actual 1.83 GB of data were
              # invisible to kopia and snapshots came in at 298 bytes.)
              # Full architecture: docs/wiki/infrastructure/pfsense-backup.md
              "/mnt/backup/pfsense"
            ];
            repositoryMounts = ["/mnt/mum"];
            proxyHost = "kopiamum.ablz.au";
            verifyPercent = 2;
            overrideHostname = "kopia";
            overrideUsername = "root";
            runAsRoot = true;
          };
        };
      };
    };

    # Per-service tailscale shares — each gets its own dedicated tailscale node
    # (pinhole access: only that service is shared, not the whole VM).
    # Kuma → alert-bridge route (#256). The bridge re-shapes Kuma's raw
    # DOWN body through claude opus and pushes a summarised message to
    # Gotify, same as it already does for Grafana alerts. Existing
    # manually-configured Gotify direct webhook (if any) stays available
    # in Kuma as a non-default fallback that a human can promote in the
    # UI if the bridge itself goes down.
    monitoring.notifications = [
      {
        name = "alert-bridge";
        type = "webhook";
        isDefault = true;
        webhookURL = "http://127.0.0.1:9876/alert";
        webhookContentType = "application/json";
      }
    ];

    # See modules/nixos/services/tailscale-share.nix.
    tailscaleShare.overseerr = {
      enable = true;
      fqdn = "overseer.ablz.au";
      upstream = "http://host.docker.internal:5055";
      # Keep sidecar state outside the seerr-owned app data root. A compromised
      # Overseerr process must not be able to rename or replace TS/Caddy state.
      dataDir = "/mnt/virtio/tailscale-share/overseerr";
      hostname = "overseer";
      firewallPorts = [5055];
      monitorName = "Overseerr (Tailnet)";
      monitorPath = "/api/v1/status";
    };
  };

  # Cratedigger — host-specific app tuning. Everything else lives in the
  # homelab wrapper at modules/nixos/services/cratedigger.nix, which configures
  # the upstream module from the cratedigger flake (inputs.cratedigger-src).
  services.cratedigger.beetsValidation.verifiedLosslessTarget = "opus 128";

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

  # pfSense ZFS backup — native ZFS on this host.
  #
  # 2026-05-26 cutover: prom previously hosted the replica and exposed it
  # to doc2 via virtiofs and then NFS. Both layers failed to traverse the
  # 12 child ZFS datasets reliably (virtiofsd's --announce-submounts only
  # propagated one child; Linux kernel NFS server can't crossmnt ZFS-on-Linux
  # child datasets with valid file handles even with per-child explicit fsids,
  # see docs.kernel.org/filesystems/nfs/reexport.html). The native answer is
  # to put ZFS on doc2 directly — pool `pfsensebackup` lives on virtio1, a
  # zvol passthrough from prom's nvmeprom. syncoid pulls directly here; the
  # 12 child datasets are real ZFS submounts (kernel ZFS, native traversal).
  #
  # Pool bootstrap (one-off):
  #   sudo zpool create -o ashift=12 -O compression=lz4 -O atime=off \
  #     -O mountpoint=/mnt/backup/pfsense pfsensebackup /dev/disk/by-id/...
  # Then auto-imports on subsequent boots via the cachefile (NixOS default).
  #
  # Full architecture: docs/wiki/infrastructure/pfsense-backup.md
  # 8-char hex required for ZFS. Stable across rebuilds.
  networking.hostId = "deadbe14";

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

  # 30GB swapfile — RAM bumped to 30GB on 2026-05-13 after cratedigger +
  # kopia thrashing pushed the previous 16GB swap to 11GB used. Matching swap
  # to RAM gives headroom for parallel import_preview workers without paging
  # death.
  swapDevices = [
    {
      device = "/var/lib/swapfile";
      size = 30 * 1024; # 30 GiB in MiB
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
