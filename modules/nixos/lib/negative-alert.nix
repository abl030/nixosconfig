{
  config,
  lib,
  pkgs,
}: let
  gotifyTokenFile = lib.attrByPath ["sops" "secrets" "gotify/token" "path"] null config;
  # `homelab.gotify.endpoint` is a readOnly option with NO default, defined only
  # when `homelab.gotify.enable` is true. `or ""` does NOT protect us: the
  # attribute exists on every host, so `or` never fires, and forcing its value
  # on a host with gotify disabled throws "accessed but has no value defined".
  # Gate on `enable` instead, which is what the `or ""` was always reaching for.
  # (Hit 2026-09-11 enabling homelab.update on imagegen-gpu, which has gotify
  # disabled because it deliberately carries no sops secrets. Such a host simply
  # cannot ping — it holds no token — so an empty URL is the correct outcome.)
  gotifyUrl =
    if config.homelab.gotify.enable
    then config.homelab.gotify.endpoint
    else "";

  bridgeUrl = config.homelab.services.alertBridge.rcaWebhookUrl or null;
  rollingUrl = config.homelab.ci.rollingFlakeUpdate.rcaWebhookUrl or null;
  bridgeSecret = config.homelab.services.alertBridge.rcaWebhookSecret or null;
  rollingSecret = config.homelab.ci.rollingFlakeUpdate.rcaWebhookSecret or null;
  rcaWebhookUrl =
    if bridgeUrl != null
    then bridgeUrl
    else if rollingUrl != null
    then rollingUrl
    else "http://100.89.160.60:8644/webhooks/alert-rca";
  rcaWebhookSecret =
    if bridgeSecret != null
    then bridgeSecret
    else if rollingSecret != null
    then rollingSecret
    else "alert-bridge-rca";
in ''
  # Hermes alert-RCA delivery. Returns curl's status (non-zero when the webhook
  # is unreachable) so a caller can decide what the fallback page should say.
  send_rca_alert() {
    local title="$1"
    local message="$2"
    local priority="''${3:-5}"

    local payload
    payload="$(${pkgs.python3}/bin/python3 -c 'import json,sys; print(json.dumps({"title": sys.argv[1], "message": sys.argv[2], "priority": int(sys.argv[3])}))' "$title" "$message" "$priority")"
    ${pkgs.curl}/bin/curl -fsS --max-time 20 -X POST "${rcaWebhookUrl}" \
      -H "Content-Type: application/json" \
      -H "X-Gitlab-Token: ${rcaWebhookSecret}" \
      --data-binary "$payload" >/dev/null
  }

  # Direct Gotify page. Fallback only: if Hermes/RCA is down, keep the old
  # direct page path so negative alerts do not disappear silently.
  send_gotify_alert() {
    local title="$1"
    local message="$2"
    local priority="''${3:-5}"

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
      --data-urlencode "title=$title" \
      --data-urlencode "message=$message" \
      --data-urlencode "priority=$priority" >/dev/null || true
  }

  # RCA first, direct Gotify only when that delivery fails; same body to both.
  # A caller that wants a different fallback body (nixos-upgrade-diagnose runs
  # its local claude triage only on that path) uses the two halves directly.
  send_negative_alert() {
    send_rca_alert "$@" || send_gotify_alert "$@"
  }
''
