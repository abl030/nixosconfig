# Tailscale ACL preserve-or-die path probe (issue #239, unit U5).
#
# `tests {}` in the ACL is static (accept/deny logic only) — it cannot prove
# on-wire reachability. This probe does: it exercises the paths that, if darked
# by an ACL regression, take the fleet down. Run continuously as a Kuma deep
# probe AND by hand before/AFTER the U7 flip (the flip gates on it going green
# again post-cutover).
#
# It runs from a fleet SERVER (doc1/doc2 — full mesh), so it verifies the
# SERVER-side preserve-or-die paths. The client-restriction NEGATIVE checks
# (client→non-allowlisted denied, edge→fleet denied, share→server denied,
# non-framework→wsl denied) and the HA→Cullen solar path are NOT covered here —
# there is no always-on client/edge node to probe from. Those are hand-run in U7
# (tailscale ping / nc) and via HA's solar entities, by design.
#
# Checks (each skipped if its target env var is empty):
#   1. DNS via pfSense's TAILNET ip on :53 — TCP *and* UDP (the #1 lockout risk;
#      tailscaled forwards resolution here and TCP/53 is load-bearing in this env).
#   2. A peer server's SSH :22 (TCP connect / banner).
#   3. kerrynas NFS :2049 (the offsite-backup path; doc2's kopia-mum mount).
#
# exit 0 → every configured check passed (Kuma push UP).
# exit 1 → at least one check failed (no push; Kuma flips DOWN after maxretries).
{pkgs}:
pkgs.writeShellApplication {
  name = "check-acl-paths";
  runtimeInputs = with pkgs; [dnsutils coreutils];
  text = ''
    set -uo pipefail

    pfsense_ts="''${ACL_PROBE_PFSENSE_TS:-100.123.61.111}"
    # NB: NOT one.one.one.one — pfBlockerNG/anycast handling returns it empty here
    # (verified 2026-06-21). google.com exercises the full pfSense->upstream path.
    dns_name="''${ACL_PROBE_DNS_NAME:-google.com}"
    ssh_target="''${ACL_PROBE_SSH_TARGET:-100.89.160.60:22}"   # default: doc1
    kerrynas="''${ACL_PROBE_KERRYNAS:-100.100.237.21:2049}"

    fail=0

    dns_check() {
      local proto="$1" flag="" out=""
      [ "$proto" = tcp ] && flag="+tcp"
      if out=$(timeout 6 dig $flag +short +time=3 +tries=1 @"$pfsense_ts" "$dns_name" 2>/dev/null) \
         && [ -n "$out" ]; then
        echo "[PASS] DNS/$proto via pfSense $pfsense_ts: $dns_name -> $(echo "$out" | head -1)"
      else
        echo "[FAIL] DNS/$proto via pfSense $pfsense_ts: could not resolve $dns_name" >&2
        fail=1
      fi
    }

    tcp_check() {
      local label="$1" hostport="$2" host="" port=""
      [ -z "$hostport" ] && return 0
      host="''${hostport%:*}"
      port="''${hostport##*:}"
      if timeout 6 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        echo "[PASS] $label: $hostport reachable"
      else
        echo "[FAIL] $label: $hostport unreachable" >&2
        fail=1
      fi
    }

    dns_check tcp
    dns_check udp
    tcp_check "server SSH"   "$ssh_target"
    tcp_check "kerrynas NFS" "$kerrynas"

    if [ "$fail" -ne 0 ]; then
      echo "[probe] one or more ACL preserve-or-die paths FAILED" >&2
      exit 1
    fi
    echo "[probe] all configured ACL paths healthy"
    exit 0
  '';
}
