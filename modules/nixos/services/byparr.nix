# homelab.services.byparr — Byparr, the maintained FlareSolverr successor (a
# Camoufox-based Cloudflare-challenge solver). Prowlarr uses it as a
# FlareSolverr-type indexer proxy to reach Cloudflare-gated indexers (1337x,
# EZTV). Stateless HTTP solver on :8191, fronted LAN-wide by nginx/localProxy.
#
# Why Byparr, not FlareSolverr: FlareSolverr is non-functional / effectively
# abandoned in 2026 (per TRaSH Guides). Byparr is the drop-in — same :8191 + the
# FlareSolverr /v1 API, so in Prowlarr it's still added as the "FlareSolverr"
# proxy type. Rules: docs/wiki/nixos-service-modules.md.
{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.byparr;
in {
  options.homelab.services.byparr = {
    enable = lib.mkEnableOption "Byparr Cloudflare solver (FlareSolverr replacement) for Prowlarr";

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "byparr.ablz.au";
      description = "LAN FQDN (localProxy) that Prowlarr points its FlareSolverr proxy at.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8191;
      description = "Byparr HTTP port (FlareSolverr-compatible; bound to loopback, fronted by nginx).";
    };

    uidBase = lib.mkOption {
      type = lib.types.int;
      default = 300000;
      description = "Host UID/GID base for the userns remap (container 0..65535 -> host base..base+65535). Must not overlap other remapped containers (netboot=100000, watchstate=200000); the image's baked UID 1000 lands on base+1000, never 1000/abl030.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-byparr.service";
          image = "ghcr.io/thephaseless/byparr:latest";
        }
      ];

      # LAN-only FQDN. Prowlarr (on servarr) reaches it by NAME, not IP (DNS-first):
      # set its FlareSolverr proxy Host to https://byparr.ablz.au.
      localProxy.hosts = [
        {
          host = cfg.fqdn;
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "Byparr (Cloudflare solver)";
          url = "https://${cfg.fqdn}/";
        }
      ];

      # Stateless solver — no DB / write path, so the shallow HTTP monitor above is
      # the right coverage (no deepProbe; a deep "solve a test challenge" probe would
      # hammer external sites every cycle). errorPatterns left empty pending ~30d of
      # Loki history (new service); a dead browser also surfaces as the Cloudflare-
      # gated indexers failing in Prowlarr's own indexer health.
      monitoring.errorPatterns = [];
    };

    virtualisation.oci-containers.containers.byparr = {
      image = "ghcr.io/thephaseless/byparr:latest";
      autoStart = true;
      pull = "newer";
      # Loopback-only publish; reached LAN-wide via nginx/localProxy (hostBindAudit).
      ports = ["127.0.0.1:${toString cfg.port}:8191"];
      environment = {
        TZ = "Australia/Perth";
        PORT = "8191";
      };
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          # Byparr bakes `USER 1000` (= host abl030) AND a UID-1000-owned uv cache
          # (/var/cache/uv) its entrypoint must write at startup, so a plain --user
          # override crashes it ("Failed to initialize cache ... Permission denied").
          # Class-2 fix (module rules): userns-remap the whole container — it keeps
          # its internal UID 1000 (owns /var/cache/uv, HOME=/tmp) but that maps to a
          # high host UID (uidBase+1000), never abl030. Stateless: no volumes, no :U.
          "--uidmap=0:${toString cfg.uidBase}:65536"
          "--gidmap=0:${toString cfg.uidBase}:65536"
          # Reap the headless browser's child processes (compose sets `init: true`).
          "--init"
          # Headless browser needs more than the 64M default /dev/shm or it crashes.
          "--shm-size=1g"
        ];
    };
  };
}
