# Cratedigger — homelab wrapper around the upstream module.
# =====================================================
#
# The actual NixOS module lives in the cratedigger repo at nix/module.nix and is
# consumed via inputs.cratedigger-src.nixosModules.default. This wrapper supplies
# the homelab-specific bits the upstream module deliberately doesn't know
# about:
#
#   - sops-nix per-key secret extraction (slskd API key, notifier creds)
#   - the nspawn PostgreSQL container backing the pipeline DB
#   - the localProxy entry that puts the web UI behind music.ablz.au
#   - systemd ordering against container@cratedigger-db.service
#
# Tuning notes that used to live in the giant downstream module now live in
# the upstream module's option docs (or in the cratedigger README for quality
# rank tuning). Anything past the option-set below is purely homelab plumbing.
#
# Network topology:
#   doc2 has two NICs on 192.168.1.0/24:
#     ens18 = 192.168.1.35 (main, DHCP) — cratedigger, metadata APIs, NFS, everything else
#     ens19 = 192.168.1.36 (VPN, static) — slskd Soulseek traffic only
#   See slskd.nix for the policy routing.
#
# Debugging:
#   journalctl -u cratedigger -f              — watch a run in real time
#   sudo systemctl start cratedigger          — trigger a run now
#   sudo cat /var/lib/cratedigger/config.ini  — verify rendered config
#   curl -s localhost:5030/api/v0/searches -H 'X-API-Key: <key>' | jq
#                                         — check slskd search queue
#
# Operations: docs/wiki/services/cratedigger.md documents the metadata gate,
# hold reasons, and least-privilege boundary.
{
  config,
  lib,
  pkgs,
  inputs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.cratedigger;
  operatorUser = hostConfig.user or "abl030";
  patchedCratediggerSrc = pkgs.applyPatches {
    name = "cratedigger-src-group-permissions";
    src = inputs.cratedigger-src;
    patches = [./cratedigger-group-permissions.patch];
  };

  metadataGateStateDir = "/run/cratedigger-metadata-gate";
  metadataGateHoldDir = "${metadataGateStateDir}/holds";
  metadataGateGuardedUnits = [
    "cratedigger.timer"
    "cratedigger.service"
    "cratedigger-web.service"
    "cratedigger-importer.service"
    "cratedigger-import-preview-worker.service"
  ];
  metadataGateResumeUnits = [
    "cratedigger.timer"
    "cratedigger-web.service"
    "cratedigger-importer.service"
    "cratedigger-import-preview-worker.service"
  ];
  metadataGateDependencyUnits = [
    "musicbrainz.service"
    "discogs-api.service"
  ];
  musicbrainzMaintenanceUnits = [
    "musicbrainz-retire-compose.service"
    "musicbrainz-build-images.service"
    "musicbrainz-token.service"
    "podman-musicbrainz-valkey-1.service"
    "podman-musicbrainz-mq-1.service"
    "podman-musicbrainz-search-1.service"
    "podman-musicbrainz-indexer-1.service"
    "podman-musicbrainz-musicbrainz-1.service"
    "podman-musicbrainz-lrclib-1.service"
    "musicbrainz.service"
  ];
  shellArray = values: lib.concatMapStringsSep " " lib.escapeShellArg values;
  metadataGateTool = pkgs.writeShellApplication {
    name = "cratedigger-metadata-gate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.jq
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      set -euo pipefail

      state_dir='${metadataGateStateDir}'
      hold_dir='${metadataGateHoldDir}'
      lock_file="$state_dir/lock"
      musicbrainz_api='${cfg.metadataGate.musicbrainzApiBase}'
      discogs_api='${cfg.metadataGate.discogsApiBase}'
      discogs_release_id='${toString cfg.metadataGate.discogsProbeReleaseId}'
      probe_timeout='${toString cfg.metadataGate.probeTimeoutSeconds}'
      guarded_units=(${shellArray metadataGateGuardedUnits})
      resume_units=(${shellArray metadataGateResumeUnits})

      mkdir_state() {
        install -d -m 0755 -o root -g root "$state_dir" "$hold_dir"
      }

      lock_state() {
        mkdir_state
        exec 9>"$lock_file"
        flock 9
      }

      valid_reason() {
        case "$1" in
          manual|dependency|discogs-import|musicbrainz-maintenance) ;;
          *)
            echo "invalid hold reason: $1" >&2
            exit 64
            ;;
        esac
      }

      has_holds() {
        mkdir_state
        shopt -s nullglob
        local hold
        for hold in "$hold_dir"/*; do
          return 0
        done
        return 1
      }

      list_holds() {
        mkdir_state
        shopt -s nullglob
        local hold
        for hold in "$hold_dir"/*; do
          basename "$hold"
        done
      }

      has_reason() {
        mkdir_state
        [ -f "$hold_dir/$1" ]
      }

      probe_musicbrainz() {
        local response
        response="$(
          curl -fsS \
            --connect-timeout 3 \
            --max-time "$probe_timeout" \
            -H 'User-Agent: cratedigger-metadata-gate/1.0 (local homelab)' \
            --get \
            --data-urlencode 'query=artist:Radiohead AND release:"OK Computer"' \
            --data 'fmt=json' \
            --data 'limit=1' \
            "$musicbrainz_api/release"
        )" || return 1
        jq -e '((.count // 0) | tonumber) > 0 or ((.releases // []) | length > 0)' >/dev/null <<<"$response" || return 1
      }

      probe_discogs() {
        local health release
        health="$(curl -fsS --connect-timeout 3 --max-time "$probe_timeout" "$discogs_api/health")" || return 1
        jq -e '.status == "ok"' >/dev/null <<<"$health" || return 1

        release="$(curl -fsS --connect-timeout 3 --max-time "$probe_timeout" "$discogs_api/api/releases/$discogs_release_id")" || return 1
        jq -e --argjson id "$discogs_release_id" '(.id // empty) == $id' >/dev/null <<<"$release" || return 1
      }

      check() {
        probe_musicbrainz || return 1
        probe_discogs || return 1
      }

      stop_guarded_units() {
        systemctl stop "''${guarded_units[@]}" || true
      }

      hold_reason() {
        local reason="$1"
        valid_reason "$reason"
        lock_state
        {
          echo "reason=$reason"
          echo "timestamp=$(date --iso-8601=seconds)"
        } >"$hold_dir/$reason"
        stop_guarded_units
      }

      release_reason() {
        local reason="$1"
        valid_reason "$reason"
        lock_state
        rm -f "$hold_dir/$reason"
      }

      start_check() {
        if has_holds; then
          echo "cratedigger metadata gate is held: $(list_holds | tr '\n' ' ')" >&2
          return 1
        fi

        if check; then
          return 0
        fi

        echo "cratedigger metadata dependency check failed; entering dependency hold" >&2
        hold_reason dependency
        return 1
      }

      resume_if_clear() {
        if ! check; then
          echo "metadata probes still failing; cratedigger remains held" >&2
          return 1
        fi

        lock_state
        rm -f "$hold_dir/dependency"
        if has_holds; then
          echo "cratedigger metadata gate still has active holds: $(list_holds | tr '\n' ' ')" >&2
          return 1
        fi

        systemctl --no-block start "''${resume_units[@]}"
      }

      status() {
        if has_holds; then
          echo "holds:"
          while IFS= read -r hold; do
            echo "  $hold"
          done < <(list_holds)
        else
          echo "holds: none"
        fi

        if check; then
          echo "probes: ok"
        else
          echo "probes: failed"
          return 1
        fi
      }

      watchdog() {
        if check; then
          if has_reason dependency; then
            resume_if_clear || true
          fi
        else
          hold_reason dependency
        fi
      }

      usage() {
        cat >&2 <<'EOF'
      usage: cratedigger-metadata-gate check|start-check|hold REASON|release REASON|resume-if-clear|status|watchdog
      reasons: manual, dependency, discogs-import, musicbrainz-maintenance
      EOF
      }

      command="''${1:-}"
      case "$command" in
        check)
          check
          ;;
        start-check)
          start_check
          ;;
        hold)
          shift
          [ "$#" -eq 1 ] || { usage; exit 64; }
          hold_reason "$1"
          ;;
        release)
          shift
          [ "$#" -eq 1 ] || { usage; exit 64; }
          release_reason "$1"
          ;;
        resume-if-clear)
          resume_if_clear
          ;;
        status)
          status
          ;;
        watchdog)
          watchdog
          ;;
        *)
          usage
          exit 64
          ;;
      esac
    '';
  };
  metadataGateCommand = "${metadataGateTool}/bin/cratedigger-metadata-gate";
  metadataGateStartCheckCommand = "${metadataGateCommand} start-check";
  metadataGateReleaseAndResumeScript = reason:
    pkgs.writeShellScript "cratedigger-release-${reason}-and-resume" ''
      set -euo pipefail
      ${metadataGateCommand} release ${lib.escapeShellArg reason}
      ${metadataGateCommand} resume-if-clear || true
    '';
  metadataGateReleaseIfClearScript = reason:
    pkgs.writeShellScript "cratedigger-release-${reason}-if-clear" ''
      set -euo pipefail
      if ${metadataGateCommand} check; then
        ${metadataGateCommand} release ${lib.escapeShellArg reason}
        ${metadataGateCommand} resume-if-clear || true
      fi
    '';

  # PostgreSQL in an nspawn container — data lives at cfg.dataDir/postgres
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "cratedigger";
    hostNum = 5;
    inherit (cfg) dataDir;
    passwordFile = "/run/secrets/cratedigger-pgpass";
  };

  sopsFile = config.homelab.secrets.sopsFile "soularr.env";
in {
  imports = [inputs.cratedigger-src.nixosModules.default];

  options.homelab.services.cratedigger = {
    enable = lib.mkEnableOption "Cratedigger — Soulseek download pipeline (homelab wrapper)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/cratedigger";
      description = "Directory for all Cratedigger state (contains postgres subdirectory).";
    };

    downloadDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Temp/slskd";
      description = "Download directory for slskd.";
    };

    metadataGate = {
      musicbrainzApiBase = lib.mkOption {
        type = lib.types.str;
        # Intentional DNS-first exception: this gate is validating the local
        # process boundary on doc2 and must not depend on Cloudflare/nginx/proxy
        # reachability while deciding whether to hold cratedigger.
        default = "http://127.0.0.1:${toString config.homelab.services.musicbrainz.webPort}/ws/2";
        description = "Local MusicBrainz /ws/2 API base URL used by the cratedigger metadata gate.";
      };

      discogsApiBase = lib.mkOption {
        type = lib.types.str;
        # Intentional DNS-first exception: see musicbrainzApiBase above.
        default = "http://127.0.0.1:${toString config.homelab.services.discogs.apiPort}";
        description = "Local Discogs API base URL used by the cratedigger metadata gate.";
      };

      discogsProbeReleaseId = lib.mkOption {
        type = lib.types.ints.positive;
        default = 83182;
        description = "Stable Discogs release ID used by the metadata gate representative lookup.";
      };

      probeTimeoutSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Maximum seconds each metadata gate HTTP probe may take.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.homelab.services.musicbrainz.enable;
        message = "homelab.services.cratedigger requires homelab.services.musicbrainz because MusicBrainz /ws/2 is a hard metadata gate.";
      }
      {
        assertion = config.homelab.services.discogs.enable;
        message = "homelab.services.cratedigger requires homelab.services.discogs because Discogs is a hard metadata gate.";
      }
    ];

    environment.systemPackages = [metadataGateTool];

    # ---------------------------------------------------------------------
    # sops-nix: decrypt the dotenv-format envfile, then split it into
    # per-key files that the upstream module can consume.
    #
    # NOTE: sops-nix `key = "X"` extraction does NOT work for multi-key
    # dotenv files — it writes the whole `KEY=VALUE` envfile regardless
    # (verified on doc2; same gotcha is documented in alerting.nix for
    # the gotify token). The upstream module wants raw values per file,
    # so we materialize them via a oneshot at boot.
    # ---------------------------------------------------------------------
    sops.secrets."soularr/env" = {
      inherit sopsFile;
      format = "dotenv";
      owner = "root";
      mode = "0400";
    };

    # PG password file — POSTGRES_PASSWORD is set, and we mirror it as
    # PGPASSWORD/PIPELINE_DB_PASSWORD in cratedigger units below so libpq
    # / sqlx / Python clients pick it up. mk-pg-container copies the root-only
    # host secret into a postgres-readable runtime file inside the nspawn.
    sops.secrets."cratedigger-pgpass" = {
      sopsFile = config.homelab.secrets.sopsFile "cratedigger-pgpass.env";
      format = "dotenv";
      mode = "0400";
    };

    # ---------------------------------------------------------------------
    # PostgreSQL container — pipeline DB.
    # ---------------------------------------------------------------------
    containers.cratedigger-db = pgc.containerConfig;

    systemd = {
      tmpfiles.rules = [
        "d ${cfg.dataDir} 0755 root root -"
        "d ${cfg.dataDir}/postgres 0700 root root -"
        "d ${metadataGateStateDir} 0755 root root -"
        "d ${metadataGateHoldDir} 0755 root root -"
      ];

      services =
        {
          cratedigger-secrets-split = {
            description = "Split soularr.env into per-key secret files for the upstream module";
            wantedBy = ["multi-user.target"];
            before = [
              "cratedigger.service"
              "cratedigger-web.service"
              "cratedigger-db-migrate.service"
              "cratedigger-importer.service"
              "cratedigger-import-preview-worker.service"
            ];
            after = ["sysinit-reactivation.target"];
            restartTriggers = [config.sops.secrets."soularr/env".path];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "cratedigger-secrets-split" ''
                set -euo pipefail
                env_file="${config.sops.secrets."soularr/env".path}"
                out_dir="/run/cratedigger-secrets"
                # Dir is 0750 root:cratedigger-ops + files are 0440 root:cratedigger-ops
                # so the operator can read the raw secrets when running
                # `pipeline-cli force-import` from a non-root shell.
                # Without this, post-import Meelo/Plex/Jellyfin notifier scans from
                # CLI invocations silently no-op — the upstream module doesn't copy
                # plaintext into config.ini anymore (issue #117), so the operator
                # has to read the source files directly.
                ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g cratedigger-ops "$out_dir"
                for key in SOULARR_SLSKD_API_KEY MEELO_USERNAME MEELO_PASSWORD PLEX_TOKEN JELLYFIN_TOKEN; do
                  ${pkgs.gnugrep}/bin/grep -m1 "^$key=" "$env_file" \
                    | ${pkgs.coreutils}/bin/cut -d= -f2- \
                    | ${pkgs.coreutils}/bin/tr -d '\n' \
                    > "$out_dir/$key"
                  ${pkgs.coreutils}/bin/chmod 0440 "$out_dir/$key"
                  ${pkgs.coreutils}/bin/chgrp cratedigger-ops "$out_dir/$key"
                done
              '';
            };
          };

          cratedigger-db-migrate = {
            after = ["container@cratedigger-db.service"];
            requires = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          cratedigger = {
            after = ["slskd.service" "container@cratedigger-db.service"] ++ metadataGateDependencyUnits;
            wants = ["slskd.service" "container@cratedigger-db.service"];
            serviceConfig = {
              ExecCondition = metadataGateStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-web = {
            after = ["container@cratedigger-db.service" "redis-cratedigger.service"] ++ metadataGateDependencyUnits;
            wants = ["container@cratedigger-db.service" "redis-cratedigger.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              ExecCondition = metadataGateStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-importer = {
            after = ["container@cratedigger-db.service"] ++ metadataGateDependencyUnits;
            wants = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              ExecCondition = metadataGateStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-import-preview-worker = {
            after = ["container@cratedigger-db.service"] ++ metadataGateDependencyUnits;
            wants = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              ExecCondition = metadataGateStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-metadata-gate-watchdog = {
            description = "Stop cratedigger API-producing units when local metadata APIs are unhealthy";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${metadataGateCommand} watchdog";
            };
          };

          cratedigger-musicbrainz-maintenance-hold = {
            description = "Hold cratedigger before MusicBrainz provider transitions";
            before = musicbrainzMaintenanceUnits;
            requiredBy = musicbrainzMaintenanceUnits;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${metadataGateCommand} hold musicbrainz-maintenance";
            };
          };

          musicbrainz.serviceConfig = {
            ExecStartPost = lib.mkAfter ["${metadataGateReleaseAndResumeScript "musicbrainz-maintenance"}"];
            ExecStop = lib.mkBefore ["${metadataGateCommand} hold musicbrainz-maintenance"];
          };

          discogs-import.serviceConfig = {
            ExecStartPre = lib.mkBefore ["${metadataGateCommand} hold discogs-import"];
            ExecStartPost = lib.mkAfter ["${metadataGateReleaseAndResumeScript "discogs-import"}"];
            ExecStopPost = lib.mkAfter ["${metadataGateReleaseIfClearScript "discogs-import"}"];
          };
        }
        // lib.genAttrs (map (lib.removeSuffix ".service") musicbrainzMaintenanceUnits) (_: {
          after = ["cratedigger-musicbrainz-maintenance-hold.service"];
          requires = ["cratedigger-musicbrainz-maintenance-hold.service"];
        });

      timers = {
        cratedigger = {
          unitConfig.ConditionPathExistsGlob = "!${metadataGateHoldDir}/*";
        };

        cratedigger-metadata-gate-watchdog = {
          description = "Cratedigger metadata API gate watchdog";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitInactiveSec = "1min";
          };
        };
      };
    };

    users = {
      groups = {
        cratedigger-ops = {};
        music-import = {};
      };
      users.${operatorUser}.extraGroups = ["cratedigger-ops"];
    };

    # ---------------------------------------------------------------------
    # Reverse proxy entry.
    # ---------------------------------------------------------------------
    homelab.localProxy.hosts = [
      {
        host = "music.ablz.au";
        port = config.services.cratedigger.web.port;
      }
    ];

    # ---------------------------------------------------------------------
    # Wire up the upstream module.
    # ---------------------------------------------------------------------
    services.cratedigger = {
      enable = true;
      src = patchedCratediggerSrc;
      group = "music-import";

      # config.ini is world-readable (0644) since issue #117 — it contains
      # only *_file paths, no secrets. The raw secrets live under
      # /run/cratedigger-secrets (group-readable by `cratedigger-ops`, see the
      # splitter above) and the Python pipeline reads them on demand via
      # CratediggerConfig.resolved_*() accessors.

      slskd = {
        apiKeyFile = "/run/cratedigger-secrets/SOULARR_SLSKD_API_KEY";
        inherit (cfg) downloadDir;
      };

      pipelineDb.dsn = pgc.dbUri;
      importer.preview.enable = true;
      importer.previewWorkers = 6;

      # Absolute path to the beets library root. Beets stores file paths in
      # its SQLite DB as relative to this root; consumers that absolutize
      # (cleanup_disambiguation_orphans, trigger_plex_scan) read this from
      # config.ini. Matches `directory:` in ~/.config/beets/config.yaml.
      beetsDirectory = "/mnt/virtio/Music/Beets";

      beetsValidation = {
        enable = true;
        stagingDir = "/mnt/virtio/Music/Incoming";
        trackingFile = "/mnt/virtio/Music/Re-download/beets-validated.jsonl";
      };

      web = {
        enable = true;
        beetsDb = "/mnt/virtio/Music/beets-library.db";
        redis.host = "127.0.0.1";
      };

      notifiers = {
        meelo = {
          enable = true;
          url = "https://meelo.ablz.au";
          usernameFile = "/run/cratedigger-secrets/MEELO_USERNAME";
          passwordFile = "/run/cratedigger-secrets/MEELO_PASSWORD";
        };
        plex = {
          enable = true;
          url = "https://plex.ablz.au";
          tokenFile = "/run/cratedigger-secrets/PLEX_TOKEN";
          librarySectionId = 3;
          pathMap = "/mnt/virtio/Music/Beets:/prom_music";
        };
        jellyfin = {
          enable = true;
          url = "https://jelly.ablz.au";
          tokenFile = "/run/cratedigger-secrets/JELLYFIN_TOKEN";
        };
      };

      healthCheck = {
        enable = true;
        onFailureCommand = "${pkgs.systemd}/bin/systemctl restart slskd.service";
      };
    };

    # ---------------------------------------------------------------------
    # Homelab-specific systemd ordering against the nspawn DB container.
    # The upstream module already sets the cross-unit deps among the cratedigger
    # services themselves; we just splice in container@cratedigger-db.service.
    # restartTriggers ensure switch-to-configuration re-runs the migrate
    # oneshot whenever the container derivation changes.
    #
    # PGPASSWORD env injection (#232): every cratedigger unit that connects to
    # PG needs to pick up the password. PGPASSWORD is the libpq standard env
    # var and is respected by sqlx (Rust importer/preview-worker), psycopg /
    # asyncpg (Python pipeline-cli, web), and plain psql.
    # ---------------------------------------------------------------------
  };
}
