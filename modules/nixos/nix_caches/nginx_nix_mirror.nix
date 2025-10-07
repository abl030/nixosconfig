# modules/nixos/nix_caches/nginx_nix_mirror.nix
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}: let
  cfg = config.homelab.services.nginxNixMirror or {};
  secretName = cfg.cloudflare.secretName;

  # --- Retention policy implementation ---
  # We keep proxy_store (immutable mirror semantics for NARs) and add a housekeeping
  # service + timer. It prunes:
  #   1) Files not accessed in N days (default 45d), with a safety guard to never
  #      delete very fresh files in the watermark phase (prevents thrash after rollouts).
  #   2) If free space drops below a low-watermark (default 20%), it deletes the
  #      least-recently-used files (by atime; falls back to mtime if noatime) until
  #      the high-watermark (default 30%) is restored.
  #
  # Why this is safe:
  # - Nix /nar/... objects are immutable; "staleness" isn't a risk, only disk growth.
  # - Your fleet updates synchronously from one flake; old paths stop being requested.
  #
  # Notes:
  # - Uses atime when available (default relatime is fine). If the cache FS is mounted
  #   with `noatime`, we fall back to mtime heuristics.
  # - Only prunes the `store/` dirs; never touches `temp/` (in-flight downloads).
  pruneScript = pkgs.writeShellScript "nginx-nix-mirror-prune" ''
    set -euo pipefail

    CACHE_ROOT=${lib.escapeShellArg cfg.cacheRoot}
    INACTIVE_DAYS=${toString cfg.retention.inactiveDays}
    PROTECT_HOURS=${toString cfg.retention.protectFreshHours}
    MIN_FREE=${toString cfg.retention.minFreePercent}
    TARGET_FREE=${toString cfg.retention.targetFreePercent}

    # Directories we are allowed to prune (only 'store/', never 'temp/').
    PRUNE_DIRS=(
      "$CACHE_ROOT/nar/store"
      "$CACHE_ROOT/nix-cache-info/store"
      "$CACHE_ROOT/narinfo/store"   # include narinfo metadata cache
    )

    # Convert hours → minutes for 'find -mmin'.
    PROTECT_MINS=$(( PROTECT_HOURS * 60 ))

    # Determine the mountpoint for CACHE_ROOT and whether noatime is set.
    mp="$(df -P "$CACHE_ROOT" | awk 'NR==2{print $6}')"
    opts="$(awk -v mp="$mp" '$2==mp{print $4}' /proc/mounts || true)"
    mode="atime"
    if printf '%s' "$opts" | grep -q 'noatime'; then
      mode="mtime"
    fi

    percent_free() {
      # Returns integer % free space on the filesystem that holds CACHE_ROOT.
      df -P "$CACHE_ROOT" | awk 'NR==2 {gsub(/%/,"",$5); print 100-$5}'
    }

    # Phase 1: prune files that haven't been *recently used*.
    # (mtime fallback doesn't need an extra "fresh guard": INACTIVE_DAYS >> PROTECT_HOURS)
    prune_inactive() {
      for d in "''${PRUNE_DIRS[@]}"; do
        [ -d "$d" ] || continue
        if [ "$mode" = "atime" ]; then
          # atime: files not accessed in N days
          find "$d" -type f -atime +"$INACTIVE_DAYS" -print0 | xargs -0r rm -f --
        else
          # mtime fallback: files not modified in N days
          find "$d" -type f -mtime +"$INACTIVE_DAYS" -print0 | xargs -0r rm -f --
        fi
      done
    }

    # Phase 2: if free space is below MIN_FREE, delete oldest files until TARGET_FREE is reached.
    # We keep a "fresh file" guard *here* to avoid deleting very recent downloads under pressure.
    prune_to_watermark() {
      cur_free="$(percent_free)"
      if [ "$cur_free" -ge "$MIN_FREE" ]; then
        return 0
      fi

      # Build an ordered (oldest-first) list across store dirs.
      tmp="$(mktemp)"
      for d in "''${PRUNE_DIRS[@]}"; do
        [ -d "$d" ] || continue
        if [ "$mode" = "atime" ]; then
          find "$d" -type f -printf '%A@ %p\n' >> "$tmp"
        else
          find "$d" -type f -printf '%T@ %p\n' >> "$tmp"
        fi
      done
      sort -n -o "$tmp" "$tmp" || true

      while read -r ts path; do
        # Fresh-file guard in watermark phase: skip if modified within PROTECT_MINS.
        if [ "$PROTECT_MINS" -gt 0 ]; then
          if [ "$(find "$path" -mmin +"$PROTECT_MINS" -printf 1 -quit | wc -c)" -eq 0 ]; then
            continue
          fi
        fi
        rm -f -- "$path" || true
        cur_free="$(percent_free)"
        if [ "$cur_free" -ge "$TARGET_FREE" ]; then
          break
        fi
      done < "$tmp"
      rm -f "$tmp"
    }

    prune_inactive
    prune_to_watermark
  '';
in {
  # Keep sops-nix self-contained here (so the module owns decryption).
  imports = [inputs.sops-nix.nixosModules.sops];

  options.homelab.services.nginxNixMirror = {
    enable = lib.mkEnableOption "Transparent pull-through mirror of cache.nixos.org via nginx";

    hostName = lib.mkOption {
      type = lib.types.str;
      description = "Public hostname (e.g., nix-mirror.example.org).";
    };

    cacheRoot = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/nginx-nix-mirror";
      description = "Root directory for cached artifacts and temp areas.";
    };

    # SIMPLIFIED EMAIL: default provided here; no file sourcing.
    acmeEmail = lib.mkOption {
      type = lib.types.str;
      default = "acme@ablz.au";
      description = "ACME contact email (override here if you don't want the default).";
    };

    # SOPS/age config kept here so the module owns decryption.
    sopsAgeKeyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = ["/etc/ssh/ssh_host_ed25519_key"];
      description = "age private key paths for decryption (default: host SSH key).";
    };

    cloudflare = {
      sopsFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Encrypted dotenv with LEGO Cloudflare vars (e.g. CLOUDFLARE_DNS_API_TOKEN=...).
          This file remains encrypted in git; sops-nix decrypts it at runtime.
        '';
        example = ./secrets/acme-cloudflare.env;
      };

      secretName = lib.mkOption {
        type = lib.types.str;
        default = "acme/cloudflare.env";
        description = "sops-nix secret name under config.sops.secrets.";
      };

      dnsPropagationCheck = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Check DNS propagation before validation.";
      };
    };

    # --- Retention policy knobs (sensible defaults) ---
    retention = {
      enable = lib.mkEnableOption "Enable housekeeping for proxy_store cache (time-based + watermark)";

      inactiveDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 45;
        description = "Delete files not accessed (or modified if noatime) in N days.";
      };

      protectFreshHours = lib.mkOption {
        type = lib.types.ints.positive;
        default = 24;
        description = "Never delete files newer than this many hours (avoid thrash after deploys).";
      };

      minFreePercent = lib.mkOption {
        type = lib.types.ints.positive;
        default = 20;
        description = "If FS free% drops below this low-watermark, start LRU pruning.";
      };

      targetFreePercent = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "After low-watermark triggers, prune until this free% is reached.";
      };

      # Daily schedule in systemd OnCalendar format.
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "03:17";
        description = "When to run pruning (systemd OnCalendar).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Decrypt Cloudflare dotenv at runtime; never enters /nix/store.
    sops.age.sshKeyPaths = cfg.sopsAgeKeyPaths;
    sops.secrets.${secretName} = {
      sopsFile = cfg.cloudflare.sopsFile;
      format = "dotenv"; # dotenv/plaintext, not YAML
      owner = "acme";
      group = "acme";
      mode = "0400";
      restartUnits = [
        "nginx.service"
        "acme-${cfg.hostName}.service"
      ];
    };

    # ACME DNS-01 via Cloudflare
    security.acme = {
      acceptTerms = true;
      # FIXED: set defaults.email correctly (previous nesting caused an invalid path).
      # mkDefault lets a global or another module override if needed.
      defaults.email = lib.mkDefault cfg.acmeEmail;
      certs."${cfg.hostName}" = {
        domain = cfg.hostName;
        dnsProvider = "cloudflare";
        credentialsFile = config.sops.secrets.${secretName}.path;
        dnsPropagationCheck = cfg.cloudflare.dnsPropagationCheck;
      };
    };

    # nginx needs to read ACME certs
    users.users.nginx.extraGroups = ["acme"];

    # nginx vhost: pull-through only for exact nix endpoints
    services.nginx = {
      # mkDefault to compose cleanly with other modules that may tweak nginx.
      enable = lib.mkDefault true;
      recommendedProxySettings = lib.mkDefault true;
      recommendedTlsSettings = lib.mkDefault true;

      virtualHosts."${cfg.hostName}" = {
        useACMEHost = cfg.hostName;
        forceSSL = true;

        # Narinfo metadata (Nix asks for this first; cache it to avoid falling through)
        locations."~ \\.narinfo$".extraConfig = ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
          proxy_temp_path    ${cfg.cacheRoot}/narinfo/temp;
          root               ${cfg.cacheRoot}/narinfo/store;
          proxy_set_header   Host "cache.nixos.org";
          proxy_pass         https://cache.nixos.org;
        '';

        locations."~ ^/nix-cache-info$".extraConfig = ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
          proxy_temp_path    ${cfg.cacheRoot}/nix-cache-info/temp;
          root               ${cfg.cacheRoot}/nix-cache-info/store;
          proxy_set_header   Host "cache.nixos.org";
          proxy_pass         https://cache.nixos.org;
        '';

        locations."~ ^/nar/.+$".extraConfig = ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
          proxy_temp_path    ${cfg.cacheRoot}/nar/temp;
          root               ${cfg.cacheRoot}/nar/store;
          proxy_set_header   Host "cache.nixos.org";
          proxy_pass         https://cache.nixos.org;
        '';
      };
    };

    # cache directories (writeable by nginx) + unit hardening escape hatches
    systemd.tmpfiles.rules = [
      "d ${cfg.cacheRoot}                       0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info        0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info/store  0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nix-cache-info/temp   0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar                   0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar/store             0750 nginx nginx -"
      "d ${cfg.cacheRoot}/nar/temp              0750 nginx nginx -"
      "d ${cfg.cacheRoot}/narinfo               0750 nginx nginx -" # allow narinfo cache
      "d ${cfg.cacheRoot}/narinfo/store         0750 nginx nginx -" # allow narinfo cache
      "d ${cfg.cacheRoot}/narinfo/temp          0750 nginx nginx -" # allow narinfo temp
    ];

    systemd.services.nginx.serviceConfig.ReadWritePaths = [
      cfg.cacheRoot
      "${cfg.cacheRoot}/nix-cache-info/temp"
      "${cfg.cacheRoot}/nar/temp"
      "${cfg.cacheRoot}/narinfo/temp" # nginx may write temp narinfo files
    ];

    networking.firewall.allowedTCPPorts = [80 443];

    # --- Retention policy: service + timer ---
    # Runs as 'nginx', low priority, daily at cfg.retention.schedule.
    systemd.services.nginx-nix-mirror-prune = lib.mkIf cfg.retention.enable {
      description = "Prune nginx proxy_store cache for ${cfg.hostName} (inactive + watermark)";
      serviceConfig = {
        Type = "oneshot";
        User = "nginx";
        Group = "nginx";
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;

        # Read/write only where we need it.
        ReadWritePaths = [cfg.cacheRoot];

        # SECURITY: keep system dirs read-only (previously discussed).
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      # Provide the tools we rely on (findutils, coreutils, awk, grep).
      path = [pkgs.findutils pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.util-linux];

      script = pruneScript;
    };

    systemd.timers.nginx-nix-mirror-prune = lib.mkIf cfg.retention.enable {
      description = "Daily nginx proxy_store cache pruning";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.retention.schedule;
        Persistent = true; # Run missed jobs at boot.
        AccuracySec = "10m";
      };
    };
  };
}
