# homelab.services.mailsearch — local hybrid (keyword + semantic) search over
# the doc2 Maildir archive. Three roles over two local indexes, all on doc2:
#
#   1. mailsearch-index  (oneshot timer)  notmuch new -> Xapian DB, then the
#                                         embed indexer; read-only on the Maildir.
#   2. mailsearch-embed  (resident)       llama-server /v1/embeddings (nomic),
#                                         CPU, 127.0.0.1 only.
#   3. mailsearch-mcp    (SSH forced cmd) read-only MCP for the doc1 agents
#                                         (search_mail + get_message).
#   + mailsearch-health  (resident)       heartbeat HTTP -> Uptime Kuma.
#   + alot TUI (mailsearch-tui) + an fzf live-filter TUI (mailsearch-live) for
#     human keyword search over SSH.
#
# Indexes live on /mnt/virtio (local-to-VM, prom ZFS) — NEVER on the hard NFS
# Maildir mount (Xapian flintlock is unreliable over NFS; a hard mount hangs).
# Indexes are as sensitive as the mail and are NOT in the offsite backup set
# (rebuildable from the Maildir). The MCP/TUI never write the Maildir.
#
# Brainstorm: docs/brainstorms/2026-06-23-mailarchive-search-requirements.md
# Plan:       docs/plans/2026-06-23-001-feat-mailarchive-search-plan.md
# Runbook:    docs/wiki/services/mailsearch.md
#
# STATUS: LIVE on doc2 (2026-06-24). Keyword index ~143k msgs; semantic index
# bootstraps over hours on first deploy. Deploy lessons (port 8181 clash -> 18181;
# long oneshot wedging switch -> restartIfChanged=false; embed 500 on >512-token
# emails -> -b/-ub 8192) are written up in docs/wiki/services/mailsearch.md.
#
# Note: the live Maildir reads fine over NFS without any ACL or the `users`
# group (verified by indexing the full archive). Residual: the SSH-spawned MCP
# does NOT get the systemd hardening below — read-only by construction under the
# minimal `mailsearch-ro` user; a socket-activated sandbox is a follow-up.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.mailsearch;

  indexer = import ../../../nix/pkgs/mailsearch-indexer.nix {inherit pkgs;};
  mcpServer = import ../../../nix/pkgs/mailsearch-mcp.nix {inherit pkgs;};

  xapianDir = "${cfg.dataDir}/xapian";
  vectorDb = "${cfg.dataDir}/vectors.db";
  modelsDir = "${cfg.dataDir}/models";
  indexHeartbeat = "${cfg.dataDir}/index.heartbeat";
  embedHeartbeat = "${cfg.dataDir}/embed.heartbeat";
  embedUrl = "http://127.0.0.1:${toString cfg.embedPort}/v1/embeddings";
  embedReadyUrl = "http://127.0.0.1:${toString cfg.embedPort}/health";

  # notmuch config: split DB off the Maildir, never write Maildir flags, ignore
  # the to-be-deleted Mailstore/export-staging trees + mbsync sidecar files.
  notmuchConfig = pkgs.writeText "mailsearch-notmuch-config" ''
    [database]
    mail_root=${cfg.maildirRoot}
    path=${xapianDir}

    [new]
    tags=
    ignore=Mailstore;export-staging;.uidvalidity;.mbsyncstate

    [maildir]
    synchronize_flags=false

    [search]
    exclude_tags=

    [user]
    name=mailsearch
    primary_email=archive@localhost
  '';

  commonEnv = {
    NOTMUCH_CONFIG = "${notmuchConfig}";
    NOTMUCH_DATABASE = xapianDir;
    NOTMUCH_BIN = "${pkgs.notmuch}/bin/notmuch";
    MAILSEARCH_VECTOR_DB = vectorDb;
    MAILSEARCH_EMBED_URL = embedUrl;
    MAILSEARCH_EMBED_MODEL = cfg.embedModel;
    MAILSEARCH_DIM = toString cfg.embedDim;
  };

  # Forced-command target for the doc1 agent's SSH stdio transport. Sets the
  # read-only env and execs the MCP server. SSH_ORIGINAL_COMMAND is ignored.
  mcpTrigger = pkgs.writeShellScript "mailsearch-mcp-trigger" ''
    set -eu
    export NOTMUCH_CONFIG=${notmuchConfig}
    export NOTMUCH_BIN=${pkgs.notmuch}/bin/notmuch
    export MAILSEARCH_VECTOR_DB=${vectorDb}
    export MAILSEARCH_EMBED_URL=${embedUrl}
    export MAILSEARCH_EMBED_MODEL=${cfg.embedModel}
    export MAILSEARCH_DIM=${toString cfg.embedDim}
    export PATH=${lib.makeBinPath [pkgs.notmuch]}:$PATH
    exec ${mcpServer}/bin/mailsearch-mcp
  '';

  # alot shows nothing for HTML-only emails without a mailcap entry to convert
  # text/html -> text. w3m + copiousoutput renders the body inline (alot FAQ #1).
  htmlMailcap = pkgs.writeText "mailsearch.mailcap" ''
    text/html; ${pkgs.w3m}/bin/w3m -dump -o document_charset=%{charset} '%s'; nametemplate=%s.html; copiousoutput
  '';

  # Human keyword TUI wrapper — alot pointed at the read-only notmuch DB.
  tui = pkgs.writeShellScriptBin "mailsearch-tui" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    export MAILCAPS=${htmlMailcap}
    exec ${pkgs.alot}/bin/alot "$@"
  '';
  cli = pkgs.writeShellScriptBin "mailsearch" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    exec ${pkgs.notmuch}/bin/notmuch "$@"
  '';

  # ── mailsearch-live: fzf "search as you type" over notmuch ────────────────
  # alot is command-driven (type ':search …'); this wrapper is the live-filter
  # surface the user wanted — every keystroke re-runs `notmuch search` (sub-second
  # over Xapian) and replaces the list, fzf's interactive-ripgrep pattern
  # (junegunn.github.io/fzf/tips/ripgrep-integration). Words AND together, so the
  # result set narrows as you type. Three tiny helpers keep the fzf binds free of
  # nested-quote escaping.

  # One search per keystroke. {q} arrives as $1 (fzf shell-quotes it). notmuch
  # errors on an empty query, so an empty box shows the newest mail as a resting
  # view instead of an error.
  liveSearch = pkgs.writeShellScript "mailsearch-live-search" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    if [ -z "$1" ]; then
      exec ${pkgs.notmuch}/bin/notmuch search --sort=newest-first --limit=200 "*"
    fi
    exec ${pkgs.notmuch}/bin/notmuch search --sort=newest-first "$1"
  '';

  # Preview pane: headers + a readable body. Prefer the text/html part rendered
  # through w3m (clean for newsletters whose text/plain is tracking padding),
  # fall back to text/plain, then to the raw notmuch dump. $1 is the `thread:ID`
  # token from column 1 of the search line.
  livePreview = pkgs.writeShellScript "mailsearch-live-preview" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    nm=${pkgs.notmuch}/bin/notmuch
    thread="$1"
    [ -z "$thread" ] && exit 0
    mid=$("$nm" search --output=messages "$thread" 2>/dev/null | head -1)
    [ -z "$mid" ] && exit 0
    "$nm" show --format=text --body=false "$mid" 2>/dev/null \
      | ${pkgs.gnugrep}/bin/grep -E '^(Subject|From|To|Cc|Date):' || true
    printf '%s\n' "────────────────────────────────────────────────────────────"
    json=$("$nm" show --format=json "$mid" 2>/dev/null)
    hid=$(printf '%s' "$json" | ${pkgs.jq}/bin/jq -r '[..|objects|select(.["content-type"]=="text/html")][0].id // empty' 2>/dev/null)
    pid=$(printf '%s' "$json" | ${pkgs.jq}/bin/jq -r '[..|objects|select(.["content-type"]=="text/plain")][0].id // empty' 2>/dev/null)
    if [ -n "$hid" ]; then
      "$nm" show --part="$hid" "$mid" 2>/dev/null | ${pkgs.w3m}/bin/w3m -dump -T text/html -o display_link_number=false 2>/dev/null
    elif [ -n "$pid" ]; then
      "$nm" show --part="$pid" "$mid" 2>/dev/null
    else
      "$nm" show --format=text "$mid" 2>/dev/null
    fi
  '';

  # Enter opens the chosen thread in the full alot reader (HTML via the w3m
  # mailcap), then returns to the live list.
  liveReader = pkgs.writeShellScript "mailsearch-live-reader" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    export MAILCAPS=${htmlMailcap}
    exec ${pkgs.alot}/bin/alot search "$1"
  '';

  live = pkgs.writeShellScriptBin "mailsearch-live" ''
    export NOTMUCH_CONFIG=${notmuchConfig}
    # --disabled: fzf does no filtering of its own; the typed query ({q}) is fed
    # to notmuch via change:reload. ALT-ENTER freezes the current results and
    # re-enables fzf's own fuzzy match to narrow that subset (the user's
    # "search within the results" ask).
    exec ${pkgs.fzf}/bin/fzf \
      --ansi --disabled --no-sort --layout=reverse --info=inline \
      --query "$*" \
      --prompt 'mail> ' \
      --header 'live notmuch search — words AND together · ENTER read in alot · ALT-ENTER freeze + fuzzy-filter subset · CTRL-/ toggle preview' \
      --preview '${livePreview} {1}' \
      --preview-window 'right,55%,wrap' \
      --bind 'start:reload(${liveSearch} {q})' \
      --bind 'change:reload(sleep 0.1; ${liveSearch} {q})' \
      --bind 'ctrl-/:toggle-preview' \
      --bind 'alt-enter:unbind(change)+change-prompt(filter> )+enable-search+clear-query+first' \
      --bind 'enter:execute(${liveReader} {1})'
  '';

  # Heartbeat HTTP server (stdlib only). 200 when BOTH the keyword index and the
  # embed indexer are fresh, 503 otherwise — so a plain status-code Kuma monitor
  # flips DOWN on staleness. Mirrors mailarchive-health.
  healthServer =
    pkgs.writers.writePython3Bin "mailsearch-health" {
      flakeIgnore = ["E501"];
    } ''
      """Report freshness of the keyword index + embed indexer."""
      import json
      import os
      import sys
      import time
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      HOST = os.environ.get("BIND_HOST", "127.0.0.1")
      PORT = int(os.environ.get("BIND_PORT", "9878"))
      THRESHOLD = int(os.environ.get("STALE_THRESHOLD_SEC", "1800"))
      HEARTBEATS = {
          "index": os.environ.get("INDEX_HEARTBEAT", ""),
          "embed": os.environ.get("EMBED_HEARTBEAT", ""),
      }


      def freshness(path):
          try:
              return int(time.time() - os.path.getmtime(path))
          except FileNotFoundError:
              return None


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *_a):
              return

          def do_GET(self):
              if self.path.rstrip("/") not in ("/health", ""):
                  self.send_response(404)
                  self.end_headers()
                  return
              status = {k: freshness(p) for k, p in HEARTBEATS.items() if p}
              healthy = all(s is not None and s < THRESHOLD for s in status.values()) and bool(status)
              body = json.dumps({"healthy": healthy, "stale_seconds": status}).encode()
              self.send_response(200 if healthy else 503)
              self.send_header("Content-Type", "application/json")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)


      def main():
          srv = ThreadingHTTPServer((HOST, PORT), Handler)
          sys.stderr.write(f"mailsearch-health: listening on {HOST}:{PORT}\n")
          srv.serve_forever()


      if __name__ == "__main__":
          main()
    '';

  # Public half of the fleet identity (private half: doc1 bastion only). doc1's
  # MCP wrapper SSHes `mailsearch-ro@doc2` with this key; the forced command
  # below restricts that login to running the read-only MCP and nothing else.
  # Keep in sync with hosts.nix `fleetIdentity`.
  fleetPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDGR7mbMKs8alVN4K1ynvqT5K3KcXdeqlV77QQS0K1qy master-fleet-identity";

  hardening = {
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    # #257: blank the host /mnt namespace so a compromised mail-parser can't read
    # other services' exports. Each unit binds back ONLY what it needs (below).
    TemporaryFileSystem = "/mnt";
  };
in {
  options.homelab.services.mailsearch = {
    enable = lib.mkEnableOption "Local hybrid (keyword + semantic) mail-archive search";

    maildirRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Andy/Email";
      description = "Maildir root to index, read-only (matches homelab.services.mailarchive.dataDir).";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/virtio/mailsearch";
      description = ''
        Index location on local virtiofs (NOT the NFS Maildir mount). Holds the
        Xapian DB, the sqlite-vec store, the embedding model cache, and
        heartbeats. Treated as sensitive as the mail; excluded from offsite backup.
      '';
    };

    indexUser = lib.mkOption {
      type = lib.types.str;
      default = "mailsearch-index";
      description = "System user that runs notmuch new + the embed indexer (read-only on the Maildir).";
    };

    embedPort = lib.mkOption {
      type = lib.types.port;
      # 18181: 8181 is already taken on doc2 (0.0.0.0). Loopback-only here.
      default = 18181;
      description = "Localhost-only port for the llama-server embeddings endpoint.";
    };

    embedModel = lib.mkOption {
      type = lib.types.str;
      default = "nomic";
      description = "Model name sent in /v1/embeddings requests (informational for llama-server).";
    };

    embedModelSpec = lib.mkOption {
      type = lib.types.str;
      default = "nomic-ai/nomic-embed-text-v1.5-GGUF:F16";
      description = ''
        llama-server `-hf <repo>:<quant>` spec. Downloaded once into dataDir/models.
        DEPLOY-TIME VERIFY this resolves to a real GGUF.
      '';
    };

    embedDim = lib.mkOption {
      type = lib.types.int;
      default = 768;
      description = "Embedding dimension (nomic-embed-text-v1.5 = 768).";
    };

    threads = lib.mkOption {
      type = lib.types.int;
      default = 8;
      description = "CPU threads for llama-server embedding inference.";
    };

    syncIntervalSec = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Seconds between index refresh runs (notmuch new + embed delta).";
    };

    staleThresholdSec = lib.mkOption {
      type = lib.types.int;
      default = 1800;
      description = "Seconds before a heartbeat is considered stale by the health endpoint.";
    };

    healthPort = lib.mkOption {
      type = lib.types.port;
      default = 9878;
      description = "Localhost port for the mailsearch-health server.";
    };

    agentAccess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Authorize the doc1 fleet key on the read-only `mailsearch-ro` user with a
        forced command running the MCP server. This is the only path the agent
        fleet reaches the index. Never extended to hermes or any other host.
      '';
    };

    tuiUser = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "abl030";
      description = "If set, add this login user to the `mailsearch` group so they can run the keyword TUI/CLI over SSH.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${cfg.indexUser} = {
      isSystemUser = true;
      group = "mailsearch";
      # Maildir read comes from a SCOPED ACL (g:mailsearch:rX) applied at deploy,
      # NOT the broad `users` group — see docs/wiki/services/mailsearch.md.
      home = cfg.dataDir;
      createHome = false;
    };
    users.users.mailsearch-embed = {
      isSystemUser = true;
      group = "mailsearch-embed";
      home = modelsDir;
      createHome = false;
    };
    users.users.mailsearch-ro = lib.mkIf cfg.agentAccess {
      isSystemUser = true;
      group = "mailsearch";
      # Maildir read (for get_message bodies) via the same scoped g:mailsearch ACL
      # as the indexer — NOT the broad `users` group.
      home = cfg.dataDir;
      createHome = false;
      shell = pkgs.bashInteractive;
      openssh.authorizedKeys.keys = [
        ''command="${mcpTrigger}",restrict,from="100.64.0.0/10,192.168.1.0/24" ${fleetPubKey}''
      ];
    };
    users.groups.mailsearch = {};
    users.groups.mailsearch-embed = {};

    users.users.${cfg.tuiUser}.extraGroups = lib.mkIf (cfg.tuiUser != null) ["mailsearch"];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.indexUser} mailsearch - -"
      "d ${xapianDir} 0750 ${cfg.indexUser} mailsearch - -"
      "d ${modelsDir} 0750 mailsearch-embed mailsearch-embed - -"
    ];

    systemd.services = {
      # ── Keyword index + embed delta (oneshot timer) ──────────────────────
      mailsearch-index = {
        description = "Mail search: notmuch index + embedding delta";
        # This oneshot runs for hours on the first (bootstrap) embed. Do NOT let
        # `nixos-rebuild switch` restart/wait on it — that wedges the whole
        # activation. The timer picks up new config on its next tick instead.
        restartIfChanged = false;
        stopIfChanged = false;
        after = ["network-online.target" "mnt-data.mount" "mnt-virtio.mount" "mailsearch-embed.service"];
        requires = ["mnt-data.mount" "mnt-virtio.mount"];
        wants = ["network-online.target" "mailsearch-embed.service"];
        path = [pkgs.notmuch];
        environment = commonEnv // {MAILSEARCH_HEARTBEAT = embedHeartbeat;};
        serviceConfig =
          {
            Type = "oneshot";
            User = cfg.indexUser;
            Group = "mailsearch";
            UMask = "0027";
            Nice = 15;
            IOSchedulingClass = "idle";
            # The first run embeds the whole archive on CPU (hours); without this
            # the default ~90s start timeout SIGTERMs the bootstrap every tick.
            TimeoutStartSec = "6h";
            # Wait for the embeddings server to actually answer before the
            # indexer's ExecStartPost calls it (Type=simple "started" != ready;
            # first boot also downloads the model).
            ExecStartPre = "${pkgs.curl}/bin/curl -sf --retry 120 --retry-delay 5 --retry-all-errors --max-time 1200 -o /dev/null ${embedReadyUrl}";
            ExecStart = "${pkgs.notmuch}/bin/notmuch new";
            # Both run only on a successful notmuch new. The indexer touches the
            # embed heartbeat itself; we touch the index heartbeat here.
            ExecStartPost = [
              "${pkgs.coreutils}/bin/touch ${indexHeartbeat}"
              "${indexer}/bin/mailsearch-indexer"
            ];
            # #257: BindPaths (not ReadOnly/ReadWritePaths) for NFS/virtiofs — a
            # raced/stale mount fails LOUD at namespace setup instead of silently
            # skipping the bind and EROFS-ing later.
            BindReadOnlyPaths = [cfg.maildirRoot];
            BindPaths = [cfg.dataDir];
            RuntimeDirectory = "mailsearch-index";
          }
          // hardening;
        unitConfig.RequiresMountsFor = [cfg.maildirRoot cfg.dataDir];
      };

      # ── Resident embeddings server (llama.cpp, CPU, loopback) ────────────
      mailsearch-embed = {
        description = "Mail search: llama-server embeddings (nomic, CPU)";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target" "mnt-virtio.mount"];
        requires = ["mnt-virtio.mount"];
        wants = ["network-online.target"];
        environment = {
          HF_HOME = modelsDir;
          LLAMA_CACHE = modelsDir;
        };
        serviceConfig =
          {
            Type = "simple";
            User = "mailsearch-embed";
            Group = "mailsearch-embed";
            Nice = 10;
            ExecStart = lib.concatStringsSep " " [
              "${pkgs.llama-cpp}/bin/llama-server"
              "-hf ${cfg.embedModelSpec}"
              "--embeddings"
              "--pooling mean"
              # One slot, NOT the auto-picked 4. With `--parallel N`, llama-server
              # splits n_ctx across N slots (8192/4 = 2048 per slot), so every
              # embed request was capped at 2048 tokens and any longer email was
              # skipped — stalling the index at ~35%. The indexer is a single
              # sequential client, so one slot suffices and gets the FULL 8192-token
              # context. See docs/wiki/services/mailsearch.md (embed-context stall).
              "--parallel 1"
              "-c 8192"
              # Physical batch must cover a whole email in one forward pass, or
              # llama-server 500s any input over the default 512 ('input too
              # large to process. increase the physical batch size').
              "-b 8192"
              "-ub 8192"
              "--rope-scaling yarn"
              "--rope-freq-scale 0.75"
              "-ngl 0"
              "-t ${toString cfg.threads}"
              "--host 127.0.0.1"
              "--port ${toString cfg.embedPort}"
            ];
            Restart = "on-failure";
            RestartSec = "15s";
            BindPaths = [modelsDir];
            RuntimeDirectory = "mailsearch-embed";
          }
          // hardening;
        unitConfig.RequiresMountsFor = [cfg.dataDir];
      };

      # ── Heartbeat HTTP for Uptime Kuma ───────────────────────────────────
      mailsearch-health = {
        description = "Mail search heartbeat HTTP server";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        environment = {
          BIND_HOST = "127.0.0.1";
          BIND_PORT = toString cfg.healthPort;
          STALE_THRESHOLD_SEC = toString cfg.staleThresholdSec;
          # Liveness = the embed heartbeat (touched every batch + every run). The
          # index heartbeat only refreshes when `notmuch new` re-runs, which it
          # does NOT during the multi-hour single bootstrap run, so it goes stale
          # and false-pages "indexer down". The keyword index is covered by the
          # deep probe (notmuch count) instead.
          EMBED_HEARTBEAT = embedHeartbeat;
        };
        serviceConfig =
          {
            Type = "simple";
            User = cfg.indexUser;
            Group = "mailsearch";
            ExecStart = "${healthServer}/bin/mailsearch-health";
            Restart = "on-failure";
            RestartSec = 5;
            BindReadOnlyPaths = [cfg.dataDir];
          }
          // hardening;
        unitConfig.RequiresMountsFor = [cfg.dataDir];
      };
    };

    systemd.timers.mailsearch-index = {
      description = "Mail search index refresh timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "${toString cfg.syncIntervalSec}s";
        AccuracySec = "30s";
        Unit = "mailsearch-index.service";
      };
    };

    # Human keyword search over SSH (no service; a package + config).
    # mailsearch-tui = alot (command-driven), mailsearch-live = fzf live filter.
    environment.systemPackages = [tui cli live pkgs.notmuch];

    homelab.monitoring.monitors = [
      {
        name = "Mailsearch index";
        url = "http://localhost:${toString cfg.healthPort}/health";
      }
    ];

    # Deep write-path probe: the shallow heartbeat is touched on a successful
    # indexer run even if the embed leg silently embedded nothing (embed server
    # down, dimension mismatch) — so it cannot catch a stalled vector store. This
    # probe checks notmuch has messages, the vector store is non-empty and not
    # lagging unboundedly, and the embed endpoint answers. (Immich #250 pattern.)
    homelab.monitoring.deepProbes = [
      {
        name = "Mailsearch index write-path";
        command = "${pkgs.callPackage ./probes/check-mailsearch.nix {}}/bin/check-mailsearch";
        interval = "30m";
        intervalSecs = 2400;
        serviceConfig = {
          User = cfg.indexUser;
          Group = "mailsearch";
          BindReadOnlyPaths = [cfg.dataDir];
          Environment = [
            "NOTMUCH_CONFIG=${notmuchConfig}"
            "MAILSEARCH_VECTOR_DB=${vectorDb}"
            "MAILSEARCH_EMBED_HEALTH_URL=${embedReadyUrl}"
          ];
        };
      }
    ];

    # A raced/stale /mnt bind source under TemporaryFileSystem fails loud at
    # namespace setup — page on it (#257). Other transient embed/IMAP/NFS
    # flakiness is normal and surfaces via the heartbeat + Kuma monitor above.
    homelab.monitoring.errorPatterns = [
      {
        name = "Mailsearch namespace setup failure";
        unit = "mailsearch-index.service";
        pattern = "Failed at step NAMESPACE";
        severity = "critical";
        summary = "mailsearch-index could not set up its mount namespace (bind source missing/stale)";
        description = "A BindPaths/BindReadOnlyPaths source under /mnt was unavailable at unit start. Check mnt-data.mount / mnt-virtio.mount on doc2.";
        threshold = 0;
      }
    ];
  };
}
