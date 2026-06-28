{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.paperless;
  pgc = import ../lib/mk-pg-container.nix {
    inherit pkgs;
    name = "paperless";
    hostNum = 3;
    inherit (cfg) dataDir;
    passwordFile = "/run/secrets/paperless-pgpass";
  };

  # Real Paperless storage paths live on tower NFS under a path with spaces.
  # The space-bearing source paths are escaped per systemd.exec(5) (backslash-
  # space) and bound to space-free destinations inside the unit's sandboxed
  # /mnt tmpfs — see sandbox below. Upstream paperless's `mediaDir` /
  # `consumptionDir` then point at the space-free destinations directly, no
  # symlinks required.
  realMediaDir = ''/mnt/data/Life/Meg\ and\ Andy/Paperless/Documents'';
  realScansDir = ''/mnt/data/Life/Meg\ and\ Andy/Scans'';
  mediaDir = "/mnt/paperless-media";
  consumeDir = "/mnt/paperless-consume";

  # Per-unit sandbox: replace /mnt with an empty tmpfs and bind only the three
  # paths paperless actually needs. This narrows paperless's visible filesystem
  # to its own data (cf. anti-pattern: paperless used to see all of /mnt/data,
  # /mnt/appdata, /mnt/mum, /mnt/mirrors, /mnt/virtio — ro but every byte
  # readable). BindPaths fails loudly if a source isn't bindable
  # (status=226/NAMESPACE), so a missing/stale NFS path will surface as a
  # failed unit + the unit's existing errorPattern alert, not silent
  # read-only-fs at first write.
  mntSandbox = {
    serviceConfig = {
      TemporaryFileSystem = "/mnt";
      BindPaths = [
        "${realMediaDir}:${mediaDir}"
        "${realScansDir}:${consumeDir}"
        "${cfg.dataDir}"
      ];
    };
  };

  # Shared deps for all paperless systemd services.
  # restartTriggers: see immich.nix comment — Requires= cascade-stops paperless
  # services when the container restarts, but switch-to-configuration won't bring
  # them back unless their own unit files changed.
  dbAndNfs = {
    after = ["container@paperless-db.service" "mnt-data.mount"];
    requires = ["container@paperless-db.service" "mnt-data.mount"];
    restartTriggers = [config.systemd.units."container@paperless-db.service".unit];
  };

  # Pre-consume script: scanner defaults to duplex, so every other page on
  # single-sided originals is a blank back. Rasterise each page at 50 DPI and
  # drop any where stddev < 0.01 AND mean > 0.985 (calibrated against doc 742
  # — content pages sit at stddev >=0.089, blanks at <=0.005, so the 0.01 cut
  # has a ~18x safety margin against false positives).
  blankStrip = pkgs.writeShellApplication {
    name = "paperless-strip-blank-pages";
    runtimeInputs = with pkgs; [ghostscript imagemagick qpdf gawk coreutils];
    text = ''
      doc="''${DOCUMENT_WORKING_PATH:-}"
      [[ -z "$doc" ]] && exit 0
      [[ "''${doc,,}" != *.pdf ]] && exit 0
      [[ -f "$doc" ]] || exit 0

      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT

      pages=$(qpdf --show-npages "$doc")
      (( pages <= 1 )) && exit 0

      keep=()
      for ((i=1; i<=pages; i++)); do
        png="$tmp/p.png"
        gs -q -dNOPAUSE -dBATCH -dSAFER \
          -sDEVICE=pnggray -r50 \
          -dFirstPage="$i" -dLastPage="$i" \
          -sOutputFile="$png" "$doc" >/dev/null 2>&1 || { keep+=("$i"); continue; }
        stats=$(magick "$png" -format "%[fx:mean] %[fx:standard_deviation]" info: 2>/dev/null) || stats="0 1"
        mean="''${stats% *}"
        sd="''${stats#* }"
        if awk -v m="$mean" -v s="$sd" 'BEGIN { exit !(s < 0.01 && m > 0.985) }'; then
          echo "blank-strip: dropping page $i (mean=$mean stddev=$sd)" >&2
        else
          keep+=("$i")
        fi
      done

      if (( ''${#keep[@]} == 0 )); then
        echo "blank-strip: every page looked blank, leaving $doc untouched" >&2
        exit 0
      fi
      if (( ''${#keep[@]} == pages )); then
        exit 0
      fi

      ranges=$(IFS=,; echo "''${keep[*]}")
      out="$tmp/out.pdf"
      qpdf --empty --pages "$doc" "$ranges" -- "$out"
      mv "$out" "$doc"
      echo "blank-strip: kept ''${#keep[@]} of $pages pages" >&2
    '';
  };
in {
  options.homelab.services.paperless = {
    enable = lib.mkEnableOption "Paperless-ngx document management";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/paperless";
      description = "Directory for Paperless app state (contains postgres subdirectory)";
    };
  };

  config = lib.mkIf cfg.enable {
    # PostgreSQL in nspawn container (pattern: immich, atuin)
    containers.paperless-db = pgc.containerConfig;

    services.paperless = {
      enable = true;
      port = 28981;
      # Localhost-only: reached via the localProxy vhost (paperless.ablz.au) and
      # the paperless agents hit that FQDN. 0.0.0.0 would expose it
      # unauthenticated to the whole tailnet (tailscale0 is a trusted fw iface).
      address = "127.0.0.1";
      inherit (cfg) dataDir;

      inherit mediaDir;
      consumptionDir = consumeDir;

      # Tika + Gotenberg for OCR of Office docs and emails
      configureTika = true;

      # External postgres via nspawn container
      database.createLocally = false;

      # Admin password — only used on first run to create superuser
      passwordFile = config.sops.secrets."paperless/password".path;

      # DB password and other secrets via environment file
      environmentFile = config.sops.secrets."paperless/env".path;

      settings = {
        PAPERLESS_DBENGINE = "postgresql";
        PAPERLESS_DBHOST = pgc.dbHost;
        PAPERLESS_DBPORT = pgc.dbPort;
        PAPERLESS_DBNAME = "paperless";
        PAPERLESS_DBUSER = "paperless";
        PAPERLESS_URL = "https://paperless.ablz.au";
        PAPERLESS_CONSUMER_RECURSIVE = true;
        PAPERLESS_CONSUMER_POLLING = 60;
        PAPERLESS_TIME_ZONE = "Australia/Perth";
        PAPERLESS_PRE_CONSUME_SCRIPT = "${blankStrip}/bin/paperless-strip-blank-pages";
      };
    };

    # All paperless services must wait for DB container and NFS, pick up the
    # pgpass env file so PAPERLESS_DBPASSWORD is set for libpq, and sandbox
    # /mnt to only the paths paperless legitimately needs.
    systemd.services = let
      base =
        dbAndNfs
        // {
          serviceConfig =
            mntSandbox.serviceConfig
            // {
              EnvironmentFile = lib.mkAfter [config.sops.secrets."paperless-pgpass".path];
            };
        };
    in {
      paperless-scheduler = base;
      paperless-task-queue = base;
      paperless-consumer = base;
      paperless-web = base;

      # configureTika spins up standalone gotenberg.service + tika.service
      # (stateless HTTP helpers for Office/email OCR). They inherit doc2's
      # full /mnt/* tree for no reason — blank it. No bind source → no
      # NAMESPACE errorPattern (#257).
      gotenberg.serviceConfig.TemporaryFileSystem = "/mnt";
      tika.serviceConfig.TemporaryFileSystem = "/mnt";

      # paperless's redis (task broker) stores in /var/lib — nothing under
      # /mnt. Blank it (#257).
      redis-paperless.serviceConfig.TemporaryFileSystem = "/mnt";
    };

    # Paperless user needs NFS access
    users.users.paperless.extraGroups = ["users"];

    sops.secrets = {
      # Secrets
      "paperless/env" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless.env";
        format = "dotenv";
        owner = "paperless";
        mode = "0400";
      };
      "paperless/password" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless-admin-password";
        format = "binary";
        owner = "paperless";
        mode = "0400";
      };
      # PG password file — POSTGRES_PASSWORD + PAPERLESS_DBPASSWORD aliases of
      # the same value; the file contains nothing but the DB password.
      "paperless-pgpass" = {
        sopsFile = config.homelab.secrets.sopsFile "paperless-pgpass.env";
        format = "dotenv";
        mode = "0400";
      };
    };

    homelab = {
      nfsWatchdog.paperless-web.path = "/mnt/data";

      localProxy.hosts = [
        {
          host = "paperless.ablz.au";
          port = 28981;
        }
      ];

      monitoring.monitors = [
        {
          name = "Paperless";
          url = "https://paperless.ablz.au/";
        }
      ];

      # See #253 audit + rules-doc "Per-service errorPatterns".
      monitoring.errorPatterns = [
        # All paperless patterns: threshold=0. Each catches a DB-auth or
        # worker/scheduler failure that emits the matching line once per
        # restart attempt; systemd's StartLimitBurst caps retries, so we
        # can't rely on N occurrences.
        #
        # 2026-06-28: these were named "…NFS/auth failure" and their comments
        # claimed to catch the NFS+BindPaths `Failed at step NAMESPACE` cycle
        # — but the regexes only ever matched the Postgres auth string, so an
        # operator over-trusted them for NFS. NFS/NAMESPACE start-failures
        # already page ONCE fleet-wide via the "Service failed to start
        # (sandbox/namespace)" alert in alerting.nix (storm de-collide
        # 2026-06-26), and a stale mount also trips the nfs-watchdog. Adding
        # `Failed at step NAMESPACE` here too would just DOUBLE-page. So the
        # fix is honesty: rename to the DB/worker signal they actually carry.
        {
          name = "Paperless web DB auth failure";
          unit = "paperless-web.service";
          # pgauth failure = DB grant regression (#232 trust→scram).
          pattern = "(?i)password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "paperless-web cannot connect to its database";
          description = ''
            paperless-web hit `password authentication failed` — the #232
            trust→scram class. NFS/mount failures are covered separately by
            the fleet-wide NAMESPACE alert and the nfs-watchdog, not here.
          '';
          threshold = 0;
        }
        {
          name = "Paperless consumer DB auth failure";
          unit = "paperless-consumer.service";
          # pgauth = DB grant regression (#232). Excludes the chronic
          # ConsumerError(duplicate) noise. NFS handled fleet-wide (see above).
          pattern = "(?i)password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "paperless-consumer cannot connect to its database";
          description = "Document ingest is stopped while the DB grant is broken.";
          threshold = 0;
        }
        {
          name = "Paperless scheduler degraded";
          unit = "paperless-scheduler.service";
          # Redis MISCONF = disk persistence broken; beat won't schedule.
          # DB auth = #232 class. NFS handled fleet-wide (see above).
          pattern = "(?i)password authentication failed for user \"paperless\"|celery\\.beat.*MISCONF";
          severity = "warning";
          summary = "celery beat scheduler is degraded";
          threshold = 0;
        }
        {
          name = "Paperless task queue worker dead";
          unit = "paperless-task-queue.service";
          # Worker death = ingest pipeline stops. Excludes per-doc
          # ConsumerError + OCR ghostscript warnings. DB auth = #232 class.
          # NFS handled fleet-wide (see above).
          pattern = "(?i)\\[CRITICAL\\] \\[celery\\.worker\\] Unrecoverable|password authentication failed for user \"paperless\"";
          severity = "critical";
          summary = "celery worker can't start or died — document ingest stopped";
          threshold = 0;
        }
      ];
    };
  };
}
