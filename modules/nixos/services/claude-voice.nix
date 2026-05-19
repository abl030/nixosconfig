{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.claude-voice;

  pythonEnv = pkgs.python3.withPackages (ps: [ps.aiohttp]);

  serviceScript = pkgs.writeText "claude-voice.py" ''
    #!/usr/bin/env python3
    """Claude transcript SSE bridge.

    Tails a Claude Code session's JSONL transcript, filters to assistant text,
    emits each text block as a Server-Sent Event so a phone-side TTS client
    can speak the conversation aloud.

    Endpoints:
      POST /register   {"project": "/home/.../claude/projects/<encoded-cwd>"}
                       → tail the most-recently-modified .jsonl in that dir.
                         /clear in claude makes a new file appear and we
                         switch to it automatically.
      POST /unregister → stop tailing.
      GET  /stream     → SSE; one "speak" event per assistant text block.
                         No backlog: subscribers see only events emitted
                         after they connected.
      GET  /healthz    → liveness + current state.
    """

    import argparse
    import asyncio
    import json
    import logging
    import re
    from pathlib import Path

    from aiohttp import web

    log = logging.getLogger("claude-voice")

    state = {
        "project_dir": None,
        "current_file": None,
        "current_pos": 0,
        "subscribers": set(),
    }

    CODE_FENCE = re.compile(r"```.*?```", re.DOTALL)
    INLINE_CODE = re.compile(r"`([^`]+)`")
    BOLD = re.compile(r"\*\*([^*]+)\*\*")
    ITALIC = re.compile(r"(?<!\*)\*([^*]+)\*(?!\*)")
    LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
    HEADING = re.compile(r"^#+\s+", re.MULTILINE)
    BULLET = re.compile(r"^\s*[-*]\s+", re.MULTILINE)
    NUMBERED = re.compile(r"^\s*\d+\.\s+", re.MULTILINE)


    def speakable(text: str) -> str:
        text = CODE_FENCE.sub("", text)
        text = INLINE_CODE.sub(r"\1", text)
        text = BOLD.sub(r"\1", text)
        text = ITALIC.sub(r"\1", text)
        text = LINK.sub(r"\1", text)
        text = HEADING.sub("", text)
        text = BULLET.sub("", text)
        text = NUMBERED.sub("", text)
        text = re.sub(r"\n{2,}", "\n", text).strip()
        return text


    def extract_assistant_text(line: str):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return []
        if obj.get("type") != "assistant":
            return []
        msg = obj.get("message") or {}
        content = msg.get("content") or []
        if isinstance(content, str):
            cleaned = speakable(content)
            return [cleaned] if cleaned else []
        out = []
        for block in content:
            if not isinstance(block, dict):
                continue
            if block.get("type") != "text":
                continue
            cleaned = speakable(block.get("text") or "")
            if cleaned:
                out.append(cleaned)
        return out


    def pick_active_jsonl(project_dir):
        if not project_dir or not project_dir.exists():
            return None
        candidates = list(project_dir.glob("*.jsonl"))
        if not candidates:
            return None
        return max(candidates, key=lambda p: p.stat().st_mtime)


    async def broadcast(text):
        payload = json.dumps({"text": text})
        for q in list(state["subscribers"]):
            try:
                q.put_nowait(payload)
            except asyncio.QueueFull:
                log.warning("subscriber queue full, dropping event")


    async def tail_loop():
        while True:
            project = state["project_dir"]
            if project is None:
                await asyncio.sleep(0.5)
                continue
            active = pick_active_jsonl(project)
            if active is None:
                await asyncio.sleep(0.5)
                continue
            if state["current_file"] != active:
                log.info("now tailing %s", active)
                state["current_file"] = active
                try:
                    state["current_pos"] = active.stat().st_size
                except FileNotFoundError:
                    state["current_pos"] = 0
                    continue
            try:
                size = active.stat().st_size
            except FileNotFoundError:
                await asyncio.sleep(0.2)
                continue
            if size < state["current_pos"]:
                state["current_pos"] = 0
            if size == state["current_pos"]:
                await asyncio.sleep(0.2)
                continue
            try:
                with active.open("rb") as f:
                    f.seek(state["current_pos"])
                    new_data = f.read()
                    state["current_pos"] = f.tell()
            except FileNotFoundError:
                await asyncio.sleep(0.2)
                continue
            text = new_data.decode("utf-8", errors="replace")
            lines = text.split("\n")
            if not text.endswith("\n") and lines:
                partial = lines.pop()
                state["current_pos"] -= len(partial.encode("utf-8"))
            for line in lines:
                if not line.strip():
                    continue
                for spoken in extract_assistant_text(line):
                    await broadcast(spoken)


    async def handle_register(request):
        body = await request.json()
        project_str = body.get("project")
        if not project_str:
            return web.json_response({"error": "missing 'project'"}, status=400)
        project = Path(project_str).resolve()
        if not project.is_dir():
            return web.json_response({"error": f"not a directory: {project}"}, status=400)
        state["project_dir"] = project
        state["current_file"] = None
        state["current_pos"] = 0
        log.info("registered project dir: %s", project)
        return web.json_response({"ok": True, "project": str(project)})


    async def handle_unregister(request):
        state["project_dir"] = None
        state["current_file"] = None
        state["current_pos"] = 0
        log.info("unregistered")
        return web.json_response({"ok": True})


    async def handle_stream(request):
        resp = web.StreamResponse(status=200, headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        })
        await resp.prepare(request)
        queue = asyncio.Queue(maxsize=100)
        state["subscribers"].add(queue)
        log.info("subscriber connected (total %d)", len(state["subscribers"]))
        try:
            await resp.write(b": connected\n\n")
            while True:
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=15)
                except asyncio.TimeoutError:
                    await resp.write(b": keepalive\n\n")
                    continue
                data = f"event: speak\ndata: {payload}\n\n".encode("utf-8")
                await resp.write(data)
        except (asyncio.CancelledError, ConnectionResetError):
            pass
        finally:
            state["subscribers"].discard(queue)
            log.info("subscriber gone (total %d)", len(state["subscribers"]))
        return resp


    async def handle_healthz(request):
        return web.json_response({
            "ok": True,
            "project_dir": str(state["project_dir"]) if state["project_dir"] else None,
            "current_file": str(state["current_file"]) if state["current_file"] else None,
            "subscribers": len(state["subscribers"]),
        })


    def make_app():
        app = web.Application()
        app.router.add_post("/register", handle_register)
        app.router.add_post("/unregister", handle_unregister)
        app.router.add_get("/stream", handle_stream)
        app.router.add_get("/healthz", handle_healthz)
        return app


    async def main(host, port):
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s %(levelname)s %(name)s %(message)s",
        )
        app = make_app()
        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, host, port)
        await site.start()
        log.info("listening on %s:%d", host, port)
        tail_task = asyncio.create_task(tail_loop())
        try:
            await asyncio.Future()
        finally:
            tail_task.cancel()
            await runner.cleanup()


    if __name__ == "__main__":
        parser = argparse.ArgumentParser()
        parser.add_argument("--host", default="127.0.0.1")
        parser.add_argument("--port", type=int, default=8765)
        args = parser.parse_args()
        asyncio.run(main(args.host, args.port))
  '';
in {
  options.homelab.services.claude-voice = {
    enable = lib.mkEnableOption "Claude transcript SSE bridge for phone-side TTS";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8765;
      description = "Localhost port for the SSE service.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "voice.ablz.au";
      description = ''
        Tailnet-only FQDN proxied to this service. Must be in your
        Cloudflare zone; the Cloudflare A record is created/updated
        automatically by homelab.localProxy and points at the host's
        Tailscale IP (not the LAN IP). Anyone outside the tailnet who
        resolves this name gets a 100.x.x.x address they can't route to.
      '';
    };

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        User the service runs as. Must be able to read
        ~/.claude/projects/ for that user — the JSONL transcripts we
        tail live there.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.claude-voice = {
      description = "Claude transcript SSE bridge for phone TTS";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        ExecStart = "${pythonEnv}/bin/python3 ${serviceScript} --host 127.0.0.1 --port ${toString cfg.port}";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = "5s";

        # Read-only access to the user's home is enough — the service only
        # reads JSONL transcripts. No writes anywhere except sockets.
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        RestrictRealtime = true;
        MemoryDenyWriteExecute = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = ["@system-service" "~@privileged" "~@resources"];
        RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
      };
    };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = cfg.port;
        tailscaleOnly = true;
      }
    ];

    homelab.monitoring.monitors = [
      {
        name = "Claude Voice (Tailnet)";
        url = "https://${cfg.fqdn}/healthz";
      }
    ];
  };
}
