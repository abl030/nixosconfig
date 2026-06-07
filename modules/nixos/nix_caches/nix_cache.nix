# modules/nixos/nix_caches/nix_cache.nix
{
  lib,
  pkgs,
  config,
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

  # ---- Pull-through failover origins ----------------------------------------
  # Ordered upstreams the mirror falls through on connection error / timeout /
  # 5xx. cache.nixos.org (Fastly) is primary; the configured fallbacks (Chinese
  # university mirrors) cover the case where our ISP can't route to Fastly's
  # 151.101.0.0/16 prefix — see docs/wiki/infrastructure/nix-mirror-failover.md
  # (2026-06-07 incident). Every origin serves cache.nixos.org-signed content
  # and nix verifies the signature client-side, so an untrusted-but-verified
  # fallback cannot inject bad paths.
  fetchOrigins =
    [
      {
        host = "cache.nixos.org";
        prefix = "";
      }
    ]
    ++ cfg.mirrorFallbacks;
  nOrigins = builtins.length fetchOrigins;

  # Generate the @fetch_<name>_<i> named-location failover chain for one store
  # area. proxy_pass carries $uri so nginx resolves the host at request time via
  # `resolver` (no stale pinned IPs — the second-order failure on 2026-06-07);
  # ipv6=off keeps it on A records. proxy_store writes to root+$uri, i.e. the
  # canonical on-disk layout regardless of which origin actually served it.
  mkFetchChain = {
    name,
    rootDir,
    tempDir,
    store ? true,
    noCache ? false,
  }:
    lib.concatStrings (lib.imap0 (idx: origin: let
        isLast = idx == nOrigins - 1;
      in ''
        location @fetch_${name}_${toString idx} {
          internal;
          root               ${rootDir};
          proxy_set_header   Host "${origin.host}";
          proxy_ssl_name     ${origin.host};
          proxy_ssl_server_name on;
          proxy_pass         https://${origin.host}${origin.prefix}$request_uri;
        ${lib.optionalString store ''
          proxy_store        on;
          proxy_store_access user:rw group:rw all:r;
        ''}${lib.optionalString noCache ''
          proxy_no_cache     1;
          proxy_cache_bypass 1;
        ''}  proxy_temp_path    ${tempDir};
          # Fail fast to the next origin when an upstream is unreachable: cap the
          # number of (resolver-returned) IPs tried so we don't burn
          # connect_timeout x N-IPs before failover (cache.nixos.org has 4 A
          # records — that was the 20s stall in early testing). read_timeout is
          # generous for large NARs over the slow China fallback link.
          proxy_connect_timeout ${
          if idx == 0
          then "3s"
          else "10s"
        };
          proxy_read_timeout 300s;
          proxy_next_upstream_tries 2;
          proxy_intercept_errors on;
        ${lib.optionalString (!isLast) "  error_page 502 503 504 = @fetch_${name}_${toString (idx + 1)};"}
        }
      '')
      fetchOrigins);
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

    mirrorFallbacks = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          host = lib.mkOption {
            type = lib.types.str;
            description = "Fallback mirror hostname (e.g. mirror.sjtu.edu.cn).";
          };
          prefix = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Path prefix on the fallback before the cache root (e.g. /nix-channels/store).";
          };
        };
      });
      default = [
        {
          host = "mirror.sjtu.edu.cn";
          prefix = "/nix-channels/store";
        }
        {
          host = "mirror.tuna.tsinghua.edu.cn";
          prefix = "/nix-channels/store";
        }
      ];
      description = ''
        Ordered fallback origins the pull-through mirror uses when
        cache.nixos.org is unreachable (connection error / timeout / 5xx).
        They serve cache.nixos.org-signed content and nix verifies signatures
        client-side, so an untrusted-but-verified fallback cannot inject bad
        paths. Channel mirrors lag tip-of-unstable by a few days, so very fresh
        paths may 404 and build from source. See
        docs/wiki/infrastructure/nix-mirror-failover.md.
      '';
    };

    mirrorResolver = lib.mkOption {
      type = lib.types.str;
      default = "100.100.100.100";
      description = ''
        DNS resolver nginx uses to re-resolve mirror upstreams at request time.
        Default is Tailscale MagicDNS. ipv6=off is applied at the use site.
      '';
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

              # Serve from disk first; on a cold miss, fall through the failover
              # chain (cache.nixos.org -> fallbacks) which fetches + stores.
              locations = {
                "~ \.narinfo$".extraConfig = ''
                  root        ${cfg.mirrorCacheRoot}/narinfo/store;
                  try_files   $uri @fetch_narinfo_0;
                '';

                # nix-cache-info: always fetched fresh (never stored), through the
                # same failover chain so the mirror stays usable when Fastly is
                # unreachable. try_files jumps unconditionally into the chain.
                "= /nix-cache-info".extraConfig = ''
                  root        ${cfg.mirrorCacheRoot};
                  try_files   /nonexistent @fetch_nixcacheinfo_0;
                '';

                "~ ^/nar/.+$".extraConfig = ''
                  root        ${cfg.mirrorCacheRoot}/nar/store;
                  try_files   $uri @fetch_nar_0;
                '';
              };

              # Re-resolve upstreams per request (A records only — IPv6 is off on
              # this host and AAAA-only resolution is what broke 2026-06-07), then
              # the generated failover chains.
              extraConfig = ''
                resolver ${cfg.mirrorResolver} valid=300s ipv6=off;

                ${mkFetchChain {
                  name = "narinfo";
                  rootDir = "${cfg.mirrorCacheRoot}/narinfo/store";
                  tempDir = "${cfg.mirrorCacheRoot}/narinfo/temp";
                }}
                ${mkFetchChain {
                  name = "nar";
                  rootDir = "${cfg.mirrorCacheRoot}/nar/store";
                  tempDir = "${cfg.mirrorCacheRoot}/nar/temp";
                }}
                ${mkFetchChain {
                  name = "nixcacheinfo";
                  rootDir = cfg.mirrorCacheRoot;
                  tempDir = "${cfg.mirrorCacheRoot}/nix-cache-info/temp";
                  store = false;
                  noCache = true;
                }}
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
      systemd.tmpfiles.rules = lib.mkOrder 2000 [
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
