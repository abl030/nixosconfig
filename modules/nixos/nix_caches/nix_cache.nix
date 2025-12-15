# modules/nixos/nix_caches/nix_cache.nix
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
/*
Unified Nix cache server:
- ACME via Cloudflare DNS-01 (via homelab.nginx core)
- Pull-through mirror of cache.nixos.org (nginx + proxy_store)
- Local binary cache via nix-serve (loopback) fronted by nginx
- Simple time-based pruning for the mirror only

Surface area is intentionally small and flat.
Secrets and ACME defaults are now handled by `homelab.nginx`.
*/
let
  cfg = config.homelab.cache or {};

  haveMirror = cfg.mirrorHost != null && cfg.mirrorHost != "";
  haveLocal = cfg.localHost != null && cfg.localHost != "";
  anyHosts = haveMirror || haveLocal;

  # Mirror prune script: delete files not accessed/modified in N days.
  # Uses atime when available (relatime OK), falls back to mtime if noatime.
  pruneScript = pkgs.writeShellScript "nginx-mirror-prune" ''
    set -euo pipefail
    ROOT=${lib.escapeShellArg cfg.mirrorCacheRoot}
    DAYS=${toString cfg.mirrorRetentionDays}
    [ "$DAYS" -gt 0 ] || exit 0

    mp="$(${pkgs.coreutils}/bin/df -P "$ROOT" | ${pkgs.gawk}/bin/awk 'NR==2{print $6}')"
    opts="$(${pkgs.coreutils}/bin/cat /proc/mounts | ${pkgs.gawk}/bin/awk -v mp="$mp" '$2==mp{print $4}' || true)"
    mode="atime"
    if printf '%s' "$opts" | ${pkgs.gnugrep}/bin/grep -q 'noatime'; then
      mode="mtime"
    fi

    # Only prune the 'store' paths; never touch temp.
    for d in \
      "$ROOT/nix-cache-info/store" \
      "$ROOT/nar/store" \
      "$ROOT/narinfo/store"
    do
      [ -d "$d" ] || continue
      if [ "$mode" = "atime" ]; then
        ${pkgs.findutils}/bin/find "$d" -type f -atime +"$DAYS" -print0 | ${pkgs.findutils}/bin/xargs -0r ${pkgs.coreutils}/bin/rm -f --
      else
        ${pkgs.findutils}/bin/find "$d" -type f -mtime +"$DAYS" -print0 | ${pkgs.findutils}/bin/xargs -0r ${pkgs.coreutils}/bin/rm -f --
      fi
    done
  '';
in {
  options.homelab.cache = {
    enable = lib.mkEnableOption "Enable the unified Nix cache server";

    # Note: ACME Email and Cloudflare Secrets are now configured in homelab.nginx

    mirrorHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public hostname for the pull-through mirror (e.g. nix-mirror.example.org). Omit to disable.";
    };

    mirrorCacheRoot = lib.mkOption {
      type = lib.types.path;
      default = "/var/cache/nginx-nix-mirror";
      description = "Root directory for mirror cache and temp areas.";
    };

    # Allow 0 to disable pruning -> use plain int + assertion below.
    mirrorRetentionDays = lib.mkOption {
      type = lib.types.int;
      default = 45;
      description = "Delete mirror files not accessed (or modified if noatime) in N days. Set 0 to disable.";
    };

    localHost = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Public hostname for the nix-serve front (e.g. nixcache.example.org). Omit to disable.";
    };

    nixServeSecretKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to nix-serve signing secret key (required if localHost is set).";
    };

    # NEW: loopback mapping for same-host requests (only affects this machine).
    loopbackSelf = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When true, map mirrorHost to 127.0.0.1/::1 on this machine only.
        Keeps same-host requests on loopback (clearer graphs, a touch less overhead).
        Other LAN clients still use normal DNS (e.g. 192.168.1.29).
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Enable the core infrastructure module
    {
      homelab.nginx.enable = true;
    }

    # Fail fast on missing secrets/keys and invalid values.
    {
      assertions = [
        {
          assertion = !(haveLocal && (cfg.nixServeSecretKeyFile == null));
          message = "homelab.cache: nixServeSecretKeyFile is required when localHost is set.";
        }
        {
          assertion = cfg.mirrorRetentionDays >= 0;
          message = "homelab.cache: mirrorRetentionDays must be >= 0.";
        }
      ];
    }

    # ACME Certificates request
    # Credentials and provider are handled by homelab.nginx defaults
    (lib.mkIf anyHosts {
      security.acme.certs = lib.mkMerge [
        (lib.mkIf haveMirror {
          "${cfg.mirrorHost}" = {domain = cfg.mirrorHost;};
        })
        (lib.mkIf haveLocal {
          "${cfg.localHost}" = {domain = cfg.localHost;};
        })
      ];
    })

    # NEW: Keep same-host requests on loopback. (Only affects this machine.)
    (lib.mkIf (haveMirror && cfg.loopbackSelf) {
      networking.hosts = {
        "127.0.0.1" = [cfg.mirrorHost];
        "::1" = [cfg.mirrorHost];
      };
    })

    # Single, robust nginx definition; vhosts merged conditionally.
    (lib.mkIf anyHosts {
      services.nginx = {
        virtualHosts = lib.mkMerge [
          (lib.mkIf haveMirror {
            "${cfg.mirrorHost}" = {
              useACMEHost = cfg.mirrorHost;
              forceSSL = true;

              # Narinfo metadata (requested first by Nix); cache it too
              # CHANGED: Serve from disk first; if missing, fetch+store via @fetch_narinfo.
              locations = {
                "~ \.narinfo$".extraConfig = ''
                  root        ${cfg.mirrorCacheRoot}/narinfo/store;
                  try_files   $uri @fetch_narinfo;
                '';

                # nix-cache-info
                # CHANGED: Always fetch from upstream (don't store). Guarantees upstream Priority and avoids divergence.
                "= /nix-cache-info".extraConfig = ''
                  proxy_set_header   Host "cache.nixos.org";
                  proxy_pass         https://cache.nixos.org;
                  proxy_no_cache     1;
                  proxy_cache_bypass 1;
                '';

                # NAR payloads
                # CHANGED: Serve from disk first; if missing, fetch+store via @fetch_nar.
                "~ ^/nar/.+$".extraConfig = ''
                  root        ${cfg.mirrorCacheRoot}/nar/store;
                  try_files   $uri @fetch_nar;
                '';
              };

              # NEW: Named fetch locations that do the one-time upstream proxy + write-through store.
              extraConfig = ''
                # --- Named fetch for .narinfo (cold path only) ---
                location @fetch_narinfo {
                  # FIX: Explicitly set root so proxy_store knows where to write
                  root               ${cfg.mirrorCacheRoot}/narinfo/store;

                  proxy_set_header   Host "cache.nixos.org";
                  proxy_pass         https://cache.nixos.org;
                  proxy_store        on;
                  proxy_store_access user:rw group:rw all:r;
                  proxy_temp_path    ${cfg.mirrorCacheRoot}/narinfo/temp;
                  # Store path derives from "root + $uri" as set in the calling location.
                }

                # --- Named fetch for /nar/... payloads (cold path only) ---
                location @fetch_nar {
                  # FIX: Explicitly set root so proxy_store knows where to write
                  root               ${cfg.mirrorCacheRoot}/nar/store;

                  proxy_set_header   Host "cache.nixos.org";
                  proxy_pass         https://cache.nixos.org;
                  proxy_store        on;
                  proxy_store_access user:rw group:rw all:r;
                  proxy_temp_path    ${cfg.mirrorCacheRoot}/nar/temp;
                  # Store path derives from "root + $uri" as set in the calling location.
                }
              '';
            };
          })

          (lib.mkIf haveLocal {
            "${cfg.localHost}" = {
              useACMEHost = cfg.localHost;
              forceSSL = true;
              # Idiomatic proxy for nix-serve on loopback
              locations."/" = {proxyPass = "http://127.0.0.1:5000";};
            };
          })
        ];
      };
    })

    # nix-serve runs on loopback only; nginx is the public face.
    (lib.mkIf haveLocal {
      services.nix-serve = {
        enable = true;
        bindAddress = "127.0.0.1";
        port = 5000;
        secretKeyFile = cfg.nixServeSecretKeyFile;
      };
    })

    # Mirror-specific FS prep and nginx write permissions (only when mirror enabled).
    (lib.mkIf haveMirror {
      systemd.tmpfiles.rules = [
        "d ${cfg.mirrorCacheRoot}                        0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nix-cache-info         0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nix-cache-info/store   0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nix-cache-info/temp    0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nar                    0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nar/store              0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/nar/temp               0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/narinfo                0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/narinfo/store          0750 nginx nginx -"
        "d ${cfg.mirrorCacheRoot}/narinfo/temp           0750 nginx nginx -"
      ];

      systemd.services.nginx.serviceConfig.ReadWritePaths = [
        cfg.mirrorCacheRoot
        "${cfg.mirrorCacheRoot}/nix-cache-info/temp"
        "${cfg.mirrorCacheRoot}/nar/temp"
        "${cfg.mirrorCacheRoot}/narinfo/temp"
      ];
    })

    # Pruning: mirror only, daily at a fixed time; 0 disables.
    (lib.mkIf (haveMirror && cfg.mirrorRetentionDays > 0) {
      systemd.services.nginx-mirror-prune = {
        description = "Prune pull-through mirror cache";
        serviceConfig = {
          Type = "oneshot";
          User = "nginx";
          Group = "nginx";
          Nice = 10;
          IOSchedulingClass = "best-effort";
          IOSchedulingPriority = 7;
          ReadWritePaths = [cfg.mirrorCacheRoot];
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          # Run the generated script directly (derivation path).
          ExecStart = ["${pruneScript}"];
        };
      };

      systemd.timers.nginx-mirror-prune = {
        description = "Daily mirror pruning";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "03:17"; # keep simple; can be optionized later if needed
          Persistent = true;
          AccuracySec = "10m";
        };
      };
    })
  ]);
}
