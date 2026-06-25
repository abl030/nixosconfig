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
    # forgejo#2: LOCKED by default (homelab.fleetDeploy.role defaults to
    # "locked") — accepts the doc1 bastion's forced-command deploy trigger
    # (polkit-scoped to start ONLY nixos-upgrade.service) AND keeps the narrow
    # read-only/deploy-hygiene NOPASSWD allowlist, with no passwordless sudo.
    # Nothing to set here; the default IS the doc2 model.
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
        # Disabled 2026-06-25: ntopng was turned off on pfSense, so the exporter
        # had nothing to scrape and was crash-looping (status=2/INVALIDARGUMENT,
        # ~140 restarts, spamming "ntopng Exporter DOWN"). Re-enable when ntopng
        # is running on pfSense again.
        enable = false;
        # Must stay in sync with pfSense's MV_VPN_IPS alias — consumed by the
        # custom ntopng client-traffic dashboard to tag VPN-routed LAN hosts.
        # The pfsense subagent is contractually obliged to update this list
        # (and flag a rebuild) whenever MV_VPN_IPS changes. See
        # .claude/agents/pfsense.md front-matter and
        # docs/wiki/services/lgtm-stack.md §"VPN-routed IP sync contract".
        vpnClientIPs = [
          # 192.168.1.4 was the decommissioned downloader2; servarr now holds .4 and
          # egresses via WAN (NOT MV_VPN_IPS) — removed 2026-06-23 (servarr .4 cutover).
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
      # Byparr — Cloudflare-challenge solver Prowlarr uses for its gated indexers
      # (1337x/EZTV). Stateless OCI container, reached LAN-wide at byparr.ablz.au.
      byparr.enable = true;
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
      # Authorize the hermes-deploy operator key to trigger fleet-update HERE
      # (doc2 only — the cratedigger host). Forced-command + tailnet/LAN-pinned;
      # see modules/nixos/services/hermes-operator-deploy.nix.
      hermesOperatorDeploy.enable = true;
      rtrfm-nowplaying.enable = true;
      gwm-archiver = {
        enable = true;
        # After a new download, WOL epi + trigger its marker-convert unit so
        # the EPUB lands without waiting for the weekly RTC-wake safety net.
        triggerConvert.enable = true;
      };
      komga = {
        enable = true;
        dataDir = "/mnt/virtio/komga";
      };
      komga-sync.enable = true;
      # Mail archival — replaces Win10 MailStore VM (VMID 102).
      # Two accounts: personal Gmail and work O365 (cullenwines.com.au).
      # Bootstrap procedure (per-account refresh tokens, sops env files):
      #   docs/wiki/services/mailarchive.md
      # Both secrets/hosts/doc2/mailarchive-{work,gmail}.env exist (seeded
      # 2026-06-18), so the fetchers are live.
      mailarchive = {
        enable = true;
        accounts = {
          work = {
            provider = "o365";
            remoteUser = "andy@cullenwines.com.au";
          };
          gmail = {
            provider = "gmail";
            remoteUser = "abl030@gmail.com";
          };
        };
      };

      # Hybrid (keyword + semantic) search over the mailarchive Maildir.
      # notmuch keyword index + nomic/sqlite-vec embeddings; index on virtiofs
      # (NOT the NFS Maildir); read-only MCP for the doc1 agents only
      # (forced-command SSH). See docs/wiki/services/mailsearch.md.
      mailsearch = {
        enable = true;
        tuiUser = "abl030";
        # Embeddings moved to the igpu iGPU (Vulkan) — CPU embedding of the large
        # backlog was the wall (~7-8s/email). Index + MCP stay here and call igpu
        # over the LAN; the shared vectors.db carries the work over.
        embed = {
          enable = false;
          url = "http://192.168.1.33:18181/v1/embeddings";
          readyUrl = "http://192.168.1.33:18181/health";
        };
      };

      kopia = {
        enable = true;
        dataDir = "/mnt/virtio/kopia";
        instances = {
          photos = {
            port = 51515;
            configDir = "/mnt/virtio/kopia/photos";
            sources = [
              "/mnt/data/Life/Photos/library"
              # /mnt/data/Life joins the photos repo as a second source so it
              # dedupes against the photo blobs already here — the 314 GiB
              # library is never re-uploaded and incurs no fresh 90-day lock.
              # The regenerable/duplicate Photos subdirs and the high-churn
              # Unraid USB backup are dropped via sourceExcludes below;
              # Photos/backups (immich DB dumps) rides along into Wasabi.
              # See docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md.
              "/mnt/data/Life"
              # pfSense backup is intentionally NOT in kopia-photos: those
              # snapshots will live in a dedicated Wasabi bucket better
              # suited to small high-churn appliance backups. Existing
              # 298-byte snapshots in this repo will be `kopia snapshot
              # delete`d and age out under the 90-day Object Lock window.
              # See docs/wiki/infrastructure/pfsense-backup.md.
            ];
            # Anchored to the /mnt/data/Life source root. library is its own
            # source above; thumbs/encoded-video/upload are immich-regenerable;
            # UnraidUSB is a 4 GiB monthly full-rewrite that's re-creatable.
            # Photos/backups (immich DB) and Photos/profile are NOT excluded.
            sourceExcludes = {
              "/mnt/data/Life" = [
                "/Photos/library"
                "/Photos/thumbs"
                "/Photos/encoded-video"
                "/Photos/upload"
                "/Tech/Backups/UnraidUSB"
              ];
            };
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
              # Curated beets music library — its own ZFS dataset on prom
              # (nvmeprom/containers/Music), a virtiofs submount under /mnt/virtio.
              # Synology-only (re-downloadable; not worth per-GB Wasabi). Walks
              # ~100k files — relies on the #267 virtiofsd fd fix to avoid ENFILE.
              # See docs/brainstorms/2026-06-07-backup-coverage-widening-requirements.md.
              "/mnt/virtio/Music"
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
  # prom-side virtiofsd fd-exhaustion fix (--inode-file-handles=prefer via a
  # dpkg-divert wrapper) — large tree walks here (e.g. kopia) would otherwise
  # drive virtiofsd to its 1M fd ceiling and ENFILE every service on this mount.
  # See docs/wiki/infrastructure/virtiofsd-fd-exhaustion.md (#267).
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
  # Then auto-imports on subsequent boots via boot.zfs.extraPools above.
  #
  # Full architecture: docs/wiki/infrastructure/pfsense-backup.md
  # 8-char hex required for ZFS. Stable across rebuilds.
  networking.hostId = "deadbe14";

  # Boot-race fix (B'): pfsensebackup lives on `vdb`, a zvol passed through from
  # prom's nvmeprom. That virtio disk attaches LATE and can *flicker* during early
  # boot — observed 2026-06-05: device visible to `zpool import` at T+46s, then
  # MISSING again for ~20s while the stock import ran, which then gave up
  # ("Pool ... in state MISSING ... no such pool available"). Because the stock
  # unit is a oneshot with no retry (Type=oneshot forbids Restart=), the pool
  # never imported, /mnt/backup/pfsense stayed empty, and the watchdog paged
  # hourly until a manual `zpool import` (the nightly auto-update reboot retriggers
  # this every time).
  #
  # The original guard (2026-05-29) only waited for the pool to become *visible*
  # then handed off to the stock ~20s import, which lost the flicker race. This
  # version imports the pool *itself*, retrying every 3s for up to ~3min so it
  # rides straight through the late-attach + flicker; the stock ExecStart then
  # sees the pool already imported and is a no-op. Runs once at boot, no
  # forever-timer. A genuinely absent device still fails the unit after the cap
  # (real signal — the pool isn't boot-critical, / is on vda), and the hourly
  # pfSense-backup watchdog remains the backstop. TimeoutStartSec is raised to
  # cover the retry window (default 90s would kill it mid-loop).
  # See docs/wiki/infrastructure/pfsense-backup.md.
  systemd.services.zfs-import-pfsensebackup.serviceConfig = {
    ExecStartPre = "${pkgs.bash}/bin/bash -c 'for _ in $(seq 1 60); do ${pkgs.zfs}/bin/zpool list pfsensebackup >/dev/null 2>&1 && exit 0; ${pkgs.zfs}/bin/zpool import pfsensebackup 2>/dev/null && exit 0; sleep 3; done; exit 0'";
    TimeoutStartSec = "210s";
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

  # Indexer recovery (2026-06-25): mailsearch-index is a long bootstrap oneshot
  # (hours). `restartIfChanged = false` means a deploy never touches a running
  # instance, so if it wedges on a pathological message the bastion otherwise has
  # no way to clear it short of the 6h start-timeout. Scoped NOPASSWD to restart
  # EXACTLY this one unit (`--no-block` returns immediately; the indexer runs as a
  # dedicated low-priv user, tiny blast radius). Pairs with the per-message guard
  # in nix/pkgs/mailsearch-indexer.nix. doc2-only since mailsearch lives only here.
  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = [
        {
          command = "/run/current-system/sw/bin/systemctl restart --no-block mailsearch-index.service";
          options = ["NOPASSWD"];
        }
      ];
    }
    # Full passwordless sudo for abl030 on doc2 (2026-06-25, user-requested).
    # Deliberate relaxation of the locked-role posture: the role default is
    # `wheelNeedsPassword = true`, which forced every bastion-driven op into the
    # narrow read-only allowlist above and made routine incident response (e.g.
    # `podman network reload`, restarting arbitrary units) impossible from doc1.
    # This is the sanctioned per-host override documented in CLAUDE.md
    # ("LOCKED-HOST sudo is role-driven, NOT guarded by a flake check" — same
    # `mkAfter` ALL/NOPASSWD pattern already live on hermes). mkAfter renders last
    # so it wins (sudoers = last match), subsuming the scoped rule above.
    #
    # Blast radius: anyone reaching doc2 via the doc1 fleet key now gets root
    # without the password gate. To revert: delete this rule and `fleet-deploy doc2`.
    {
      users = ["abl030"];
      commands = [
        {
          command = "ALL";
          options = ["NOPASSWD"];
        }
      ];
    }
  ];
}
