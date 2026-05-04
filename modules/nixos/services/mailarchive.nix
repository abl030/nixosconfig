# Mail archival via mbsync + cyrus-sasl-xoauth2 + a small Python OAuth helper.
#
# Replaces the Win10 MailStore VM with a NixOS-native fetcher that pulls
# Gmail and O365 (cullenwines.com.au) into Maildir under
# /mnt/data/Life/Andy/Email/<account>/. Backup-of-record posture:
# Sync Pull, Create Near, Remove None, Expunge None — server-side
# deletions never propagate to the local archive.
#
# Runbook: docs/wiki/services/mailarchive.md
# Plan:    docs/plans/2026-05-04-001-feat-mailarchive-mailstore-retirement-plan.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.mailarchive;

  # OAuth2 helper — same definition exported by nix/devshell.nix as the
  # `oauth2-helper` flake app, so the bootstrap and runtime refresh paths
  # share one binary.
  oauth2Helper = import ../../../nix/pkgs/oauth2-helper.nix {inherit pkgs;};

  # Heartbeat HTTP server. Reads /var/lib/mailarchive/<account>.heartbeat
  # mtimes and serves a server-side boolean `healthy` flag. The
  # server-side boolean is required because monitoring_sync.nix hardcodes
  # the json-query operator to `==` — a client-side `<600` comparator would
  # silently fail. See plan §"Heartbeat via pull/json-query with server-side
  # boolean".
  healthServer =
    pkgs.writers.writePython3Bin "mailarchive-health" {
      flakeIgnore = ["E501"];
    } ''
      """Tiny HTTP server reporting per-account fetcher freshness."""

      import datetime
      import json
      import os
      import sys
      from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

      HOST = os.environ.get("BIND_HOST", "127.0.0.1")
      PORT = int(os.environ.get("BIND_PORT", "9876"))
      HEARTBEAT_DIR = os.environ.get("HEARTBEAT_DIR", "/var/lib/mailarchive")
      THRESHOLD = int(os.environ.get("STALE_THRESHOLD_SEC", "600"))
      ACCOUNTS = set(filter(None, os.environ.get("ACCOUNTS", "").split(",")))


      def health_for(account):
          path = os.path.join(HEARTBEAT_DIR, f"{account}.heartbeat")
          try:
              mtime = os.path.getmtime(path)
          except FileNotFoundError:
              return {"healthy": False, "stale_seconds": None, "last_sync": None}
          import time
          stale = int(time.time() - mtime)
          return {
              "healthy": stale < THRESHOLD,
              "stale_seconds": stale,
              "last_sync": datetime.datetime.fromtimestamp(mtime, datetime.timezone.utc).isoformat(),
          }


      class Handler(BaseHTTPRequestHandler):
          def log_message(self, *_args):  # quiet
              return

          def do_GET(self):
              parts = self.path.strip("/").split("/")
              if len(parts) == 2 and parts[0] == "health":
                  account = parts[1]
                  if account not in ACCOUNTS:
                      self.send_response(404)
                      self.send_header("Content-Type", "application/json")
                      self.end_headers()
                      self.wfile.write(json.dumps({"error": "unknown account"}).encode())
                      return
                  body = json.dumps(health_for(account)).encode()
                  self.send_response(200)
                  self.send_header("Content-Type", "application/json")
                  self.send_header("Content-Length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
                  return
              self.send_response(404)
              self.end_headers()


      def main():
          srv = ThreadingHTTPServer((HOST, PORT), Handler)
          sys.stderr.write(f"mailarchive-health: listening on {HOST}:{PORT}, accounts={sorted(ACCOUNTS)}\n")
          srv.serve_forever()


      if __name__ == "__main__":
          main()
    '';

  defaultGmailFolders = ["[Gmail]/All Mail"];
  defaultO365Folders = [
    "INBOX*"
    "Sent Items*"
    "Archive"
    "Archives*"
    "Drafts"
    "Deleted Items*"
    "Junk Email"
  ];

  # IMAP host per provider.
  imapHostFor = provider: let
    hosts = {
      gmail = "imap.gmail.com";
      o365 = "outlook.office365.com";
    };
  in
    hosts.${provider};

  # Render an mbsync rc for a single account. Backup-of-record posture:
  # `Sync Pull` (one-way, server → local), `Create Near` (don't pollute the
  # remote with locally-created folders), `Remove None` + `Expunge None`
  # (server-side deletions never propagate locally — deletion-resistance).
  mkMbsyncRc = name: acct: let
    quotedPatterns =
      lib.concatStringsSep " " (map (p: "\"${p}\"") acct.folderPatterns);
  in ''
    IMAPAccount ${name}
    Host ${imapHostFor acct.provider}
    User ${acct.remoteUser}
    AuthMechs XOAUTH2
    PassCmd "${oauth2Helper}/bin/oauth2-helper refresh --provider=${acct.provider}"
    SSLType IMAPS
    PipelineDepth 1

    IMAPStore ${name}-remote
    Account ${name}

    MaildirStore ${name}-local
    Path ${cfg.dataDir}/${name}/
    SubFolders Verbatim

    Channel ${name}
    Far :${name}-remote:
    Near :${name}-local:
    Patterns ${quotedPatterns}
    Sync Pull
    Create Near
    Remove None
    Expunge None
    SyncState *
  '';

  accountModule = lib.types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      provider = lib.mkOption {
        type = lib.types.enum ["gmail" "o365"];
        description = "Mail provider — drives OAuth flow specifics and folder defaults.";
      };

      remoteUser = lib.mkOption {
        type = lib.types.str;
        description = "Remote IMAP user (full email address).";
      };

      syncIntervalSec = lib.mkOption {
        type = lib.types.int;
        default =
          if config.provider == "o365"
          then 60
          else 120;
        defaultText = lib.literalExpression "60 for o365, 120 for gmail";
        description = "Seconds between mbsync runs.";
      };

      credentialSecret = lib.mkOption {
        type = lib.types.str;
        default = "mailarchive/${name}";
        defaultText = lib.literalExpression "mailarchive/<account>";
        description = ''
          sops secret name. Defaults to "mailarchive/<account>" — the
          per-account dotenv must contain OAUTH_REFRESH_TOKEN, OAUTH_CLIENT_ID,
          and (Gmail only) OAUTH_CLIENT_SECRET.
        '';
      };

      folderPatterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default =
          if config.provider == "gmail"
          then defaultGmailFolders
          else defaultO365Folders;
        defaultText = lib.literalExpression ''
          gmail → ["[Gmail]/All Mail"]
          o365  → ["INBOX*" "Sent Items*" "Archive" "Archives*" "Drafts" "Deleted Items*" "Junk Email"]
        '';
        description = ''
          mbsync Patterns directive — list of patterns to fetch. Trailing `*`
          makes a pattern recursive. Gmail's default fetches All Mail only
          (Gmail labels-as-folders multiplies messages per label, so the
          canonical backup target is `[Gmail]/All Mail`).
        '';
      };
    };
  });
in {
  options.homelab.services.mailarchive = {
    enable = lib.mkEnableOption "Mail archival via mbsync + XOAUTH2";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Life/Andy/Email";
      description = "Base directory for per-account Maildir trees.";
    };

    healthPort = lib.mkOption {
      type = lib.types.port;
      default = 9876;
      description = "Localhost port for the mailarchive-health server.";
    };

    staleThresholdSec = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = ''
        Seconds since last successful sync before /health/<account> reports
        healthy=false. Pairs with Uptime Kuma's maxretries × interval to give
        ~10-20 min total page latency for a stuck fetcher.
      '';
    };

    accounts = lib.mkOption {
      type = lib.types.attrsOf accountModule;
      default = {};
      description = "Per-account fetcher configuration.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Static system user — needs NFS write access to /mnt/data via users group.
    users.users.mailarchive = {
      isSystemUser = true;
      group = "mailarchive";
      home = "/var/lib/mailarchive";
      createHome = false;
      extraGroups = ["users"];
    };
    users.groups.mailarchive = {};

    sops.secrets =
      lib.mapAttrs' (
        name: _:
          lib.nameValuePair "mailarchive/${name}" {
            sopsFile = config.homelab.secrets.sopsFile "mailarchive-${name}.env";
            format = "dotenv";
            owner = "mailarchive";
            mode = "0400";
          }
      )
      cfg.accounts;

    # mbsync rc files. mbsync runs PassCmd via popen() so the rendered string
    # is shell-evaluated — Nix store paths and the provider enum are safe.
    environment.etc =
      lib.mapAttrs' (
        name: acct:
          lib.nameValuePair "mailarchive/mbsync-${name}.rc" {
            text = mkMbsyncRc name acct;
            mode = "0400";
            user = "mailarchive";
            group = "mailarchive";
          }
      )
      cfg.accounts;

    systemd = {
      tmpfiles.rules =
        [
          "d /var/lib/mailarchive 0700 mailarchive mailarchive - -"
        ]
        ++ (lib.mapAttrsToList (
            name: _: "d ${cfg.dataDir}/${name} 0700 mailarchive mailarchive - -"
          )
          cfg.accounts);

      services =
        (lib.mapAttrs' (
            name: _:
              lib.nameValuePair "mailarchive-${name}" {
                description = "Mail archival fetcher (${name})";
                after = ["network-online.target" "mnt-data.mount"];
                requires = ["mnt-data.mount"];
                wants = ["network-online.target"];

                path = with pkgs; [isync coreutils];
                serviceConfig = {
                  Type = "oneshot";
                  User = "mailarchive";
                  Group = "mailarchive";
                  # libsasl2 finds plugins via SASL_PATH; PATH alone is not enough.
                  Environment = "SASL_PATH=${pkgs.cyrus-sasl-xoauth2}/lib/sasl2";
                  EnvironmentFile = config.sops.secrets."mailarchive/${name}".path;
                  ExecStart = "${pkgs.isync}/bin/mbsync -c /etc/mailarchive/mbsync-${name}.rc -a";
                  # ExecStartPost only runs on ExecStart success — heartbeat
                  # therefore reflects last successful sync.
                  ExecStartPost = "${pkgs.coreutils}/bin/touch /var/lib/mailarchive/${name}.heartbeat";
                  Nice = 10;
                };
              }
          )
          cfg.accounts)
        // lib.optionalAttrs (cfg.accounts != {}) {
          # Long-running heartbeat HTTP server, polled by Uptime Kuma.
          mailarchive-health = {
            description = "Mail archival heartbeat HTTP server";
            wantedBy = ["multi-user.target"];
            after = ["network-online.target"];
            wants = ["network-online.target"];
            environment = {
              BIND_HOST = "127.0.0.1";
              BIND_PORT = toString cfg.healthPort;
              HEARTBEAT_DIR = "/var/lib/mailarchive";
              STALE_THRESHOLD_SEC = toString cfg.staleThresholdSec;
              ACCOUNTS = lib.concatStringsSep "," (lib.attrNames cfg.accounts);
            };
            serviceConfig = {
              Type = "simple";
              User = "mailarchive";
              Group = "mailarchive";
              ExecStart = "${healthServer}/bin/mailarchive-health";
              Restart = "on-failure";
              RestartSec = 5;
            };
          };
        };

      timers =
        lib.mapAttrs' (
          name: acct:
            lib.nameValuePair "mailarchive-${name}" {
              description = "Mail archival timer (${name})";
              wantedBy = ["timers.target"];
              timerConfig = {
                OnBootSec = "2min";
                OnUnitActiveSec = "${toString acct.syncIntervalSec}s";
                AccuracySec = "10s";
                Unit = "mailarchive-${name}.service";
              };
            }
        )
        cfg.accounts;
    };

    homelab = {
      # Per-account Uptime Kuma monitors. Monitor JSON shape is
      # {"healthy": true|false, ...}; with the server-side threshold, a stale
      # fetcher flips healthy→false in ~10 min, then Kuma's
      # interval=60s × maxretries=10 adds another ~10 min before paging Gotify.
      monitoring.monitors =
        lib.mapAttrsToList (name: _: {
          name = "Mailarchive: ${name}";
          type = "json-query";
          url = "http://localhost:${toString cfg.healthPort}/health/${name}";
          jsonPath = "$.healthy";
          expectedValue = "true";
        })
        cfg.accounts;

      # NFS watchdog — restart the per-account fetcher if its data path
      # under /mnt/data goes stale. The watchdog stat-checks every 5 min;
      # mbsync's incremental sync semantics tolerate the gap.
      nfsWatchdog =
        lib.mapAttrs' (
          name: _:
            lib.nameValuePair "mailarchive-${name}" {
              path = "${cfg.dataDir}/${name}";
            }
        )
        cfg.accounts;
    };
  };
}
