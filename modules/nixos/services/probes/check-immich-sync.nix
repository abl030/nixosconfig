# Deep write-path probe for Immich.
#
# Authenticated POST against /api/sync/stream with types=["AssetEditsV1"],
# which exercises sync.repository.AssetEditSync.getDeletes — the exact
# code path that returned PostgresError: permission denied for table
# asset_edit_audit in the #250 incident. Exits 0 if the API returns 2xx,
# non-zero otherwise. The deep-probe oneshot in monitoring_sync.nix
# pushes a heartbeat to Kuma on exit 0 and silently fails on anything
# else (Kuma flips DOWN after the configured maxretries).
#
# Auth: reads the API key from $IMMICH_API_KEY_FILE (path to a sops
# secret containing IMMICH_API_KEY=...). The probe oneshot loads that
# file as an EnvironmentFile, so IMMICH_API_KEY is also directly
# available as an env var — but we read from the file for resilience
# against env stripping under PrivateTmp etc.
#
# Endpoint choice:
#   POST /api/sync/stream is the canonical post-incident probe — body
#   {"types":["AssetEditsV1"]} triggers AssetEditSync.getDeletes, which
#   runs the exact SQL that broke. The endpoint returns a streaming
#   response; we only care about the initial HTTP status (200 = code
#   path completed without raising; 5xx = something blew up before
#   sending headers). If upstream Immich renames the endpoint we'll
#   need to revisit; see docs/wiki/services/immich-asset-edit-audit-incident.md.
{pkgs}:
pkgs.writeShellApplication {
  name = "check-immich-sync";
  runtimeInputs = with pkgs; [curl coreutils gnugrep];
  text = ''
    set -uo pipefail

    base="''${IMMICH_BASE_URL:-https://photos.ablz.au}"
    key_file="''${IMMICH_API_KEY_FILE:?IMMICH_API_KEY_FILE not set}"
    endpoint="''${IMMICH_PROBE_PATH:-/api/sync/stream}"

    if [ ! -r "$key_file" ]; then
      echo "[probe] key file unreadable: $key_file" >&2
      exit 2
    fi

    # Accept either KEY=value or bare-value forms.
    raw=$(cat "$key_file")
    key=''${raw#IMMICH_API_KEY=}
    key=$(printf '%s' "$key" | tr -d '\r\n')
    if [ -z "$key" ]; then
      echo "[probe] empty IMMICH_API_KEY" >&2
      exit 2
    fi

    # POST /api/sync/stream with types=["AssetEditsV1"]. The response is
    # NDJSON streamed; we read at most 4 KiB then close the connection.
    # We only branch on HTTP status, so the body content doesn't matter.
    # --max-time covers both connect + read; --connect-timeout is just
    # the initial TCP/TLS handshake.
    status=$(curl -sS -o /dev/null -w '%{http_code}' \
      --max-time 30 \
      --connect-timeout 5 \
      -X POST \
      -H "x-api-key: $key" \
      -H "content-type: application/json" \
      --max-filesize 4096 \
      -d '{"types":["AssetEditsV1"]}' \
      "$base$endpoint" 2>/dev/null || true)
    rc=$?

    if [ "$rc" -ne 0 ]; then
      echo "[probe] curl exit $rc against $base$endpoint" >&2
      exit "$rc"
    fi

    case "$status" in
      2*)
        # Healthy.
        exit 0
        ;;
      401|403)
        echo "[probe] auth failed ($status) — API key may need regeneration" >&2
        exit 1
        ;;
      5*)
        echo "[probe] server error $status — probe sees a real failure" >&2
        exit 1
        ;;
      *)
        echo "[probe] unexpected status $status" >&2
        exit 1
        ;;
    esac
  '';
}
