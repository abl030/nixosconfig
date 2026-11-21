# Read-only copy-paste board: a static page that lists short-lived snippets
# (commands to paste on a machine you can't copy from). There is deliberately
# no web write path — a writable no-auth page would let anyone on the LAN plant
# a command that then gets pasted into an elevated shell. Snippets are written
# as JSON files into stateDir over SSH by cfg.user (write-then-rename), and a
# timer deletes them once their `expires` time passes.
{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.services.pasteBoard;

  site = pkgs.runCommand "paste-board-site" {} ''
    mkdir -p $out
    cp ${./index.html} $out/index.html
    cp ${./app.js} $out/app.js
  '';

  sweep = pkgs.writeShellScript "paste-board-sweep" ''
    set -uo pipefail
    now=$(${pkgs.coreutils}/bin/date +%s)
    shopt -s nullglob dotglob
    for f in ${cfg.stateDir}/msgs/*; do
      [[ -f "$f" ]] || continue
      mtime=$(${pkgs.coreutils}/bin/stat -c %Y "$f")
      # Hard ceiling regardless of contents (also catches stale temp files).
      if (( now - mtime > ${toString cfg.maxTtlSeconds} )); then
        ${pkgs.coreutils}/bin/rm -f -- "$f"; continue
      fi
      case "$f" in *.json) ;; *) continue ;; esac
      exp=$(${pkgs.jq}/bin/jq -r '.expires // empty' "$f" 2>/dev/null || true)
      if [[ ! "$exp" =~ ^[0-9]+$ ]] || (( exp <= now )); then
        ${pkgs.coreutils}/bin/rm -f -- "$f"
      fi
    done
  '';
in {
  options.homelab.services.pasteBoard = {
    enable = lib.mkEnableOption "read-only, self-expiring copy-paste board";

    fqdn = lib.mkOption {
      type = lib.types.str;
      description = "Public FQDN served through homelab.localProxy.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8890;
      description = "Loopback port for the static nginx server behind localProxy.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "Account that writes snippets (over SSH) and runs the expiry sweep.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/paste-board";
      description = "Holds msgs/, one JSON file per snippet.";
    };

    maxTtlSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 86400;
      description = "Files older than this are deleted whatever their own expiry says.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Group nginx reads; setgid so new files inherit the group; no world access.
    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} nginx -"
      "d ${cfg.stateDir}/msgs 2750 ${cfg.user} nginx -"
    ];

    services.nginx.enable = true;
    services.nginx.virtualHosts."paste-board-loopback" = {
      listen = [
        {
          addr = "127.0.0.1";
          inherit (cfg) port;
        }
      ];
      root = site;
      extraConfig = ''
        add_header Cache-Control "no-store" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header Referrer-Policy "no-referrer" always;
        add_header Content-Security-Policy "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
      '';
      locations."/".tryFiles = "$uri /index.html";
      locations."/msgs/" = {
        alias = "${cfg.stateDir}/msgs/";
        extraConfig = ''
          autoindex on;
          autoindex_format json;
          limit_except GET HEAD { deny all; }
          default_type application/json;
          # No add_header here: it would drop the server-level headers.
        '';
      };
    };

    systemd.services.paste-board-sweep = {
      description = "Delete expired paste-board snippets";
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        ExecStart = sweep;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        ReadWritePaths = ["${cfg.stateDir}/msgs"];
      };
    };
    systemd.timers.paste-board-sweep = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "minutely";
        AccuracySec = "10s";
        Persistent = true;
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        inherit (cfg) port;
      }
    ];

    # Stateless static page; snippets are disposable by design, so a deep probe
    # or log fingerprints would have nothing meaningful to assert.
    homelab.monitoring.errorPatterns = [];
  };
}
