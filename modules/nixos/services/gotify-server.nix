{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.gotify;

  dbPath = "${cfg.dataDir}/data/gotify.db";

  # Read-only triage reader for the Gotify message DB. The DB is owned by the
  # `gotify` system user and the host is locked (forgejo#2 — no passwordless
  # sudo), so the morning triage-overnight skill cannot read it. This wrapper is
  # the ONLY sudo-granted path to it: it runs FIXED read-only queries with
  # integer-validated arguments, opens the DB with `-readonly`, and never
  # evaluates user-supplied SQL or sqlite dot-commands. That last point is the
  # whole reason a wrapper exists instead of granting `sudo sqlite3`: sqlite3's
  # `.shell`/`.system`/`.import`/`.output` dot-commands execute arbitrary
  # commands and write files, so a NOPASSWD `sudo sqlite3 <db>` is really a root
  # shell. This grant exposes exactly "list recent messages" + "show messages by
  # id" — nothing more. See docs/wiki/services/gotify.md + the triage skill.
  gotifyTriage = pkgs.writeShellApplication {
    name = "gotify-triage";
    runtimeInputs = [pkgs.sqlite];
    text = ''
      db=${lib.escapeShellArg dbPath}
      case "''${1:-recent}" in
        recent)
          hours="''${2:-30}"
          [[ "$hours" =~ ^[0-9]+$ ]] || { echo "hours must be an integer" >&2; exit 2; }
          sqlite3 -readonly -batch "$db" \
            "SELECT id, application_id, datetime(date) AS d, priority, substr(title,1,80) FROM messages WHERE date >= datetime('now','-''${hours} hours') ORDER BY date DESC;"
          ;;
        msg)
          ids="''${2:-}"
          [[ "$ids" =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo "usage: gotify-triage msg <id[,id...]>" >&2; exit 2; }
          sqlite3 -readonly -batch -line "$db" \
            "SELECT id, title, message FROM messages WHERE id IN (''${ids});"
          ;;
        *)
          echo "usage: gotify-triage recent [hours] | msg <id[,id...]>" >&2; exit 2 ;;
      esac
    '';
  };
in {
  options.homelab.services.gotify = {
    enable = lib.mkEnableOption "Gotify push notification server (native NixOS module)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/gotify-server";
      description = "Directory where Gotify stores its data (database, uploads, plugins).";
    };
  };

  config = lib.mkIf cfg.enable {
    services.gotify = {
      enable = true;
      environment = {
        GOTIFY_SERVER_PORT = 8050;
      };
    };

    # Static user so we can own virtiofs data without DynamicUser conflicts
    users.users.gotify = {
      isSystemUser = true;
      group = "gotify";
      home = cfg.dataDir;
    };
    users.groups.gotify = {};

    # Override upstream service to use static user and custom data dir.
    # #257: upstream gotify ships no sandboxing — full /mnt/* RW-visible.
    # Gotify writes only its dataDir (db, uploads, plugins), so add
    # ProtectSystem=strict + blank /mnt bound to that one virtiofs dir.
    # RequiresMountsFor orders the fail-loud bind after mnt-virtio.mount.
    systemd.services.gotify-server = {
      unitConfig.RequiresMountsFor = [cfg.dataDir];
      serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "gotify";
        Group = "gotify";
        WorkingDirectory = lib.mkForce cfg.dataDir;
        StateDirectory = lib.mkForce "";
        ProtectSystem = "strict";
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir];
      };
    };

    networking.firewall.allowedTCPPorts = [8050];

    # Make `sudo gotify-triage ...` resolve on PATH for the triage skill.
    environment.systemPackages = [gotifyTriage];

    # Scoped read-only DB access for the triage user. The locked host strips
    # passwordless sudo, so this is the single NOPASSWD carve-out — and it points
    # at the fixed-query wrapper above, NOT at `sqlite3`, so it cannot run
    # arbitrary SQL or shell. Merges with the locked-role podman allowlist
    # (fleet-deploy.nix) via the list option.
    security.sudo.extraRules = lib.mkAfter [
      {
        users = [hostConfig.user];
        commands =
          map (command: {
            inherit command;
            options = ["NOPASSWD"];
          }) [
            # Match the /run/current-system/sw/bin symlink the user actually
            # invokes — sudo compares the PATH-resolved path TEXTUALLY, not the
            # canonicalized store path, so a raw ${gotifyTriage}/bin/... rule
            # silently fails to match and falls through to "password required".
            # Same convention as the podman rules in fleet-deploy.nix (bin =
            # "/run/current-system/sw/bin"); gotifyTriage is in systemPackages
            # above, so the symlink exists.
            "/run/current-system/sw/bin/gotify-triage"
            "/run/current-system/sw/bin/gotify-triage *"
          ];
      }
    ];

    homelab = {
      localProxy.hosts = [
        {
          host = "gotify.ablz.au";
          port = 8050;
          websocket = true;
        }
      ];

      monitoring.monitors = [
        {
          name = "Gotify";
          url = "https://gotify.ablz.au/";
        }
      ];

      # See #253 audit + rules-doc "Per-service errorPatterns".
      # If Gotify fails, no alerts reach the phone. Critical.
      monitoring.errorPatterns = [
        {
          name = "Gotify server failure";
          unit = "gotify-server.service";
          # 2026-06-28: dropped the dead `fatal` arm — gotify (Go) never logs
          # that word, so it matched nothing and only implied coverage. The
          # two arms kept ARE genuine non-recovering crash signatures. Routine
          # gotify noise (`SLOW SQL >= 200ms`, `WebSocket: ReadError ... use
          # of closed network connection`) and the self-healing `unable to
          # open database` blip are deliberately NOT matched — they recover on
          # their own and would only false-page; a true gotify outage shows as
          # panic / bind failure here and via its Kuma HTTP monitor.
          pattern = "(?i)panic|listen tcp.*bind";
          severity = "critical";
          summary = "Gotify server crashed — push notifications offline";
          # Single-shot: panic lines emit once before the process exits.
          # Sustained-threshold would silently lose the alert.
          threshold = 0;
        }
      ];
    };
  };
}
