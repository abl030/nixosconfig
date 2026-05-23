# Komga magazine library (https://magazines.ablz.au).
# See docs/wiki/services/komga.md for the why/what/gotchas write-up, and
# docs/wiki/services/magazines.md for how this fits into the overall
# magazine archive system (gwm-archiver / komga-sync / EPUB pipeline).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.komga;

  # Path on the host (NFS-mounted) that holds the magazine archive.
  # We bind this read-only into the service namespace so the service can
  # scan and serve files, but cannot mutate the canonical archive (Komga
  # stores its index + thumbnails inside its own stateDir).
  magazinesHost = "/mnt/data/Media/Magazines";
in {
  options.homelab.services.komga = {
    enable = lib.mkEnableOption "Komga magazine/comic/ebook server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/komga";
      description = ''
        Directory where Komga stores its H2 database, thumbnails, search
        index, and application.yml. Recommend a virtiofs path so the VM
        stays disposable.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      # 8085 = cratedigger, 8086 = discogs-api, 8090 = gatus on doc2.
      # Pick a slot that doesn't collide on the current host.
      default = 8089;
      description = "Loopback port Komga listens on. Surfaced via homelab.localProxy.hosts.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "magazines.ablz.au";
      description = "Public FQDN for the reverse proxy.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.komga = {
      enable = true;
      stateDir = cfg.dataDir;
      settings = {
        server = {
          # Bind to loopback only — LAN access flows through nginx via
          # homelab.localProxy, never direct.
          address = "127.0.0.1";
          port = cfg.port;
          # Tomcat ships forwarded-headers support so Komga sees the real
          # client IP / scheme behind the nginx proxy.
          forward-headers-strategy = "framework";
        };
        # Use stateDir directly (the upstream module's `config-dir` lives
        # here too — the assertion in upstream komga.nix enforces this).
        komga.config-dir = cfg.dataDir;
      };
    };

    # Add komga to the `users` group so the NFS bind below (gid=users
    # files on tower) is readable.
    users.users.komga.extraGroups = ["users"];

    systemd.services.komga = {
      # Komga is a Java/JVM service that loads its library list from the
      # H2 DB at startup. If the NFS bind isn't ready, the scan job fails
      # but the service stays up. We mark the dep as Wants= (not Requires=)
      # so a temporary mount blip doesn't cascade-stop the whole service —
      # homelab.nfsWatchdog below handles recovery.
      after = ["mnt-data.mount"];
      wants = ["mnt-data.mount"];

      serviceConfig = {
        # Narrow /mnt visibility: only the magazines tree + stateDir.
        # Per `.claude/rules/nixos-service-modules.md` (Sandbox patterns):
        # BindReadOnlyPaths / BindPaths are fail-loud (status=226/NAMESPACE)
        # if the source is unavailable, so a stale NFS gets caught
        # immediately instead of presenting an empty library hours later.
        TemporaryFileSystem = "/mnt";
        BindReadOnlyPaths = [magazinesHost];
        # stateDir lives under /mnt/virtio (virtiofs), so it'd also be
        # masked by the TemporaryFileSystem above without this bind.
        # rw — Komga writes its sqlite DB, thumbnails, search index here.
        BindPaths = [cfg.dataDir];
      };
    };

    homelab = {
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          port = cfg.port;
          # EPUB / PDF downloads can be big; lift the upload cap. Komga
          # itself doesn't accept uploads from clients in our flow (the
          # archiver scripts write to the bind dir directly), but the
          # download direction needs the same nginx tuning we use for
          # immich and audiobookshelf.
          maxBodySize = "0";
          # Reader uses WebSockets for live progress sync between
          # multiple sessions.
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          # /actuator/health is Komga's Spring-Boot health endpoint —
          # returns 200 OK with the JVM, DB, and disk space status.
          name = "Komga (LAN)";
          url = "https://${cfg.fqdn}/actuator/health";
        }
      ];

      # Stateful service but no deep probe yet. Justification:
      #   - The canonical archive is /mnt/data/Media/Magazines/ and is
      #     maintained by gwm-archiver / wvj-archive — Komga is read-only
      #     against it. There is no user-driven write path inside Komga
      #     that we'd lose silently the way Immich lost asset_edit_audit.
      #   - The H2 DB lives in stateDir on virtiofs; corruption would
      #     surface as /actuator/health returning DOWN, which the shallow
      #     Kuma monitor catches.
      #   - Library scan failures show up in journald — see errorPatterns.
      # Revisit if we add an OPDS-write or upload path through Komga,
      # or if we move from H2 to PostgreSQL (Komga supports both).

      # Komga is a brand-new deployment as of this commit. The fingerprint
      # methodology from #253 (read 30 days of Loki history to pick real
      # failure strings) can't apply yet. Start with the well-known JVM
      # and Spring-Boot failure shapes and tighten after the first month
      # of real journal data lands in Loki.
      monitoring.errorPatterns = [
        {
          name = "Komga JVM out-of-memory";
          unit = "komga.service";
          pattern = "OutOfMemoryError|java\\.lang\\.OutOfMemoryError";
          severity = "critical";
          summary = "Komga JVM crashed with OOM — service likely down or degraded";
          # Single-shot: the JVM doesn't keep logging after OOM.
          threshold = 0;
        }
        {
          name = "Komga library scan failed";
          unit = "komga.service";
          # Komga logs `Library scan for library X failed` or
          # `Error scanning ...` on per-library scan errors.
          pattern = "(?i)(library scan for .* failed|error scanning|book analysis failed)";
          severity = "warning";
          summary = "Komga library scan threw an error — new issues may not be indexed";
        }
        {
          name = "Komga bind-mount failure";
          unit = "komga.service";
          # Mirrors the NFS-backed BindReadOnlyPaths fail-loud failure
          # mode documented in the Sandbox patterns rule.
          pattern = "Failed at step NAMESPACE";
          severity = "critical";
          summary = "Komga refused to start — magazine library bind failed (likely NFS stale)";
          threshold = 0;
        }
      ];

      # NFS watchdog — restart Komga if the bind-source mount goes stale.
      # The 5min-interval timer + service restart is the canonical pattern
      # used by paperless, immich, etc.
      nfsWatchdog.komga.path = magazinesHost;
    };
  };
}
