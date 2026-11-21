# Per-host ACME certificate expiry check (#233).
#
# Independent of the renewal mechanism on purpose: NixOS's renew script
# exits 0 on a failed renewal until a third of the lifetime is left, and
# the 2026-09 lego flag rename broke every renewal fleet-wide for six days
# without a page. This timer looks only at the end result — the certificate
# a client actually gets — and logs a line Grafana alerts on
# (alerting.nix, acmeAlert).
#
# The cert list comes from this host's own `security.acme.certs` at eval
# time, so leftover directories in /var/lib/acme never false-positive.
# For each cert it reads the certificate served on 127.0.0.1:443 for the
# cert's domain (what nginx/caddy really hand out, so a missed reload
# shows up too); when nothing local serves that name it falls back to
# the file on disk.
#
# Log lines (the alert matches EXPIRING|MISSING):
#   acme-expiry-check: EXPIRING cert=<name> domain=<d> days=<n> source=<served|file>
#   acme-expiry-check: MISSING cert=<name> domain=<d>
#   acme-expiry-check: checked=<n> expiring=<n> missing=<n>
# See docs/wiki/services/acme-certificates.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.acmeMonitor;
  certs = config.security.acme.certs;

  certTable = pkgs.writeText "acme-monitor-certs.tsv" (lib.concatMapStrings (name: let
    c = certs.${name};
  in "${name}\t${c.domain}\t${c.directory}/cert.pem\n") (lib.attrNames certs));

  checkScript = pkgs.writeShellApplication {
    name = "acme-expiry-check";
    runtimeInputs = [pkgs.openssl pkgs.coreutils];
    text = ''
      warn_days=${toString cfg.warnDays}
      now=$(date +%s)
      checked=0
      expiring=0
      missing=0

      days_left() {
        local end
        end=$(openssl x509 -noout -enddate | cut -d= -f2) || return 1
        [ -n "$end" ] || return 1
        echo $(( ($(date -d "$end" +%s) - now) / 86400 ))
      }

      while IFS=$'\t' read -r name domain file; do
        checked=$((checked + 1))
        days=""
        origin=""
        # SNI probe of the local listener. Accept the answer only if the
        # served certificate is valid for this domain; otherwise the
        # listener is serving a default/other cert and the file is the
        # better source of truth.
        probe_domain=''${domain#\*.}
        served=$(timeout 10 openssl s_client -connect 127.0.0.1:443 \
          -servername "$probe_domain" </dev/null 2>/dev/null \
          | openssl x509 2>/dev/null || true)
        if [ -n "$served" ] \
          && printf '%s\n' "$served" | openssl x509 -noout -checkhost "$probe_domain" 2>/dev/null \
            | grep -q 'does match'; then
          days=$(printf '%s\n' "$served" | days_left) && origin="served"
        fi
        if [ -z "$origin" ] && [ -r "$file" ]; then
          days=$(days_left <"$file") && origin="file"
        fi
        if [ -z "$origin" ]; then
          missing=$((missing + 1))
          echo "acme-expiry-check: MISSING cert=$name domain=$domain"
          continue
        fi
        if [ "$days" -lt "$warn_days" ]; then
          expiring=$((expiring + 1))
          echo "acme-expiry-check: EXPIRING cert=$name domain=$domain days=$days source=$origin"
        fi
      done <${certTable}

      echo "acme-expiry-check: checked=$checked expiring=$expiring missing=$missing"
    '';
  };
in {
  options.homelab.acmeMonitor = {
    enable =
      lib.mkEnableOption "hourly ACME certificate expiry check (logs to journald for the fleet alert)"
      // {default = certs != {};};

    warnDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 21;
      description = ''
        Log EXPIRING for any certificate with fewer than this many days
        left. Let's Encrypt certs last 90 days and renew with about 30
        left, so a healthy fleet never gets below ~30.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.acme-expiry-check = {
      description = "Check ACME certificate expiry (served and on disk)";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe checkScript;
        # Reads /var/lib/acme/<cert>/cert.pem (owned by acme) and talks
        # to the local TLS listener only.
        User = "acme";
        Group = "acme";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        # #257 convention: nothing under /mnt is needed.
        TemporaryFileSystem = "/mnt";
        CapabilityBoundingSet = "";
        SystemCallFilter = ["@system-service"];
      };
    };

    systemd.timers.acme-expiry-check = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "5m";
      };
    };
  };
}
