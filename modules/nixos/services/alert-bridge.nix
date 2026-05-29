# Grafana + Kuma → claude -p → Gotify webhook bridge.
# See docs/wiki/services/lgtm-stack.md "alert-bridge" for the why,
# the per-alert flow, the payload-shape detection logic (Grafana vs
# Kuma), and the auth/group gotchas (#251 + #256).
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
# Grafana/Prometheus "resolved" alerts are skipped, but Kuma DOWN→UP
# recoveries DO send a plain "[recovered] … is UP" Gotify ping (no Claude) —
# the "you can stop worrying" signal.
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
    You are summarising a homelab alert for an operator reading it on a
    phone push notification. Be terse. Output plain text only, no markdown.

    Input is one of:
    - Grafana alert: "## Alert metadata" + optional "## Matching log lines"
    - Kuma DOWN: "## Kuma monitor DOWN" with monitor + heartbeat fields,
      and (for push-type monitors) "## Recent journal for <unit>" with
      the failing probe's stdout/stderr.

    Output format — exactly 2 or 3 lines, total under 300 characters:
    Line 1 (required): <emoji> <one-line: who/what/where>
    Line 2 (required): <classification>: <one-line reasoning>
    Line 3 (optional): Next: <one-line action>, or omit if no action needed.

    Emoji rule: critical=🔴, warning=🟡, info=ℹ️
    Classifications:
    - DB DDL alerts: EXPECTED (operator session), DRIFT (matches incident
      patterns), or UNKNOWN.
    - Kuma DOWN: read the journal lines if present; classify the
      underlying failure (e.g. "permission denied for table" = drift
      regression, network/DNS issues = upstream, "command exited N" =
      probe internal).
    - Other alerts: pick the natural classification.

    Do not output anything else. No prefatory text, no closing remarks,
    no "I'll analyse...", no bullet points, no JSON.
  '';

  bridgeScript = pkgs.writers.writePython3 "alert-bridge" {flakeIgnore = ["E501" "W293" "E302" "E305" "E402" "E741" "W391" "E401" "E231"];} ''
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

    # Mirror of the probeSlug helper in monitoring_sync.nix so we can
    # reverse a Kuma push-monitor name back to its systemd unit. Must
    # stay in sync with the Nix-side function.
    _PROBE_SLUG_REPLACEMENTS = [
        ("/", "-"), (" ", "-"), ("(", ""), (")", ""),
        ("—", "-"), ("[", ""), ("]", ""),
    ]

    def probe_slug(name):
        s = name.lower()
        for src, dst in _PROBE_SLUG_REPLACEMENTS:
            s = s.replace(src, dst)
        return s

    def fetch_journal(unit, since_minutes=15, limit=30):
        """Return recent journal lines for a systemd unit. Empty list on
        error; we still want to push the alert even without journal
        context."""
        try:
            result = subprocess.run(
                ["journalctl", "-u", unit, "--no-pager",
                 "--since", f"{since_minutes} min ago",
                 "-n", str(limit), "-o", "short"],
                capture_output=True, text=True, timeout=15,
            )
            if result.returncode != 0:
                print(f"[bridge] journalctl rc={result.returncode} for {unit}: "
                      f"{result.stderr[:200]}", file=sys.stderr, flush=True)
                return []
            return [ln for ln in result.stdout.splitlines() if ln.strip()][-limit:]
        except Exception as e:
            print(f"[bridge] journalctl exception for {unit}: {e}",
                  file=sys.stderr, flush=True)
            return []

    def handle_kuma_alert(data):
        """Kuma webhook payload — push-monitor or HTTP-monitor down/up.
        See docs/wiki/services/lgtm-stack.md for the alert-bridge flow."""
        heartbeat = data.get("heartbeat") or {}
        monitor = data.get("monitor") or {}
        msg = data.get("msg", "")

        mon_name = monitor.get("name", "?")
        mon_type = monitor.get("type", "?")
        mon_url = monitor.get("url", "")
        # heartbeat.status: 0=DOWN, 1=UP, 2=PENDING, 3=MAINTENANCE
        status_code = heartbeat.get("status")
        status_str = {0: "DOWN", 1: "UP", 2: "PENDING", 3: "MAINTENANCE"}.get(
            status_code, f"status={status_code}")
        heartbeat_msg = heartbeat.get("msg", "")
        ping = heartbeat.get("ping")
        hb_time = heartbeat.get("time", "")

        # Recovery (UP, status 1): send a plain "back online" ping directly —
        # NO Claude summarisation (that would be silly for a recovery), just a
        # templated Gotify push so the user gets the "you can stop worrying,
        # it's resolved" signal. Lower priority than the critical DOWN page.
        # Kuma only fires UP on a real DOWN→UP transition, so this won't spam.
        if status_code == 1:
            print(f"[bridge] kuma recovery: {mon_name} UP",
                  file=sys.stderr, flush=True)
            body = "✅ back online"
            if ping is not None:
                body += f" · ping {ping}ms"
            if hb_time:
                body += f"\nat {hb_time}"
            if heartbeat_msg:
                body += f"\n{heartbeat_msg[:300]}"
            gotify_push(f"[recovered] {mon_name} is UP", body, priority=5)
            return

        # Anything else that isn't DOWN (PENDING / MAINTENANCE / unknown) → ignore.
        if status_code != 0:
            print(f"[bridge] kuma alert ignored ({status_str}): {mon_name}",
                  file=sys.stderr, flush=True)
            return

        print(f"[bridge] kuma alert: {mon_name} type={mon_type} {status_str}",
              file=sys.stderr, flush=True)

        ctx = "## Kuma monitor DOWN\n"
        ctx += f"monitor: {mon_name}\n"
        ctx += f"type: {mon_type}\n"
        if mon_url:
            ctx += f"url: {mon_url}\n"
        ctx += f"status: {status_str}\n"
        if hb_time:
            ctx += f"failedAt: {hb_time}\n"
        if ping is not None:
            ctx += f"ping_ms: {ping}\n"
        if heartbeat_msg:
            ctx += f"heartbeat_msg: {heartbeat_msg[:500]}\n"
        if msg:
            ctx += f"kuma_msg: {msg[:500]}\n"

        # Push-monitor → enrich with the corresponding deep-probe
        # oneshot's recent journal. Convention: monitor name maps to
        # `deep-probe-<slug>.service` via the same probeSlug helper
        # monitoring_sync.nix uses.
        if mon_type == "push":
            slug = probe_slug(mon_name)
            unit = f"deep-probe-{slug}.service"
            lines = fetch_journal(unit, since_minutes=20, limit=40)
            if lines:
                ctx += f"\n## Recent journal for {unit} (last 40 lines, 20m window)\n"
                ctx += "\n".join(line[:400] for line in lines) + "\n"
            else:
                ctx += f"\n## (no journal lines found for {unit})\n"

        summary = claude_summarise(ctx)
        title = f"[critical] {mon_name} DOWN"
        gotify_push(title, summary, priority=8)

    def handle_alert(alert):
        if alert.get("status") != "firing":
            return
        fp = alert.get("fingerprint", "?")
        labels = alert.get("labels", {})
        print(f"[bridge] handle fp={fp} name={labels.get('alertname','?')} "
              f"has_loki_lines={bool(labels.get('loki_lines'))} "
              f"has_loki_query={bool(labels.get('loki_query'))}",
              file=sys.stderr, flush=True)
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
                # Detect payload shape:
                #   Grafana → has "alerts": [...]
                #   Kuma    → has "heartbeat" + "monitor" at top level
                if "alerts" in data:
                    alerts = data.get("alerts", [])
                    firing = [a for a in alerts if a.get("status") == "firing"]
                    print(f"[bridge] POST received (grafana): {len(alerts)} alerts ({len(firing)} firing)",
                          file=sys.stderr, flush=True)
                    for a in alerts:
                        fp = a.get("fingerprint", "?")
                        name = a.get("labels", {}).get("alertname", "?")
                        status = a.get("status", "?")
                        starts = a.get("startsAt", "?")
                        print(f"[bridge]   alert fp={fp} name={name} status={status} startsAt={starts}",
                              file=sys.stderr, flush=True)
                    for alert in alerts:
                        handle_alert(alert)
                elif "heartbeat" in data or "monitor" in data:
                    print(f"[bridge] POST received (kuma): monitor={data.get('monitor',{}).get('name','?')}",
                          file=sys.stderr, flush=True)
                    handle_kuma_alert(data)
                else:
                    print(f"[bridge] POST received: unknown payload shape — keys={list(data.keys())[:10]}",
                          file=sys.stderr, flush=True)
            except Exception as e:
                print(f"[bridge] handler error: {e}", file=sys.stderr, flush=True)
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
        # systemd-journal membership lets the bridge run `journalctl -u
        # deep-probe-<slug>.service` to fetch context for Kuma DOWN
        # alerts (#256). Without it, journalctl prints "No journal files
        # were opened" and the alert lands without journal context.
        SupplementaryGroups = ["systemd-journal"];
        # journalctl needs to be on PATH for fetch_journal in the script.
        Environment = ["PATH=${pkgs.systemd}/bin"];
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
