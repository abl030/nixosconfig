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

    runtimeUid = lib.mkOption {
      type = lib.types.int;
      default = 2015;
      description = "Dedicated host UID the container runs as (must NOT be 1000/abl030).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Byparr's image bakes `USER 1000` — under rootful podman that is host UID 1000
    # (= abl030, passwordless-sudo admin), the forbidden case. It's a plain
    # `python main.py` entrypoint (no s6/PUID drop), so it honours an explicit
    # --user override (class-1 per the module rules): pin it to a dedicated UID.
    # HOME=/tmp (writable) + /app/.venv (read+exec); the solver keeps no host state.
    users.users.byparr = {
      isSystemUser = true;
      group = "users";
      uid = cfg.runtimeUid;
      description = "Byparr Cloudflare solver (OCI container runtime UID)";
    };

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
          # Not host UID 1000: image bakes USER 1000; pin runtime to the dedicated UID.
          "--user=${toString cfg.runtimeUid}:100"
          # Reap the headless browser's child processes (compose sets `init: true`).
          "--init"
          # Headless browser needs more than the 64M default /dev/shm or it crashes.
          "--shm-size=1g"
        ];
    };
  };
}
