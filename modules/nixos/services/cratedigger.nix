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
#   sudo -u cratedigger cratedigger-check-beets-config --role importer
#                                               — verify the host mutation contract
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
  webHostName = "music.ablz.au";
  webGatewayPort = 8086;
  webAccessGroup = "cratedigger-web";

  # Holds are safety state, not runtime cache. In particular, a doc2 reboot
  # during a remote Discogs table rebuild must not erase `discogs-import` and
  # let Cratedigger restart against a half-imported database.
  metadataGateStateDir = "/var/lib/cratedigger-metadata-gate";
  metadataGateHoldDir = "${metadataGateStateDir}/holds";
  # These stable files belong to the future lifecycle-migration receipt, not
  # the generic metadata gate. Keeping them outside holds/ lets that receipt
  # resume web/importer/preview while independently withholding each producer;
  # only the owning receipt may remove them.
  metadataGateMainStartInhibitor = "${metadataGateStateDir}/inhibit-cratedigger.service";
  metadataGateYoutubeStartInhibitor = "${metadataGateStateDir}/inhibit-cratedigger-youtube-ingest.service";

  processingDir = "${cfg.dataDir}/processing";
  beetsRuntime = config.homelab.services.beets.runtime;
  beetsDbDir = builtins.dirOf beetsRuntime.expectedLibrary;
  musicRoot = "/mnt/virtio/Music";
  stagingRoot = "${musicRoot}/Incoming";
  beetsLibraryRoot = beetsRuntime.expectedDirectory;
  redownloadTrackingDir = "${musicRoot}/Re-download";
  slskdDownloadDir = cfg.downloadDir;

  # #257 found that the Cratedigger app units inherited the host's entire /mnt
  # tree RW. They now run non-root and receive a private /mnt containing only
  # the explicit per-unit binds below. The pipeline's real scope is its
  # virtiofs state, the shared music subtrees it needs, and slskd download staging
  # (cfg.downloadDir — on doc2 /mnt/virtio/music/slskd, lowercase, distinct
  # from the capital-M /mnt/virtio/Music Beets tree). The main timer-driven
  # unit is narrowed here too; unfindable receives no /mnt bind. This private
  # view is not applied to gate/secrets/db-migrate/temp-clean oneshots, which
  # touch only /run, /tmp, or the DB container over TCP. See
  # docs/wiki/infrastructure/systemd-sandbox-mnt.md.
  # A writable BindPaths mount remains writable even when an upstream module
  # enables ProtectSystem=strict or names a narrower ReadWritePaths list. Keep
  # this authority table explicit so the downstream overlay cannot reopen a
  # broad Music-root write surface. Web/importer inspect the complete music
  # tree read-only but receive writes only to their reviewed subtrees. Preview
  # also resolves current-HAVE evidence from Beets, so it needs the dedicated
  # database directory as read-only authority.
  # See docs/wiki/infrastructure/systemd-sandbox-mnt.md.
  upstreamHardenedMntSandboxes = {
    cratedigger = {
      writable = [processingDir stagingRoot redownloadTrackingDir slskdDownloadDir];
      readOnly = [beetsDbDir musicRoot];
    };
    cratedigger-unfindable = {
      writable = [];
      readOnly = [];
    };
    cratedigger-web = {
      writable = [processingDir beetsDbDir beetsLibraryRoot stagingRoot slskdDownloadDir];
      readOnly = [musicRoot];
    };
    cratedigger-importer = {
      writable = [processingDir beetsDbDir beetsLibraryRoot stagingRoot redownloadTrackingDir slskdDownloadDir];
      readOnly = [musicRoot];
    };
    cratedigger-import-preview-worker = {
      writable = [processingDir slskdDownloadDir];
      readOnly = [beetsDbDir musicRoot];
    };
    cratedigger-youtube-ingest.writable = [stagingRoot];
  };
  metadataGateGuardedUnits = [
    "cratedigger.timer"
    "cratedigger.service"
    "cratedigger-web.service"
    "cratedigger-importer.service"
    "cratedigger-import-preview-worker.service"
    "cratedigger-youtube-ingest.service"
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
    "cratedigger-youtube-ingest.service"
  ];
  mountListContains = path: paths:
    builtins.elem path paths || builtins.elem "-${path}" paths;

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
        # Never SIGTERM an activating unit: doing so makes a NixOS switch fail.
        # Instead, keep reconciling until every guarded unit is conclusively
        # inactive. An activation that passed ExecCondition just before the hold
        # was written may finish, but it is stopped before this function returns
        # and therefore before any destructive remote import begins.
        local attempts=0
        local state unit
        local unsettled
        local to_stop
        while ((attempts < 120)); do
          ((attempts += 1))
          unsettled=false
          to_stop=()
          for unit in "''${guarded_units[@]}"; do
            if ! state="$(systemctl show --property=ActiveState --value "$unit")"; then
              echo "failed to query guarded unit state: $unit" >&2
              return 1
            fi
            case "$state" in
              inactive|failed) ;;
              active|reloading)
                unsettled=true
                to_stop+=("$unit")
                ;;
              "")
                echo "systemd returned an empty state for guarded unit: $unit" >&2
                return 1
                ;;
              *) unsettled=true ;;
            esac
          done

          if [ "''${#to_stop[@]}" -gt 0 ]; then
            systemctl stop "''${to_stop[@]}" || true
          elif [ "$unsettled" = false ]; then
            return 0
          fi
          sleep 1
        done

        echo "timed out waiting for guarded Cratedigger units to become inactive" >&2
        return 1
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

      # Issue #1161. True while a NixOS switch is running: the fleet path
      # (nixos-upgrade.service wraps fetch+build+switch) and a break-glass
      # manual `nixos-rebuild switch`, which runs switch-to-configuration
      # under the transient nixos-rebuild-switch-to-configuration.service.
      switch_in_flight() {
        local unit
        for unit in nixos-upgrade.service \
          nixos-rebuild-switch-to-configuration.service; do
          if systemctl is-active --quiet "$unit"; then
            return 0
          fi
        done
        return 1
      }

      watchdog() {
        if check; then
          # Issue #1161: never RESUME during a switch. resume_if_clear ends in
          # `systemctl --no-block start "''${resume_units[@]}"`. Five of those
          # six units pull in cratedigger-db-migrate.service -- web, importer,
          # preview-worker and youtube-ingest via Requires=, and
          # cratedigger.service via Wants=, which enqueues a start job just
          # the same -- so that call also starts the migrate unit. While
          # switch-to-configuration's stop transaction is still draining -- the
          # importer's #1089 graceful drain routinely takes seconds -- the
          # migrate unit's own stop job is still QUEUED behind those
          # dependents, and a start job in the default `replace` mode replaces
          # it. RemainAfterExit leaves the unit active(exited) throughout, so
          # the replacement start is a silent -EALREADY no-op and the switch's
          # migration never runs. On 2026-08-14 this timer fired at 15:26:45.96
          # inside a switch and migration 078 was skipped; the pipeline then
          # hard-failed every cycle for ~4 minutes.
          #
          # This start also lands BEFORE switch-to-configuration's
          # daemon-reload, so it can bring the guarded units up on stale unit
          # definitions, which the switch's own start phase then leaves alone
          # because they are already active.
          #
          # Upstream cratedigger now also ships stopIfChanged = false on the
          # migrate unit, so the migration itself can no longer be swallowed.
          # This guard keeps the reconciler out of the switch window entirely.
          # It NARROWS the race rather than eliminating it: a switch that
          # begins immediately after this check still overlaps. The explicit
          # `resume-if-clear` subcommand is deliberately NOT guarded -- that
          # one is operator/deploy intent, not an unattended timer.
          #
          # Only the resume (start) direction is guarded. The hold path below
          # still runs during a switch: stopping guarded units when the
          # metadata APIs are actually unhealthy is the safe direction, and
          # the switch is stopping them anyway.
          if switch_in_flight; then
            echo "nixos switch in flight; deferring cratedigger gate resume" >&2
            return 0
          fi

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
  liveWorldAuditDebtStateDir = "/var/lib/cratedigger-live-world-audit";
  liveWorldAuditDebtState = "${liveWorldAuditDebtStateDir}/known-debt.json";
  worldAuditDebtGate = "${inputs.cratedigger-src.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/cratedigger-world-audit-debt-gate";
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
  liveWorldAuditTracked = pkgs.writeShellApplication {
    name = "cratedigger-live-world-audit-tracked";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      set -euo pipefail

      if ((EUID != 0)); then
        echo "cratedigger-live-world-audit-tracked must run as root" >&2
        exit 4
      fi
      if (($# != 0)); then
        echo "usage: sudo cratedigger-live-world-audit-tracked" >&2
        exit 2
      fi

      strict_status=0
      if strict_json="$(
        ${liveWorldAudit}/bin/cratedigger-live-world-audit
      )"; then
        strict_status=0
      else
        strict_status=$?
      fi
      if ((strict_status != 0 && strict_status != 1)); then
        echo "cratedigger-live-world-audit-tracked: strict audit failed (exit $strict_status)" >&2
        exit "$strict_status"
      fi

      # The raw production report stays on doc2. Only the classifier's
      # aggregate result crosses the daily SSH boundary.
      printf '%s\n' "$strict_json" |
        ${worldAuditDebtGate} --state ${lib.escapeShellArg liveWorldAuditDebtState}
    '';
  };
  metadataGateCommand = "${metadataGateTool}/bin/cratedigger-metadata-gate";
  metadataGatePrivilegedStartCheckCommand = "+${metadataGateCommand} start-check";
  remoteDiscogsImportScript = pkgs.writeShellScript "cratedigger-discogs-import-remote" ''
    set -euo pipefail

    host=${lib.escapeShellArg cfg.metadataGate.remoteDiscogsImportHost}
    # Use doc2's persistent machine identity. The matching key on the Discogs
    # guest is forced-command + restrict, so it cannot open a shell or request
    # any operation other than starting the importer.
    key=/etc/ssh/ssh_host_ed25519_key
    ssh=(
      ${pkgs.openssh}/bin/ssh
      -o BatchMode=yes
      -o ConnectTimeout=30
      -o GlobalKnownHostsFile=/etc/ssh/ssh_known_hosts
      -o UserKnownHostsFile=/dev/null
      -o StrictHostKeyChecking=yes
      -o IdentitiesOnly=yes
      -i "$key"
      discogs-import-coordinator@"$host"
    )

    # Fail closed: any remote/import/probe failure deliberately leaves this
    # durable hold in place. Only a completed import followed by healthy
    # representative probes may release Cratedigger.
    ${metadataGateCommand} hold discogs-import
    imported=false
    for attempt in $(${pkgs.coreutils}/bin/seq 1 4); do
      if "''${ssh[@]}" start-discogs-import
      then
        imported=true
        break
      fi
      echo "remote Discogs import attempt $attempt failed" >&2
      if [ "$attempt" -lt 4 ]; then
        ${pkgs.coreutils}/bin/sleep 15m
      fi
    done

    if [ "$imported" != true ]; then
      echo "remote Discogs import exhausted retries; discogs-import hold retained" >&2
      exit 1
    fi
    if ! ${metadataGateCommand} check; then
      echo "metadata probes failed after remote Discogs import; hold retained" >&2
      exit 1
    fi
    ${metadataGateCommand} release discogs-import
    ${metadataGateCommand} resume-if-clear || true
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
        # Direct LAN endpoint: the gate must not depend on Cloudflare/nginx
        # while deciding whether to hold cratedigger.
        default = "http://192.168.1.43:${toString config.homelab.services.musicbrainz.webPort}/ws/2";
        description = "MusicBrainz /ws/2 API base URL used by the cratedigger metadata gate.";
      };

      discogsApiBase = lib.mkOption {
        type = lib.types.str;
        # Direct LAN endpoint: see musicbrainzApiBase above.
        default = "http://192.168.1.44:${toString config.homelab.services.discogs.apiPort}";
        description = "Discogs API base URL used by the cratedigger metadata gate.";
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

      remoteDiscogsImportHost = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SSH host for a remotely hosted Discogs importer. When set, Cratedigger owns the monthly timer, durable hold, retries, and post-import release.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # #847: evaluation-time pins for the declarative sandbox authority table.
    # These use the same data-driven table that renders the units; the final
    # negative assertion is the known-bad broad-parent case.
    assertions = [
      {
        assertion = config.services.cratedigger.beets.runtime == beetsRuntime;
        message = "cratedigger must consume the one deployment-owned Beets runtime capability";
      }
      {
        assertion =
          upstreamHardenedMntSandboxes.cratedigger.writable
          == [processingDir stagingRoot redownloadTrackingDir slskdDownloadDir];
        message = "the main pipeline must bind only its processing, staging, tracking, and slskd write roots";
      }
      {
        assertion = upstreamHardenedMntSandboxes.cratedigger.readOnly == [beetsDbDir musicRoot];
        message = "the main pipeline must see Beets authority only through read-only mounts";
      }
      {
        assertion =
          upstreamHardenedMntSandboxes.cratedigger-web.writable
          == [processingDir beetsDbDir beetsLibraryRoot stagingRoot slskdDownloadDir]
          && upstreamHardenedMntSandboxes.cratedigger-importer.writable
          == [processingDir beetsDbDir beetsLibraryRoot stagingRoot redownloadTrackingDir slskdDownloadDir]
          && upstreamHardenedMntSandboxes.cratedigger-import-preview-worker.writable
          == [processingDir slskdDownloadDir];
        message = "web, importer, and preview must retain only their reviewed writable Music subtrees";
      }
      {
        assertion =
          lib.all
          (unit:
            !(mountListContains
              beetsRuntime.expectedStateFile
              (config.systemd.services.${unit}.serviceConfig.BindPaths or []))
            && mountListContains
            beetsRuntime.expectedStateFile
            (config.systemd.services.${unit}.serviceConfig.BindReadOnlyPaths or []))
          ["cratedigger" "cratedigger-web" "cratedigger-import-preview-worker"];
        message = "main, web, and preview must receive the Beets state file read-only and never writable";
      }
      {
        assertion =
          mountListContains
          beetsRuntime.expectedStateFile
          (config.systemd.services.cratedigger-importer.serviceConfig.BindPaths or []);
        message = "the importer alone must receive the writable Beets state-file bind";
      }
      {
        assertion =
          !(builtins.elem musicRoot upstreamHardenedMntSandboxes.cratedigger-web.writable)
          && !(builtins.elem musicRoot upstreamHardenedMntSandboxes.cratedigger-importer.writable);
        message = "known-bad: web/importer must never receive a broad Music-root writable bind";
      }
      {
        assertion =
          metadataGateGuardedUnits
          == [
            "cratedigger.timer"
            "cratedigger.service"
            "cratedigger-web.service"
            "cratedigger-importer.service"
            "cratedigger-import-preview-worker.service"
            "cratedigger-youtube-ingest.service"
          ];
        message = "metadata gate holds must stop every ordinary Cratedigger producer";
      }
      {
        assertion =
          metadataGateResumeUnits
          == [
            "cratedigger.service"
            "cratedigger.timer"
            "cratedigger-web.service"
            "cratedigger-importer.service"
            "cratedigger-import-preview-worker.service"
            "cratedigger-youtube-ingest.service"
          ];
        message = "metadata gate resume must restore every ordinary Cratedigger producer";
      }
      {
        assertion =
          (config.systemd.services.cratedigger.unitConfig.ConditionPathExists or null)
          == "!${metadataGateMainStartInhibitor}";
        message = "the main controlled-start inhibitor must guard only cratedigger.service";
      }
      {
        assertion =
          (config.systemd.services.cratedigger-youtube-ingest.unitConfig.ConditionPathExists or null)
          == "!${metadataGateYoutubeStartInhibitor}";
        message = "the YouTube controlled-start inhibitor must guard only cratedigger-youtube-ingest.service";
      }
      {
        assertion =
          config.systemd.services.cratedigger.serviceConfig.ExecCondition
          == metadataGatePrivilegedStartCheckCommand
          && (config.systemd.services.cratedigger-youtube-ingest.serviceConfig.ExecCondition or null)
          == metadataGatePrivilegedStartCheckCommand;
        message = "controlled Cratedigger producers must retain the privileged metadata readiness check";
      }
      {
        assertion =
          lib.all
          (unit:
            (config.systemd.services.${unit}.unitConfig.ConditionPathExists or null)
            == null)
          [
            "cratedigger-web"
            "cratedigger-importer"
            "cratedigger-import-preview-worker"
          ];
        message = "controlled-start inhibitors must not block web, importer, or preview";
      }
      {
        assertion =
          lib.all
          (path:
            lib.hasPrefix "${metadataGateStateDir}/" path
            && !(lib.hasPrefix "${metadataGateHoldDir}/" path))
          [
            metadataGateMainStartInhibitor
            metadataGateYoutubeStartInhibitor
          ];
        message = "receipt-owned start inhibitors must stay outside metadata gate hold cleanup";
      }
    ];

    environment.systemPackages = [
      metadataGateTool
      liveWorldAudit
      liveWorldAuditTracked
    ];

    # The daily doc1 compatibility unit runs the tracked read-only command over
    # SSH after its candidate gates. Keep the strict command independently
    # available for diagnosis, and keep both privilege boundaries narrower
    # than a remote shell even if doc2 returns to the locked-host sudo posture.
    security.sudo.extraRules = [
      {
        users = [operatorUser];
        commands = [
          {
            command = "/run/current-system/sw/bin/cratedigger-live-world-audit";
            options = ["NOPASSWD"];
          }
          {
            command = "/run/current-system/sw/bin/cratedigger-live-world-audit-tracked";
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
        # privateUsers=no exposes the container's PostgreSQL uid/gid directly
        # on the host bind mount. Declaring this root-owned revokes PostgreSQL's
        # access on every tmpfiles reset and panics the next checkpoint.
        "d ${pgDataDirRoot}/postgres 0750 ${toString config.ids.uids.postgres} ${toString config.ids.gids.postgres} -"
        "d ${metadataGateStateDir} 0700 root root -"
        "d ${metadataGateHoldDir} 0700 root root -"
        "d ${liveWorldAuditDebtStateDir} 0700 root root -"
        # The system-level Beets module is the sole declarative owner of the
        # catalog parent, catalog file, and library root. Cratedigger retains
        # only its validation staging directory here.
        "d /mnt/virtio/Music 0755 root root -"
        "d /mnt/virtio/Music/Incoming 2775 cratedigger users -"
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
            # cratedigger#1172 item 4. This unit carries the exact #1161 shape:
            # RemainAfterExit plus Before= five workers, so on a switch its stop
            # job queues behind theirs (reverse After=). With the NixOS default
            # it lands in switch-to-configuration's stop AND start lists, and
            # any concurrent `systemctl start` (job mode replace) can replace
            # that still-queued stop; the replacement start then hits
            # unit_start()'s -EALREADY, so ExecStart never forks and systemd
            # logs nothing at all. That silently leaves the per-key secret files
            # under /run/cratedigger-secrets stale after a sops rotation.
            #
            # It is not exposed today only because the second ingredient is
            # missing -- nothing Requires=/Wants= it besides multi-user.target,
            # and it is absent from the deploy hold's resume_units/guarded_units
            # -- not because the first is. stopIfChanged = false routes it to
            # the restart list, whose JOB_RESTART absorbs a concurrent
            # JOB_START. Fail-closed hygiene; the same applies to any future
            # RemainAfterExit oneshot ordered before the workers.
            stopIfChanged = false;
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
            after = ["microvm@slskd.service" "container@cratedigger-db.service"];
            wants = ["microvm@slskd.service" "container@cratedigger-db.service"];
            unitConfig.ConditionPathExists = "!${metadataGateMainStartInhibitor}";
            serviceConfig = {
              ExecCondition = metadataGatePrivilegedStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              ReadWritePaths = lib.mkAfter [metadataGateStateDir];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-web = {
            after = ["container@cratedigger-db.service" "redis-cratedigger.service"];
            wants = ["container@cratedigger-db.service" "redis-cratedigger.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              # The fixed store command records a dependency hold. `+` keeps
              # that trusted control-plane action outside ProtectSystem=strict.
              ExecCondition = metadataGatePrivilegedStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              ReadWritePaths = lib.mkAfter [metadataGateStateDir];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-importer = {
            after = ["container@cratedigger-db.service"];
            wants = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              ExecCondition = metadataGatePrivilegedStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              ReadWritePaths = lib.mkAfter [metadataGateStateDir];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-import-preview-worker = {
            after = ["container@cratedigger-db.service"];
            wants = ["container@cratedigger-db.service"];
            restartTriggers = [config.systemd.units."container@cratedigger-db.service".unit];
            serviceConfig = {
              ExecCondition = metadataGatePrivilegedStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              ReadWritePaths = lib.mkAfter [metadataGateStateDir];
              UMask = lib.mkForce "0002";
            };
          };

          cratedigger-unfindable = {
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          # Same shape as cratedigger-unfindable: a daily timer-driven oneshot
          # that reaches the pipeline DB over TCP and therefore needs the
          # pgpass credential. Deliberately not a metadata-gate guarded unit
          # (that list covers the ordinary producers only, and is pinned by an
          # assertion above).
          cratedigger-canonical-reconcile = {
            serviceConfig.EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
          };

          cratedigger-youtube-ingest = {
            unitConfig.ConditionPathExists = "!${metadataGateYoutubeStartInhibitor}";
            serviceConfig = {
              ExecCondition = metadataGatePrivilegedStartCheckCommand;
              EnvironmentFile = lib.mkAfter [config.sops.secrets."cratedigger-pgpass".path];
              ReadWritePaths = lib.mkAfter [metadataGateStateDir];
            };
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

          # Keep the historical unit name so systemd's Persistent timer stamp
          # survives the move from the local importer to the remote coordinator.
          discogs-import = lib.mkIf (cfg.metadataGate.remoteDiscogsImportHost != null) {
            description = "Run remote Discogs import inside the Cratedigger metadata hold";
            after = ["network-online.target"];
            wants = ["network-online.target"];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = remoteDiscogsImportScript;
              TimeoutStartSec = "14h";
              NoNewPrivileges = true;
            };
          };
        }
        (lib.mapAttrs (_: sandbox: {
            unitConfig.RequiresMountsFor = sandbox.writable ++ (sandbox.readOnly or []);
            serviceConfig =
              {
                TemporaryFileSystem = "/mnt";
              }
              // lib.optionalAttrs (sandbox.writable != []) {
                BindPaths = sandbox.writable;
              }
              // lib.optionalAttrs ((sandbox.readOnly or []) != []) {
                BindReadOnlyPaths = sandbox.readOnly;
              };
          })
          upstreamHardenedMntSandboxes)
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

        discogs-import = lib.mkIf (cfg.metadataGate.remoteDiscogsImportHost != null) {
          description = "Monthly remotely coordinated Discogs dump import";
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "*-*-02 04:00:00";
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
      users.${operatorUser}.extraGroups = [
        "cratedigger-ops"
        webAccessGroup
      ];
      # The cratedigger user itself is declared by the upstream module (its
      # `mkIf (cfg.user != "root")` block below); this is an additive merge
      # of supplementary groups, not a redefinition. `music-import` is
      # LOAD-BEARING: slskd's download dir is 770 slskd:music-import, so
      # without it a non-root cratedigger can't read/reap in-flight
      # downloads. The system-level Beets owner separately adds
      # `cratedigger-ops` for its runtime secret and state capabilities.
      users.cratedigger.extraGroups = ["music-import"];
    };

    # ---------------------------------------------------------------------
    # Reverse proxy entry.
    # ---------------------------------------------------------------------
    homelab.localProxy.hosts = [
      {
        host = webHostName;
        port = webGatewayPort;
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
      processingDir = "${cfg.dataDir}/processing";

      # Manual local-import lane (cratedigger #1176). The upstream option
      # deliberately has no default: an installation that does not set these
      # has no local-import surface at all, so enabling it is a conscious act.
      # The root is broad because every Cratedigger-owned tree beneath it
      # (processing, staging, the slskd download dir, the Beets library and
      # its DB directory) is refused at execution authority regardless, so
      # breadth costs nothing there — pointing the lane at our own state is
      # the realistic operator typo, and that is where it is caught. The lane
      # only ever READS this tree: it copies into private 0700 scratch and
      # never mutates, moves, or deletes the operator's folder.
      localImport = {
        enable = true;
        dir = "/mnt/virtio";
      };

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
      musicbrainz.apiBase = "http://192.168.1.43:5200";
      # Discogs browse is mirror-required. Address the Rust API directly on
      # the private LAN: discogs.ablz.au resolves to the public Caddy proxy,
      # whose domain-fronting guard rejects this machine-to-machine path with
      # HTTP 421 before the request reaches CT 102.
      discogs.apiBase = cfg.metadataGate.discogsApiBase;

      # Cratedigger consumes the system Beets owner's one package/config/path
      # capability. Secret rendering, host-local state, shared storage, and
      # the plain operator CLI remain outside the application module.
      beets = {
        runtime = beetsRuntime;

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
        hostName = webHostName;
        gatewayPort = webGatewayPort;
        accessGroup = webAccessGroup;
        # Temporary explicit opt-out while external OIDC authorization is
        # designed and deployed. The upstream module otherwise fails closed.
        enableInsecure = true;
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
