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
#   ens18 = 192.168.1.35 (main); ens19 = .36 (VPN-routed yt-dlp only).
#   slskd is a microVM at 192.168.21.2 on SLSKD_DMZ; see
#   hosts/doc2/slskd-microvm.nix.
#
# Debugging:
#   journalctl -u cratedigger -f              — watch a run in real time
#   sudo systemctl start cratedigger          — trigger a run now
#   sudo cat /var/lib/cratedigger/config.ini  — verify rendered config
#   curl -s 192.168.21.2:5030/api/v0/searches -H @/tmp/slskd-api-header | jq
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

  metadataGateStateDir = "/run/cratedigger-metadata-gate";
  metadataGateHoldDir = "${metadataGateStateDir}/holds";

  # #257: the cratedigger app units run as ROOT and inherited the host's
  # entire /mnt tree RW — including /mnt/backup/pfsense (the pfSense ZFS
  # backups), /mnt/appdata, /mnt/mum, /mnt/mirrors. The pipeline's real scope
  # is three paths: its virtiofs state/backups dir, the shared music tree
  # (beets library + Incoming + Re-download), and the slskd download staging
  # (cfg.downloadDir — on doc2 /mnt/virtio/music/slskd, lowercase, distinct
  # from the capital-M /mnt/virtio/Music beets tree). Blank /mnt and bind
  # back exactly those. This is the single
  # biggest blast-radius reduction in the #257 audit (root + everything → a
  # root process confined to its own music pipeline). NOT applied to the
  # gate/secrets/db-migrate/temp-clean oneshots — they touch only /run, /tmp,
  # or the DB container over TCP. See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
  musicBinds = [cfg.dataDir "/mnt/virtio/Music" cfg.downloadDir];
  musicSandboxUnits = [
    "cratedigger"
    "cratedigger-web"
    "cratedigger-importer"
    "cratedigger-import-preview-worker"
    "cratedigger-unfindable"
    "cratedigger-youtube-ingest"
  ];
  metadataGateGuardedUnits = [
    "cratedigger.timer"
    "cratedigger.service"
    "cratedigger-web.service"
    "cratedigger-importer.service"
    "cratedigger-import-preview-worker.service"
  ];
  metadataGateResumeUnits = [
    # The pipeline service itself, not just its timer. The timer loops via
    # OnUnitInactiveSec=1s, which only schedules once cratedigger.service has
    # run and gone inactive; its OnBootSec=5min seed is missed whenever the
    # gate holds cratedigger past boot+5min (the boot race). Starting only the
    # timer on resume leaves it armed-but-inert (NextElapse=infinity) until a
    # manual kick. Starting the service re-seeds the loop. Idempotent: a start
    # on the already-running (near-continuous) pipeline is a no-op, and holds
    # are still honoured by resume_if_clear before anything starts.
    "cratedigger.service"
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
        # Only stop units that are fully RUNNING. A unit in 'activating' is
        # mid-start (typically its start-check ExecCondition), and `systemctl
        # stop` there kills the start job with SIGTERM — systemd records
        # "Failed with result 'signal'" and switch-to-configuration exits 4
        # (the 2026-07-03 deploy failure: cratedigger-musicbrainz-maintenance-
        # hold's ExecStart raced the guarded units' starts). Every caller
        # writes the hold file BEFORE calling us, so an in-flight start either
        # skips cleanly via ExecCondition or runs at most one watchdog
        # interval (1min) before the next hold_reason catches it active.
        local unit
        local to_stop=()
        for unit in "''${guarded_units[@]}"; do
          case "$(systemctl is-active "$unit" 2>/dev/null || true)" in
            active|reloading) to_stop+=("$unit") ;;
          esac
        done
        if [ "''${#to_stop[@]}" -gt 0 ]; then
          systemctl stop "''${to_stop[@]}" || true
        fi
      }

      write_hold_reason() {
        local reason="$1"
        valid_reason "$reason"
        lock_state
        {
          echo "reason=$reason"
          echo "timestamp=$(date --iso-8601=seconds)"
        } >"$hold_dir/$reason"
      }

      hold_reason() {
        local reason="$1"
        write_hold_reason "$reason"
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
        # ExecCondition runs inside the unit that is starting. Calling
        # hold_reason here would stop all guarded units, including this
        # in-flight unit, so systemd reports SIGTERM and switch-to-configuration
        # fails. Record the hold only; ExecCondition's non-zero exit cleanly skips
        # this start, and the watchdog still stops already-running guarded units.
        write_hold_reason dependency
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
          # Reconcile unconditionally when probes are healthy. resume_if_clear
          # is idempotent (systemctl start on a running unit is a no-op) and
          # still honours active holds, so this self-heals the stuck-stopped
          # state from a boot race: at boot the musicbrainz-maintenance hold is
          # released by musicbrainz.service ExecStartPost BEFORE MusicBrainz's
          # /ws/2 API is actually serving, so resume-if-clear bails with no
          # hold left behind. The old guard (resume only when a `dependency`
          # hold exists) then never fired, leaving web/importer/preview-worker/
          # timer dead until the next manual kick. See the 2026-06-25 outage.
          resume_if_clear || true
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
  liveWorldAudit = pkgs.writeShellApplication {
    name = "cratedigger-live-world-audit";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = ''
      set -euo pipefail

      if ((EUID != 0)); then
        echo "cratedigger-live-world-audit must run as root" >&2
        exit 4
      fi
      if (($# != 0)); then
        echo "usage: sudo cratedigger-live-world-audit" >&2
        exit 2
      fi

      pgpass=${lib.escapeShellArg config.sops.secrets."cratedigger-pgpass".path}
      if ! password="$(
        ${pkgs.gnugrep}/bin/grep -m1 '^PGPASSWORD=' "$pgpass" \
          | ${pkgs.coreutils}/bin/cut -d= -f2-
      )" || [[ -z "$password" ]]; then
        echo "cratedigger-live-world-audit: PGPASSWORD is unavailable" >&2
        exit 5
      fi

      export PGPASSWORD="$password"
      exec /run/current-system/sw/bin/pipeline-cli audit world --json
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

  # PostgreSQL in an nspawn container — data lives at pgDataDirRoot/postgres
  # on doc2's LOCAL disk (NOT on virtiofs). The /mnt/virtio/cratedigger/postgres
  # path (cfg.dataDir/postgres) was hitting recurring virtiofs-mediated PANICs:
  #   PANIC: could not open file "/var/lib/postgresql/16/global/pg_control":
  #          Permission denied
  # — 21 events between 2026-04-25 and 2026-05-15 on cratedigger-db alone,
  # always at checkpoint time, all dropping every connected client. Postgres
  # has no soft-fail mode for pg_control I/O failures (LWN fsyncgate).
  # The original data has been preserved at /mnt/virtio/cratedigger/postgres
  # (a frozen snapshot taken at the cutover) for rollback. cfg.dataDir is
  # kept pointed at /mnt/virtio/cratedigger so backups/ still lives there.
  pgDataDirRoot = "/var/lib/cratedigger-db";
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "cratedigger";
    hostNum = 5;
    dataDir = pgDataDirRoot;
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

    environment.systemPackages = [
      metadataGateTool
      liveWorldAudit
    ];

    # The daily doc1 compatibility unit runs this exact read-only command over
    # SSH after its candidate gates. Keep the privilege boundary narrower than
    # a remote shell even if doc2 returns to the locked-host sudo posture.
    security.sudo.extraRules = [
      {
        users = [operatorUser];
        commands = [
          {
            command = "/run/current-system/sw/bin/cratedigger-live-world-audit";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

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
        # Postgres data dir now on local disk — see pgDataDirRoot comment above.
        # The original /mnt/virtio/cratedigger/postgres is preserved untouched
        # as the pre-migration rollback snapshot.
        "d ${pgDataDirRoot} 0755 root root -"
        "d ${pgDataDirRoot}/postgres 0700 root root -"
        "d ${metadataGateStateDir} 0755 root root -"
        "d ${metadataGateHoldDir} 0755 root root -"
        # #570: keep the library roots setgid + group-writable + group `users`
        # so new album dirs inherit the group and gid-100 consumers (Jellyfin)
        # can write NFO/art alongside media. Existing subtree ownership is fixed
        # by a one-time operator chgrp/chmod during the deploy window.
        #
        # /mnt/virtio/Music itself (root:root 0755 by default) MUST be
        # group-writable too: the beets library DB, its SQLite rollback journal,
        # beets-import.log and .harness-mutations.jsonl all live directly under
        # it, and a non-root cratedigger creating the journal in a 0755 root dir
        # fails with "attempt to write a readonly database" (regression fixed
        # 2026-07-09 — the cutover provisioned Beets/Incoming but missed their
        # shared parent). Owner stays root since the dir also holds unrelated
        # content (AI/, Live/, VA/); group `users` + setgid gives cratedigger
        # write + makes new files inherit the group.
        "d /mnt/virtio/Music 2775 root users -"
        "d /mnt/virtio/Music/Beets 2775 cratedigger users -"
        "d /mnt/virtio/Music/Incoming 2775 cratedigger users -"
        # NOTE: the discogs token (/var/lib/cratedigger/secrets/discogs-token,
        # root:root 0400) CANNOT be managed by tmpfiles — systemd-tmpfiles
        # refuses the "unsafe path transition" from the cratedigger-owned
        # /var/lib/cratedigger into the root-owned secrets/ subdir. The
        # non-root service reads it via a durable one-time operator chown to
        # `root:cratedigger-ops 0440` (matches the out-of-band-secret pattern
        # noted on beets.package.discogsTokenFile below; migrate to sops-nix
        # with owner=cratedigger when convenient).
      ];

      services = lib.mkMerge [
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
              NoNewPrivileges = true; # install/grep/chmod as root; no setuid exec (#232)
              ExecStart = pkgs.writeShellScript "cratedigger-secrets-split" ''
                set -euo pipefail
                env_file="${config.sops.secrets."soularr/env".path}"
                out_dir="/run/cratedigger-secrets"
                # Dir is 0750 root:cratedigger-ops + files are 0440 root:cratedigger-ops
                # so the operator can read the raw secrets when running
                # `pipeline-cli force-import` from a non-root shell.
                # Without this, post-import Plex/Jellyfin notifier scans from
                # CLI invocations silently no-op — the upstream module doesn't copy
                # plaintext into config.ini anymore (issue #117), so the operator
                # has to read the source files directly.
                ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g cratedigger-ops "$out_dir"
                for key in SOULARR_SLSKD_API_KEY PLEX_TOKEN JELLYFIN_TOKEN; do
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

          # #257: cratedigger's redis (job queue) stores in /var/lib — nothing
          # under /mnt. Blank it.
          redis-cratedigger.serviceConfig.TemporaryFileSystem = "/mnt";

          cratedigger-db-migrate = {
            after = ["container@cratedigger-db.service"];
            requires = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          cratedigger = {
            after = ["microvm@slskd.service" "container@cratedigger-db.service"] ++ metadataGateDependencyUnits;
            wants = ["microvm@slskd.service" "container@cratedigger-db.service"];
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

          cratedigger-unfindable = {
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          cratedigger-youtube-ingest = {
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          cratedigger-metadata-gate-watchdog = {
            description = "Stop cratedigger API-producing units when local metadata APIs are unhealthy";
            serviceConfig = {
              Type = "oneshot";
              NoNewPrivileges = true; # gate CLI → systemctl as root; no setuid exec (#232)
              ExecStart = "${metadataGateCommand} watchdog";
            };
          };

          cratedigger-temp-clean = {
            description = "Remove stale cratedigger scratch directories from /tmp";
            serviceConfig = {
              Type = "oneshot";
              NoNewPrivileges = true; # find/rm scratch dirs; no setuid exec (#232)
              ExecStart = pkgs.writeShellScript "cratedigger-temp-clean" ''
                set -euo pipefail
                ${pkgs.findutils}/bin/find /tmp -maxdepth 1 -type d \
                  \( -name 'cratedigger-import-preview-*' -o -name 'cratedigger-v0-probe-*' \) \
                  -mmin +360 -exec ${pkgs.coreutils}/bin/rm -rf -- {} +
              '';
            };
          };

          cratedigger-musicbrainz-maintenance-hold = {
            description = "Hold cratedigger before MusicBrainz provider transitions";
            before = musicbrainzMaintenanceUnits;
            requiredBy = musicbrainzMaintenanceUnits;
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              NoNewPrivileges = true; # gate CLI → systemctl as root; no setuid exec (#232)
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
        (lib.genAttrs (map (lib.removeSuffix ".service") musicbrainzMaintenanceUnits) (_: {
          after = ["cratedigger-musicbrainz-maintenance-hold.service"];
          requires = ["cratedigger-musicbrainz-maintenance-hold.service"];
        }))
        # #257 /mnt sandbox — merged into each app unit's serviceConfig
        # (systemd's submodule merge composes this with the ExecCondition /
        # EnvironmentFile / UMask blocks above). See musicBinds comment.
        (lib.genAttrs musicSandboxUnits (_: {
          unitConfig.RequiresMountsFor = musicBinds;
          serviceConfig = {
            TemporaryFileSystem = "/mnt";
            BindPaths = musicBinds;
          };
        }))
      ];

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

        cratedigger-temp-clean = {
          description = "Cratedigger scratch cleanup timer";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "30min";
            OnUnitInactiveSec = "1h";
            Persistent = true;
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
      # The cratedigger user itself is declared by the upstream module (its
      # `mkIf (cfg.user != "root")` block below); this is an additive merge
      # of supplementary groups, not a redefinition. `music-import` is
      # LOAD-BEARING: slskd's download dir is 770 slskd:music-import, so
      # without it a non-root cratedigger can't read/reap in-flight
      # downloads. The upstream discogsOperatorGroup setting below adds
      # `cratedigger-ops`, which also grants /run/cratedigger-secrets access.
      users.cratedigger.extraGroups = ["music-import"];
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

    # See #253 audit + rules-doc "Per-service errorPatterns".
    # cratedigger-web and -importer are intentionally SKIPPED — the web
    # service emits thousands of [ERROR] beets-distance API lines per
    # import session (expected scoring backoff), and the importer logs
    # per-file move errors as normal Windows-path rollback artifacts.
    # Real outages on either surface as Kuma HTTP failures.
    homelab.monitoring.errorPatterns = [
      {
        name = "Cratedigger preview worker died";
        unit = "cratedigger-import-preview-worker.service";
        # Per-thread "crashed" alone is too low-bar (ffmpeg per-file
        # failures). "exiting after N crash(es)" is when the worker
        # actually gives up and the preview pipeline stops.
        pattern = "(?i)Import preview worker exiting after \\d+ worker thread crash";
        severity = "critical";
        summary = "preview worker hit the crash limit and exited";
        # Single-shot: worker logs the give-up line once and exits.
        threshold = 0;
      }
      # #257 NAMESPACE start-failures on the music-touching app units
      # (cratedigger-web / cratedigger-importer) now page ONCE via the
      # fleet-wide "Service failed to start (sandbox/namespace)" alert in
      # alerting.nix — no per-service entries (storm de-collide 2026-06-26).
      {
        name = "Cratedigger DB migration failed";
        unit = "cratedigger-db-migrate.service";
        pattern = "(?i)error: .*migrat|migration failed|relation .* does not exist";
        severity = "critical";
        summary = "schema migration failed — app likely won't start";
        # Single-shot: migration unit exits on first failure.
        threshold = 0;
      }
    ];

    # ---------------------------------------------------------------------
    # Wire up the upstream module.
    # ---------------------------------------------------------------------
    services.cratedigger = {
      enable = true;
      src = inputs.cratedigger-src;
      user = "cratedigger";
      group = "users";

      # config.ini is world-readable (0644) since issue #117 — it contains
      # only *_file paths, no secrets. The raw secrets live under
      # /run/cratedigger-secrets (group-readable by `cratedigger-ops`, see the
      # splitter above) and the Python pipeline reads them on demand via
      # CratediggerConfig.resolved_*() accessors.

      slskd = {
        apiKeyFile = "/run/cratedigger-secrets/SOULARR_SLSKD_API_KEY";
        hostUrl = "http://192.168.21.2:5030";
        inherit (cfg) downloadDir;
      };

      pipelineDb.dsn = pgc.dbUri;
      importer.previewWorkers = 6;

      # Tier-2 cutover (cratedigger plan U12): mirrors as configuration.
      # ONE MB origin threads to web/mb.py, pipeline-cli, and the rendered
      # beets musicbrainz block (host:port / http / ratelimit 100 derived).
      musicbrainz.apiBase = "http://192.168.1.35:5200";
      # Discogs browse is mirror-required; this is the Rust mirror.
      discogs.apiBase = "https://discogs.ablz.au";

      # Module-owned beets (replaces the Home Manager beets): build-time
      # mirror patches + the Discogs token via the *File pattern. The token
      # file is root-owned under /var/lib (extracted from the old
      # ~/.config/beets/secrets.yaml during the cutover window). The upstream
      # module renders its include at 0440 for the explicit operator group so
      # pipeline-cli and the service load the same noninteractive config.
      # #495-era refactor (cratedigger commit 604da00) consolidated the beets
      # option surface under services.cratedigger.beets.*: the package/mirror
      # knobs moved to beets.package.*, the config.ini [Beets] directory to
      # beets.config.directory, and the validation gate to beets.validation.*.
      beets = {
        package = {
          discogsMirrorUrl = "https://discogs.ablz.au";
          lrclibUrl = "http://192.168.1.35:3300/api";
          discogsTokenFile = "/var/lib/cratedigger/secrets/discogs-token";
          discogsOperatorGroup = "cratedigger-ops";
        };

        # Absolute path to the beets library root. Beets stores file paths in
        # its SQLite DB as relative to this root; consumers that absolutize
        # (cleanup_disambiguation_orphans, trigger_plex_scan) read this from
        # config.ini. Matches `directory:` in ~/.config/beets/config.yaml.
        config.directory = "/mnt/virtio/Music/Beets";

        validation = {
          enable = true;
          stagingDir = "/mnt/virtio/Music/Incoming";
          trackingFile = "/mnt/virtio/Music/Re-download/beets-validated.jsonl";
        };
      };

      youtubeIngest = {
        enable = true;
        # Keep yt-dlp on doc2's pre-existing VPN-routed second NIC. slskd moved
        # to SLSKD_DMZ, but this source route remains intentionally separate.
        sourceAddress = "192.168.1.36";
      };

      web = {
        enable = true;
        redis.host = "127.0.0.1";
      };

      notifiers = {
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
          # Jellyfin owns library locations in its persistent runtime state.
          # Music item 7e64...ccb is scoped there to the Beets subtree; pin the
          # stable ID so imports refresh only that library instead of every
          # Jellyfin library. The prefix swap lets the "Recently Added"
          # DateCreated pin (cratedigger issue #574) locate imported albums.
          libraryId = "7e64e319657a9516ec78490da03edccb";
          pathMap = "/mnt/virtio/Music/Beets:/mnt/fuse/Media/Music/Beets";
        };
      };

      healthCheck = {
        enable = true;
        onFailureCommand = "${pkgs.systemd}/bin/systemctl restart microvm@slskd.service";
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
