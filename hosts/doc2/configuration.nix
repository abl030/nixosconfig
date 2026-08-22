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
    ./slskd-microvm.nix
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
    # A kernel panic must not leave this service appliance frozen indefinitely.
    # The independent doc1 watchdog still captures the console before resetting
    # failures that do not reach the kernel's own reboot path.
    kernelParams = ["panic=30"];
  };

  # Kernel printk streaming now comes from homelab.crashCapture, which generalises
  # this host's 2026-07-22 sender to the whole fleet — doc1 had no sender of its
  # own, which is why its 2026-07-24 panic frames were lost (#51).
  #
  # Collector is prom, not doc1. On 2026-07-24 doc1 panicked and doc2 wedged in
  # the same window, so pointing doc2's kernel log at doc1 loses exactly the
  # records worth having. prom is the hypervisor and its journal was pristine
  # throughout. Note doc1 also hosts the doc2Recovery watchdog, so a doc1 outage
  # takes out doc2's capture path twice over; the prom-side collector removes one
  # of those dependencies.
  # See docs/wiki/infrastructure/doc2-kernel-panic-2026-07-22.md and
  # docs/wiki/infrastructure/fleet-crash-capture.md.
  homelab.crashCapture = {
    netconsole = {
      collectorAddress = "192.168.1.12";
      collectorMac = "9c:6b:00:95:f5:51";
      # Dedicated prom receiver. UDP/6666 belongs to the issue-51 lab receiver;
      # sharing it hid the 2026-08-03 panic in vm951-netconsole.log.
      collectorPort = 6667;
    };

    # The 2026-08-03 double fault destroyed the initiating stack before the
    # terminal panic reached netconsole. Preserve the dead kernel so crash(8)
    # can inspect the first fault rather than only its recursive aftermath.
    kdump = {
      enable = true;
      reservedMemory = "512M";
    };
  };

  # Include tasks, memory, timers, locks, ftrace and all-CPU backtraces in any
  # panic that still has enough kernel state to print them. kdump remains the
  # primary path when the text trace itself is damaged.
  boot.kernel.sysctl."kernel.panic_print" = 63;

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
          # 192.168.1.4 = servarr (*arr stack). Re-added to MV_VPN_IPS 2026-06-28 so
          # its Prowlarr indexer / Cloudflare-solver egress exits via AirVPN (USA preferred) and
          # not the home WAN IP — which 1337x.to banned. servarr→qbt .20.2:8080 is
          # carved out by a pfSense floating bypass rule so the qbt WebUI stays direct.
          # (.4 was the decommissioned downloader2 before; removed 2026-06-23 at the
          # servarr .4 cutover, restored now.)
          "192.168.1.4" # servarr (*arr) — VPN egress, 1337x.to ban dodge (2026-06-28)
          "192.168.1.15"
          "192.168.1.17" # tower nzbget (ipvlan on br0)
          "192.168.1.18" # tower nzbhydra2 (ipvlan on br0)
          "192.168.1.24"
          "192.168.1.34"
          "192.168.1.36" # doc2-vpn (2nd NIC — yt-dlp rescue egress)
          "192.168.1.118"
        ];
      };
    };

    # NFS for Immich media — same writable mount as doc1
    mounts.nfsLocal.enable = true;

    # Dedicated single-disk magazine archive share (escapes the /mnt/data
    # shfs-union ESTALE). Static + rw: doc2 runs gwm-archiver (write),
    # komga/komga-sync (read) and kopia (read for backup) against it.
    mounts.magazines.enable = true;

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
      alerting = {
        enable = true;
        vpnGatewayAlert.enable = true;
      };
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
      alertBridge = {
        enable = true;
        # Forward enriched alerts to Hermes on doc1 for automated RCA.
        # The webhook triggers the alert-rca skill which investigates
        # read-only and optionally opens a signed PR to nixosconfig.
        rcaWebhookUrl = "http://192.168.1.29:8644/webhooks/alert-rca";
        rcaWebhookSecret = "alert-bridge-rca";
      };
      byparr.enable = false;
      immich = {
        enable = true;
        dataDir = "/mnt/virtio/immich";
      };
      gotify = {
        enable = true;
        dataDir = "/mnt/virtio/gotify";
      };
      ntfy.enable = true;
      tautulli = {
        enable = true;
        dataDir = "/mnt/virtio/tautulli";
      };
      audiobookshelf = {
        enable = true;
        dataDir = "/mnt/virtio/audiobookshelf";
      };
      # Companion to ABS: chapter-splits books into Yoto-legal tracks and
      # serves them as a browsable tailnet file drop, because the ABS app
      # downloads into private app storage a file-picker can't reach and a
      # single-file .m4b busts Yoto's 60min/100MB per-track cap anyway.
      yotoShare.enable = true;
      atuin = {
        enable = true;
        dataDir = "/mnt/virtio/atuin";
      };
      beancount.enable = true;
      beets = {
        enable = true;
        manageSharedStorage = true;
      };
      cratedigger = {
        enable = true;
        downloadDir = "/mnt/virtio/music/slskd";
        metadataGate.remoteDiscogsImportHost = "192.168.1.44";
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
        # 8080 (the default) collides with UniFi's device-inform port now that
        # the controller lives on doc2 — move netboot's asset HTTP server off it.
        assetsPort = 8070;
      };
      youtarr = {
        enable = true;
        dataDir = "/mnt/virtio/youtarr";
      };
      musicbrainz = {
        enable = false;
        dataDir = "/mnt/virtio/musicbrainz";
        mirrorDir = "/mnt/mirrors/musicbrainz";
      };
      discogs = {
        enable = false;
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
      # UniFi Network controller — migrated off the caddy LXC to a standard
      # localProxy/nginx service module. State on portable, kopia-backed
      # virtiofs (was stranded on the LXC's unbacked-up root); UI surfaced via
      # localProxy (https upstream), which also fixes the CSRF/Host login bug.
      unifiController = {
        enable = true;
        dataDir = "/mnt/virtio/unifi";
      };
      # Static MSN history viewer — sandboxed static server behind localProxy.
      msnHistoryViewer.enable = true;
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
              # Wine-magazine archive (PDFs + EPUBs + JSON sidecars, ~2.6 GB)
              # on its dedicated single-disk share. Expensive to regenerate
              # (Marker ML conversion + sidecars; pre-2017 issues are 0-byte /
              # unrecoverable server-side), so it earns an offsite copy.
              "/mnt/magazines"
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
              # Wine-magazine archive on its dedicated single-disk share.
              # Synology offsite copy alongside the photos-repo (Wasabi) one.
              "/mnt/magazines"
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
              # VM backup archives from prom — age-encrypted weekly tarballs of
              # nvmeprom/containers written by containers-backup.service on doc1.
              # Tower exports VMBackups to doc2 read-only (HAOS gets the only rw
              # entry); we ship the encrypted .tar.gz.age files offsite to mum's
              # Synology. Requires: tower VMBackups NFS export scoped to
              # 192.168.1.35/36 ro — see the fileSystems entry below for the
              # full rule and why nothing else needs NFS on that share.
              "/mnt/backup/vm-backups/containers"
              # Home Assistant's nightly automatic backups (02:00, keep 7).
              # HAOS writes them itself over a Supervisor NFS backup mount
              # (192.168.1.20 is the only rw entry in tower's VMBackups export);
              # kopia-mum is what actually gets them off the LAN.
              # Full architecture: docs/wiki/services/home-assistant-auto-update.md
              "/mnt/backup/vm-backups/homeassistant"
            ];
            # Calibration encodes are regenerable scratch data. A 693 GiB run
            # monopolized Kopia's single scheduled upload queue for >13h on
            # 2026-07-27, preventing the other six daily sources from running.
            sourceExcludes = {
              "/mnt/virtio/Music" = ["/calibration-tmp"];
            };
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

    # Cullen Wines' PUBLIC website (a client site we don't host). Uptime only —
    # cert/domain expiry is covered separately in domain-monitor.nix. This
    # pre-existed as a hand-made Kuma monitor with maxretries=2, so one slow
    # response on the external site tripped a DOWN→UP flap constantly, and it
    # still carried the legacy direct-Gotify notification (double-paging).
    # Declaring it here adopts that monitor (matched by URL) so the reconciler
    # (a) resets it to the alert-bridge notification ONLY — no more double-ping —
    # and (b) widens maxretries to 10 (~10 min of continuous failure before it
    # pages) so brief upstream blips no longer flap. 2026-07-07.
    monitoring.monitors = [
      {
        name = "Cullen Wines";
        url = "https://cullenwines.com.au";
        maxretries = 10;
      }
      # Home Assistant is not a NixOS flake host (HAOS on prom VM 116), so it
      # had no monitor at all until 2026-08-21. It now auto-updates Core, OS,
      # add-ons and HACS unattended, and this is the only out-of-band signal
      # that an unattended update failed to come back up — the in-band one
      # (the "report versions after restart" automation) cannot fire if HA is
      # the thing that is down. /manifest.json is served by HA itself with no
      # auth, so a 200 proves HA's HTTP stack is up, not just the caddy edge.
      # See docs/wiki/services/home-assistant-auto-update.md.
      {
        name = "Home Assistant";
        url = "https://home.ablz.au/manifest.json";
        maxretries = 3;
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
  services.cratedigger.beets.validation.verifiedLosslessTarget = "opus 128";

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

  # VM backup archives — read-only NFS mount of tower's VMBackups share.
  # Kopia-mum walks /mnt/backup/vm-backups/{containers,homeassistant} to ship the
  # age-encrypted .tar.gz.age files (written by containers-backup.service on doc1)
  # and HA's nightly backups to mum's Synology.
  # Automount (lazy): only attached when kopia accesses it; nofail so a down tower
  # doesn't block boot or activation.
  #
  # Tower side (2026-08-21): the VMBackups export was `*(rw)` — world-writable to
  # anything that could reach tower's NFS — despite this comment previously claiming
  # it was scoped. It is now genuinely scoped in /boot/config/shares/VMBackups.cfg:
  #   192.168.1.35 ro, 192.168.1.36 ro  (doc2's two NICs, this mount)
  #   192.168.1.20 rw                   (HAOS Supervisor backup mount)
  # Nothing else reaches that share over NFS — doc1's containers-backup and
  # prom-rpool-backup use SSH, and the PBS VM uses virtiofs passthrough.
  # See docs/wiki/services/home-assistant-auto-update.md.
  fileSystems."/mnt/backup/vm-backups" = {
    device = "192.168.1.2:/mnt/user/VMBackups";
    fsType = "nfs";
    options = [
      "x-systemd.automount"
      "noauto"
      "nofail"
      "_netdev"
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
      "x-systemd.mount-timeout=30s"
      "x-systemd.idle-timeout=300"
      "noatime"
      "nfsvers=4.2"
      "ro"
    ];
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
    # Keep the pre-existing VPN-routed source address for Cratedigger's yt-dlp
    # rescue worker. slskd no longer uses ens19; it is jailed on SLSKD_DMZ.
    iproute2.enable = true;
    localCommands = ''
      for i in $(seq 1 30); do
        main_ip=$(ip -4 addr show ens18 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
        vpn_ip=$(ip -4 addr show ens19 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
        [ -n "$main_ip" ] && [ -n "$vpn_ip" ] && break
        sleep 1
      done
      ip route replace 192.168.1.0/24 dev ens18 src "$main_ip" table main
      ip route replace 192.168.1.0/24 dev ens19 src 192.168.1.36 table 100
      ip route replace default via 192.168.1.1 dev ens19 table 100
      ip rule del from 192.168.1.36 table 100 2>/dev/null || true
      ip rule add from 192.168.1.36 table 100 priority 101
    '';
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

  # Keep the headless operator account's user manager alive between short-lived
  # SSH sessions. Otherwise logind can stop user@1000.service while
  # switch-to-configuration is reloading its units, leaving a stale
  # /run/user/1000/bus socket and making an otherwise successful deployment exit 4.
  users.users.abl030.linger = true;

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
