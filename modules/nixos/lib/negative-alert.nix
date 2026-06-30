{
  config,
  lib,
  pkgs,
}: let
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  gotifyUrl = config.homelab.gotify.endpoint or "";

  bridgeUrl = config.homelab.services.alertBridge.rcaWebhookUrl or null;
  rollingUrl = config.homelab.ci.rollingFlakeUpdate.rcaWebhookUrl or null;
  bridgeSecret = config.homelab.services.alertBridge.rcaWebhookSecret or null;
  rollingSecret = config.homelab.ci.rollingFlakeUpdate.rcaWebhookSecret or null;
  rcaWebhookUrl =
    if bridgeUrl != null
    then bridgeUrl
    else if rollingUrl != null
    then rollingUrl
    else "http://192.168.1.29:8644/webhooks/alert-rca";
  rcaWebhookSecret =
    if bridgeSecret != null
    then bridgeSecret
    else if rollingSecret != null
    then rollingSecret
    else "alert-bridge-rca";
in ''
  send_negative_alert() {
    local title="$1"
    local message="$2"
    local priority="''${3:-5}"

    local payload
    payload="$(${pkgs.python3}/bin/python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "message": sys.argv[2], "priority": int(sys.argv[3])}))' "$title" "$message" "$priority")"
    if ${pkgs.curl}/bin/curl -fsS --max-time 20 -X POST "${rcaWebhookUrl}" \
      -H "Content-Type: application/json" \
      -H "X-Gitlab-Token: ${rcaWebhookSecret}" \
      --data-binary "$payload" >/dev/null; then
      return 0
    fi

    # Fallback only: if Hermes/RCA is down, keep the old direct page path so
    # negative alerts do not disappear silently.
    local token_file="${
    if gotifyTokenFile != null
    then gotifyTokenFile
    else ""
  }"
    if [ -z "$token_file" ] || [ ! -r "$token_file" ] || [ -z "${gotifyUrl}" ]; then
      echo "No RCA delivery and no Gotify fallback available for: $title" >&2
      return 0
    fi
    local raw_token token
    raw_token="$(cat "$token_file")"
    if [[ "$raw_token" == GOTIFY_TOKEN=* ]]; then
      token="''${raw_token#GOTIFY_TOKEN=}"
    else
      token="$raw_token"
    fi
    token="$(printf '%s' "$token" | tr -d '\r\n')"
    if [ -z "$token" ]; then
      return 0
    fi
    ${pkgs.curl}/bin/curl -fsS -X POST "${gotifyUrl}/message?token=$token" \
      -F "title=$title" \
      -F "message=$message" \
      -F "priority=$priority" >/dev/null || true
  }
''
