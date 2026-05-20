# Grafana → claude -p → Gotify webhook bridge.
#
# Inserts itself between Grafana's alerting and Gotify so each fired alert
# can be summarised by claude (haiku) before pushing. The raw Grafana
# webhook payload is verbose (30+ lines per alert, mostly LogQL + DAG
# metadata); claude collapses it to a 2-3 line phone-readable note.
#
# Flow per alert (status=firing):
#   1. Bridge receives Grafana webhook JSON on 127.0.0.1:<port>/alert
#   2. If labels.loki_query is set, bridge re-queries Loki for the actual
#      matching lines (last 10 over a 10m window)
#   3. Composes a context block: alert metadata + log lines
#   4. Pipes to `claude -p --model haiku` with a tight system prompt
#   5. POSTs the summary to Gotify with severity-aware priority
#
# Resolved alerts are skipped (no "things are better" notifications).
# Alerts without loki_query (e.g. the Prometheus reboot rule) still work —
# claude just gets metadata-only context.
#
# Runs as the abl030 user because claude-code auth lives in that user's
# ~/.claude after the one-time interactive `sudo -u abl030 --login claude`
# setup. Same requirement as nixos-upgrade-diagnose in autoupdate/update.nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.alertBridge;

  systemPrompt = ''
    You are summarising a Grafana alert for a homelab operator reading it on
    a phone push notification. Be terse. Output plain text only, no markdown.

    Input format:
    - "## Alert metadata" block: alertname, severity, startedAt, annotations
    - Optional "## Matching log lines" block: log entries that caused the alert

    Output format — exactly 2 or 3 lines, total under 300 characters:
    Line 1 (required): <emoji> <one-line: who/what/where>
    Line 2 (required): <classification>: <one-line reasoning>
    Line 3 (optional): Next: <one-line action>, or omit if no action needed.

    Emoji rule: critical=🔴, warning=🟡, info=ℹ️
    Classification rule for DB DDL alerts: EXPECTED (operator session),
    DRIFT (unexpected schema mutation matching incident patterns), or
    UNKNOWN. For other alerts: pick the natural classification.

    Do not output anything else. No prefatory text, no closing remarks,
    no "I'll analyse...", no bullet points, no JSON.
  '';

  bridgeScript = pkgs.writers.writePython3 "alert-bridge" {flakeIgnore = ["E501" "W293" "E302" "E305" "E402" "E741" "W391" "E401"];} ''
    import http.server
    import json
    import os
    import subprocess
    import sys
    import time
    import urllib.parse
    import urllib.request

    GOTIFY_URL = os.environ["GOTIFY_URL"]
    GOTIFY_TOKEN_FILE = os.environ["GOTIFY_TOKEN_FILE"]
    LOKI_URL = os.environ.get("LOKI_URL", "http://127.0.0.1:3100")
    CLAUDE_BIN = os.environ["CLAUDE_BIN"]
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9876"))
    SYSTEM_PROMPT = os.environ["SYSTEM_PROMPT"]

    def read_token():
        try:
            with open(GOTIFY_TOKEN_FILE) as f:
                for line in f:
                    if line.startswith("GOTIFY_TOKEN="):
                        return line.split("=", 1)[1].strip()
        except Exception as e:
            print(f"[bridge] token read failed: {e}", file=sys.stderr)
        return None

    def query_loki(logql, lookback_secs=600, limit=10):
        now_ns = int(time.time() * 1e9)
        start_ns = now_ns - lookback_secs * 10**9
        params = urllib.parse.urlencode({
            "query": logql,
            "start": start_ns,
            "end": now_ns,
            "limit": limit,
            "direction": "backward",
        })
        url = f"{LOKI_URL}/loki/api/v1/query_range?{params}"
        try:
            with urllib.request.urlopen(url, timeout=8) as resp:
                data = json.load(resp)
        except Exception as e:
            return [f"(loki query failed: {e})"]
        lines = []
        for stream in data.get("data", {}).get("result", []):
            for ts, line in stream.get("values", []):
                lines.append(line)
        return lines[:limit]

    CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "opus")
    CLAUDE_TIMEOUT = int(os.environ.get("CLAUDE_TIMEOUT_SECS", "300"))

    def claude_summarise(context):
        try:
            result = subprocess.run(
                [CLAUDE_BIN, "-p",
                 "--system-prompt", SYSTEM_PROMPT,
                 "--model", CLAUDE_MODEL,
                 "--allowedTools", "",
                 "Summarise this alert."],
                input=context,
                capture_output=True,
                text=True,
                timeout=CLAUDE_TIMEOUT,
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip()
            print(f"[bridge] claude rc={result.returncode} stderr={result.stderr[:500]}",
                  file=sys.stderr)
        except Exception as e:
            print(f"[bridge] claude exception: {e}", file=sys.stderr)
        # Fallback: send raw context, truncated
        return f"(claude unavailable — raw context below)\n\n{context[:800]}"

    def gotify_push(title, message, priority=5):
        token = read_token()
        if not token:
            print(f"[bridge] no gotify token; would send: {title}", file=sys.stderr)
            return
        payload = urllib.parse.urlencode({
            "title": title,
            "message": message,
            "priority": priority,
        }).encode()
        req = urllib.request.Request(
            f"{GOTIFY_URL}/message?token={token}",
            data=payload,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
        except Exception as e:
            print(f"[bridge] gotify push failed: {e}", file=sys.stderr)

    def handle_alert(alert):
        if alert.get("status") != "firing":
            return
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        alertname = labels.get("alertname", "unknown")
        severity = labels.get("severity", "warning")
        starts_at = alert.get("startsAt", "")

        ctx = f"## Alert metadata\nalertname: {alertname}\nseverity: {severity}\nstartedAt: {starts_at}\n"
        if annotations.get("summary"):
            ctx += f"summary: {annotations['summary']}\n"
        if annotations.get("description"):
            ctx += f"description: {annotations['description'][:500]}\n"

        # Prefer the raw stream-selector query so we get actual log lines;
        # the aggregated loki_query returns scalar counts not text.
        lines_query = labels.get("loki_lines") or labels.get("loki_query")
        if lines_query:
            lines = query_loki(lines_query)
            if lines:
                ctx += "\n## Matching log lines (last 10, newest first)\n"
                for line in lines:
                    ctx += f"{line[:400]}\n"

        summary = claude_summarise(ctx)
        title = f"[{severity}] {alertname}"
        priority = 8 if severity == "critical" else 5
        gotify_push(title, summary, priority=priority)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                data = json.loads(body)
                for alert in data.get("alerts", []):
                    handle_alert(alert)
            except Exception as e:
                print(f"[bridge] handler error: {e}", file=sys.stderr)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok\n")

        def log_message(self, fmt, *args):
            return

    if __name__ == "__main__":
        print(f"[bridge] listening on 127.0.0.1:{LISTEN_PORT}", file=sys.stderr)
        http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
  '';
in {
  options.homelab.services.alertBridge = {
    enable = lib.mkEnableOption "claude-p summary bridge between Grafana alerts and Gotify";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9876;
      description = "TCP port the bridge listens on (127.0.0.1 only).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "abl030";
      description = ''
        User to run the bridge as. Must have a working claude-code auth
        in ~/.claude — establish once interactively via
        `sudo -u <user> --login claude` per host. Same requirement as
        nixos-upgrade-diagnose.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "opus";
      description = ''
        claude model to invoke. Defaults to opus because these alerts
        carry context (LogQL, log lines, schema state) that wants real
        reasoning to classify drift vs operator activity — haiku tends
        to over-pattern-match. Override per-host if cost or latency
        matters more than classification accuracy.
      '';
    };

    claudeTimeoutSecs = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = ''
        Hard timeout for the claude subprocess. Opus is slower than
        haiku (5-30s typical, 60s+ for cold model load) so we allow
        plenty of headroom. The bridge falls through to a raw-context
        Gotify push if the timeout fires.
      '';
    };

    gotifyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://gotify.ablz.au";
      description = "Base URL of the Gotify server (no trailing slash).";
    };

    lokiUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:3100";
      description = "Loki HTTP endpoint for re-querying log lines.";
    };

    gotifyTokenSopsFile = lib.mkOption {
      type = lib.types.path;
      default = config.homelab.secrets.sopsFile "gotify.env";
      description = ''
        Sops file containing GOTIFY_TOKEN. Defaults to the shared agent
        Gotify app — same token the existing alerting prestart uses, just
        decrypted under a different owner (the bridge user).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    sops.secrets."alert-bridge/gotify-token" = {
      sopsFile = cfg.gotifyTokenSopsFile;
      format = "dotenv";
      key = "GOTIFY_TOKEN";
      owner = cfg.user;
      mode = "0400";
    };

    systemd.services.alert-bridge = {
      description = "Grafana → claude -p → Gotify alert-summary bridge";
      after = ["network-online.target" "sops-install-secrets.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        GOTIFY_URL = cfg.gotifyUrl;
        GOTIFY_TOKEN_FILE = config.sops.secrets."alert-bridge/gotify-token".path;
        LOKI_URL = cfg.lokiUrl;
        CLAUDE_BIN = "${pkgs.claude-code}/bin/claude";
        CLAUDE_MODEL = cfg.model;
        CLAUDE_TIMEOUT_SECS = toString cfg.claudeTimeoutSecs;
        LISTEN_PORT = toString cfg.listenPort;
        SYSTEM_PROMPT = systemPrompt;
      };

      serviceConfig = {
        User = cfg.user;
        Group = "users";
        ExecStart = bridgeScript;
        Restart = "on-failure";
        RestartSec = "5s";
        # Don't sandbox heavily — claude needs to read ~/.claude and the
        # internet. Minimal hardening only.
        NoNewPrivileges = true;
        PrivateTmp = true;
      };
    };
  };
}
