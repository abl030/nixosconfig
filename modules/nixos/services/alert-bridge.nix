# Grafana + Kuma → Gotify webhook bridge (raw passthrough).
# See docs/wiki/services/lgtm-stack.md "alert-bridge" for the why,
# the per-alert flow, the payload-shape detection logic (Grafana vs
# Kuma), and the auth/group gotchas (#251 + #256).
#
# Inserts itself between Grafana/Kuma alerting and Gotify to translate the
# verbose webhook payloads into a phone-readable push. It re-queries Loki for
# the actual matching log lines and (for Kuma push monitors) fetches the
# failing probe's journal, then POSTs that context block to Gotify verbatim.
#
# History: this used to pipe the context through `claude -p --model haiku` to
# collapse it to a 2-3 line summary. Removed 2026-06-22 — the summaries were
# rarely read, and the claude OAuth token on the run-host expired silently and
# rotted the enrichment for a week (the bridge fell back to raw anyway). Raw
# text is the contract now: no LLM in the alert path.
#
# Flow per alert (status=firing):
#   1. Bridge receives Grafana webhook JSON on 127.0.0.1:<port>/alert
#   2. If labels.loki_query is set, bridge re-queries Loki for the actual
#      matching lines (last 10 over a 10m window)
#   3. Composes a context block: alert metadata + log lines
#   4. POSTs that context (truncated) to Gotify with severity-aware priority
#
# Grafana/Prometheus "resolved" alerts are skipped, but Kuma DOWN→UP
# recoveries DO send a plain "[recovered] … is UP" Gotify ping —
# the "you can stop worrying" signal.
#
# Runs as the abl030 user (historical; it has systemd-journal access and the
# decrypted Gotify token). No longer needs ~/.claude.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.alertBridge;

  bridgeScript = pkgs.writers.writePython3 "alert-bridge" {flakeIgnore = ["E501" "W293" "E302" "E305" "E402" "E741" "W391" "E401" "E231"];} ''
    import http.server
    import json
    import os
    import subprocess
    import sys
    import threading
    import time
    import urllib.parse
    import urllib.request

    GOTIFY_URL = os.environ["GOTIFY_URL"]
    GOTIFY_TOKEN_FILE = os.environ["GOTIFY_TOKEN_FILE"]
    LOKI_URL = os.environ.get("LOKI_URL", "http://127.0.0.1:3100")
    LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "9876"))
    MAX_MSG_CHARS = int(os.environ.get("MAX_MSG_CHARS", "1400"))

    # Storm damper knobs. When many pages fire at once (one root cause → N distal
    # symptom alerts — the 2026-06-25 prom-disk cascade was ~50 pings), coalesce
    # the flood into a single digest instead of paging each. Root-cause-agnostic:
    # it keys off page RATE, not any specific signature, so it catches the next
    # storm too (network blip, OOM, wedged mount — whatever).
    STORM_WINDOW_SECS = int(os.environ.get("STORM_WINDOW_SECS", "300"))
    STORM_THRESHOLD = int(os.environ.get("STORM_THRESHOLD", "6"))
    STORM_FLUSH_SECS = int(os.environ.get("STORM_FLUSH_SECS", "120"))
    STORM_QUIET_SECS = int(os.environ.get("STORM_QUIET_SECS", "180"))
    RCA_BATCH_SECS = int(os.environ.get("RCA_BATCH_SECS", "600"))

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

    def format_message(context):
        # Raw passthrough: the composed context block IS the message. Strip the
        # "## " markdown headers for phone readability and cap the length so the
        # push stays scannable. No LLM in the path (removed 2026-06-22).
        text = "\n".join(
            line[3:] if line.startswith("## ") else line
            for line in context.strip().splitlines()
        )
        if len(text) > MAX_MSG_CHARS:
            text = text[:MAX_MSG_CHARS].rstrip() + "\n…(truncated)"
        return text

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

    # ---- RCA forward -------------------------------------------------------
    # Forward the enriched alert context to Hermes for automated RCA.
    # Best-effort: failures here don't affect the Gotify push path.
    # Auth: X-Gitlab-Token header (plain secret match) — simplest scheme
    # the Hermes webhook platform supports without computing HMAC.
    RCA_WEBHOOK_URL = os.environ.get("RCA_WEBHOOK_URL")
    RCA_WEBHOOK_SECRET = os.environ.get("RCA_WEBHOOK_SECRET", "")

    def rca_forward(title, message, priority=5):
        if not RCA_WEBHOOK_URL:
            return
        payload = json.dumps({
            "title": title,
            "message": message,
            "priority": priority,
        }).encode()
        req = urllib.request.Request(
            RCA_WEBHOOK_URL,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "X-Gitlab-Token": RCA_WEBHOOK_SECRET,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp.read()
        except Exception as e:
            print(f"[bridge] rca forward failed: {e}", file=sys.stderr)

    # ---- RCA batching ------------------------------------------------------
    # RCA is LLM-backed and expensive; alert storms usually share one root cause.
    # Every alert is queued into a rolling batch and a daemon flushes one Hermes
    # prompt per RCA_BATCH_SECS. Gotify paging remains immediate/storm-damped;
    # only the agent investigation is delayed/coalesced.
    _rca_lock = threading.Lock()
    _rca_batch = []  # (ts, title, priority, message)

    def rca_enqueue(title, message, priority=5):
        if not RCA_WEBHOOK_URL:
            return
        now = time.time()
        with _rca_lock:
            _rca_batch.append((now, title, priority, message))
            print(f"[bridge] rca queued: batch_size={len(_rca_batch)} title={title}",
                  file=sys.stderr, flush=True)

    def _format_rca_batch(items):
        n = len(items)
        crit = sum(1 for (_ts, _t, p, _m) in items if p >= 8)
        window_start = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(items[0][0]))
        window_end = time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(items[-1][0]))
        suffix = "s" if n != 1 else ""
        title = f"Alert batch: {n} alert{suffix} in {RCA_BATCH_SECS // 60}m ({crit} critical)"
        lines = [
            "Alert batch for RCA",
            f"count: {n}",
            f"critical: {crit}",
            f"window_start: {window_start}",
            f"window_end: {window_end}",
            "",
            "Alerts:",
        ]
        for idx, (_ts, t, p, m) in enumerate(items[:50], start=1):
            lines.append(f"\n--- alert {idx}/{n} priority={p} title={t}")
            msg = (m or "").strip()
            if len(msg) > 1800:
                msg = msg[:1800].rstrip() + "\n…(alert message truncated)"
            lines.append(msg)
        if n > 50:
            lines.append(f"\n…{n - 50} additional alerts omitted from prompt; inspect alert-bridge logs/Grafana if needed.")
        return title, "\n".join(lines), 8 if crit else 5

    def _rca_batch_flusher():
        while True:
            time.sleep(5)
            items = None
            with _rca_lock:
                if _rca_batch and time.time() - _rca_batch[0][0] >= RCA_BATCH_SECS:
                    items = list(_rca_batch)
                    _rca_batch.clear()
            if items:
                title, message, priority = _format_rca_batch(items)
                print(f"[bridge] rca batch flush: {len(items)} alerts",
                      file=sys.stderr, flush=True)
                rca_forward(title, message, priority)

    # ---- Storm damper -------------------------------------------------------
    # Every outgoing page flows through dispatch(). It counts pages in a rolling
    # window; once more than STORM_THRESHOLD fire within STORM_WINDOW_SECS it
    # flips to "storm" mode and HOLDS subsequent pages in a buffer, emitting one
    # coalesced digest (rolling, at most every STORM_FLUSH_SECS) that lists the
    # held alerts. A daemon thread flushes the tail and ends the storm after
    # STORM_QUIET_SECS with no new pages. Nothing is dropped — the flood becomes
    # a handful of digests, not 50 pushes. The digest calls gotify_push directly
    # so it neither recurses nor counts toward the storm. Boxed single-element
    # lists hold the mutable flags so the module-level helpers avoid `global`.
    _storm_lock = threading.Lock()
    _storm_recent = []        # dispatch timestamps within the window
    _storm_buffer = []        # held (ts, title, priority) during a storm
    _storm_active = [False]
    _storm_last_digest = [0.0]

    def _storm_prune(now):
        cutoff = now - STORM_WINDOW_SECS
        while _storm_recent and _storm_recent[0] < cutoff:
            _storm_recent.pop(0)

    def _push_digest(items):
        if not items:
            return
        n = len(items)
        crit = sum(1 for it in items if it[2] >= 8)
        lines = [f"{n} alerts coalesced in the last few minutes ({crit} critical):"]
        for (_ts, t, p) in items[:30]:
            lines.append(f"{'🔴' if p >= 8 else '🟡'} {t}")
        if n > 30:
            lines.append(f"…and {n - 30} more")
        lines.append("")
        lines.append("(individual pages held by the storm damper — likely one root")
        lines.append("cause. Check Grafana/Loki for the common failure.)")
        gotify_push(f"⚡ Alert storm: {n} alerts", "\n".join(lines), priority=8)

    def dispatch(title, message, priority=5):
        """Single choke point for every outgoing page; applies the storm damper."""
        now = time.time()
        send = None
        digest = None
        rca_enqueue(title, message, priority)
        with _storm_lock:
            _storm_recent.append(now)
            _storm_prune(now)
            if not _storm_active[0] and len(_storm_recent) >= STORM_THRESHOLD:
                _storm_active[0] = True
                _storm_last_digest[0] = now
                print(f"[bridge] STORM start: {len(_storm_recent)} pages in "
                      f"{STORM_WINDOW_SECS}s — coalescing", file=sys.stderr, flush=True)
            if _storm_active[0]:
                _storm_buffer.append((now, title, priority))
                if now - _storm_last_digest[0] >= STORM_FLUSH_SECS:
                    digest = list(_storm_buffer)
                    _storm_buffer.clear()
                    _storm_last_digest[0] = now
            else:
                send = (title, message, priority)
        # Network I/O outside the lock so the flusher thread never blocks on it.
        if send is not None:
            gotify_push(*send)
        if digest is not None:
            _push_digest(digest)

    def _storm_flusher():
        """Flush the storm tail: end the storm and emit a final digest once no
        new pages have arrived for STORM_QUIET_SECS (also emits a rolling digest
        if a long storm crosses STORM_FLUSH_SECS between dispatches)."""
        while True:
            time.sleep(15)
            now = time.time()
            digest = None
            with _storm_lock:
                _storm_prune(now)
                if _storm_active[0]:
                    last = _storm_recent[-1] if _storm_recent else 0
                    if now - last >= STORM_QUIET_SECS:
                        if _storm_buffer:
                            digest = list(_storm_buffer)
                            _storm_buffer.clear()
                        _storm_active[0] = False
                        print("[bridge] STORM end — flushing tail",
                              file=sys.stderr, flush=True)
                    elif _storm_buffer and now - _storm_last_digest[0] >= STORM_FLUSH_SECS:
                        digest = list(_storm_buffer)
                        _storm_buffer.clear()
                        _storm_last_digest[0] = now
            if digest:
                _push_digest(digest)

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

        # Recovery (UP, status 1): send a plain "back online" ping — a
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
            dispatch(f"[recovered] {mon_name} is UP", body, priority=5)
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

        summary = format_message(ctx)
        title = f"[critical] {mon_name} DOWN"
        dispatch(title, summary, priority=8)

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

        summary = format_message(ctx)
        title = f"[{severity}] {alertname}"
        priority = 8 if severity == "critical" else 5
        dispatch(title, summary, priority=priority)

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
        threading.Thread(target=_storm_flusher, daemon=True).start()
        threading.Thread(target=_rca_batch_flusher, daemon=True).start()
        http.server.HTTPServer(("127.0.0.1", LISTEN_PORT), Handler).serve_forever()
  '';
in {
  options.homelab.services.alertBridge = {
    enable = lib.mkEnableOption "Grafana/Kuma → Gotify webhook bridge (raw passthrough)";

    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 9876;
      description = "TCP port the bridge listens on (127.0.0.1 only).";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "abl030";
      description = ''
        User to run the bridge as. Needs systemd-journal group membership
        (Kuma push-monitor journal context) and read access to the decrypted
        Gotify token. No claude/~/.claude requirement (removed 2026-06-22).
      '';
    };

    gotifyUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://gotify.ablz.au";
      description = "Base URL of the Gotify server (no trailing slash).";
    };

    rcaWebhookUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Hermes webhook URL to forward enriched alert context for RCA.
        When set, the bridge POSTs the alert (title, message, priority)
        to this URL in addition to pushing to Gotify. The Hermes agent
        on the receiving end runs the alert-rca skill.
        Set to null to disable RCA forwarding.
      '';
    };

    rcaWebhookSecret = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Shared secret for the RCA webhook URL. Sent as X-Gitlab-Token
        header (plain secret match — simplest Hermes webhook auth).
        Required when rcaWebhookUrl is set.
      '';
    };

    rcaBatchSecs = lib.mkOption {
      type = lib.types.int;
      default = 600;
      description = ''
        Seconds to coalesce alerts before forwarding one batched prompt to
        Hermes for RCA. Gotify notifications still flow through the immediate
        alert/storm-damper path; this only controls LLM-backed investigation.
      '';
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

    # Storm damper — collapse an alert flood (one root cause → N distal symptom
    # pages) into a single coalesced digest. Root-cause-agnostic (keys off page
    # rate). See the script's "Storm damper" block.
    stormThreshold = lib.mkOption {
      type = lib.types.int;
      default = 6;
      description = "More than this many pages within stormWindowSecs flips the bridge into storm mode (subsequent pages coalesced into a digest).";
    };
    stormWindowSecs = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Rolling window (seconds) over which outgoing pages are counted against stormThreshold.";
    };
    stormFlushSecs = lib.mkOption {
      type = lib.types.int;
      default = 120;
      description = "During a storm, emit a rolling digest of held alerts at most this often (seconds).";
    };
    stormQuietSecs = lib.mkOption {
      type = lib.types.int;
      default = 180;
      description = "A storm ends (final digest flushed) after this many seconds with no new pages.";
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
      description = "Grafana/Kuma → Gotify alert bridge (raw passthrough)";
      after = ["network-online.target" "sops-install-secrets.service"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];

      environment = {
        GOTIFY_URL = cfg.gotifyUrl;
        GOTIFY_TOKEN_FILE = config.sops.secrets."alert-bridge/gotify-token".path;
        LOKI_URL = cfg.lokiUrl;
        LISTEN_PORT = toString cfg.listenPort;
        STORM_THRESHOLD = toString cfg.stormThreshold;
        STORM_WINDOW_SECS = toString cfg.stormWindowSecs;
        STORM_FLUSH_SECS = toString cfg.stormFlushSecs;
        STORM_QUIET_SECS = toString cfg.stormQuietSecs;
        RCA_BATCH_SECS = toString cfg.rcaBatchSecs;
      } // lib.optionalAttrs (cfg.rcaWebhookUrl != null) {
        RCA_WEBHOOK_URL = cfg.rcaWebhookUrl;
      } // lib.optionalAttrs (cfg.rcaWebhookSecret != null) {
        RCA_WEBHOOK_SECRET = cfg.rcaWebhookSecret;
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
        # Light hardening. The bridge only queries Loki over HTTP, runs
        # journalctl, and POSTs to Gotify — no home/secrets beyond the token.
        NoNewPrivileges = true;
        PrivateTmp = true;
        # #257: the bridge needs nothing on /mnt, so blank the tree it was
        # needlessly inheriting.
        TemporaryFileSystem = "/mnt";
      };
    };
  };
}
