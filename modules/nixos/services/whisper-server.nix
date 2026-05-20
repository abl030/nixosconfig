# Self-hosted whisper.cpp transcription server with an OpenAI-compatible HTTP
# endpoint, so phone keyboards (Dictate, etc.) and any other OpenAI Whisper
# client can send audio to this tailnet host instead of Groq/OpenAI.
#
# whisper.cpp 1.8.3+ ships a Vulkan backend; on the igpu VM with AMD iGPU
# passthrough we get GPU-accelerated inference without CUDA. faster-whisper /
# CTranslate2 don't have a ROCm or Vulkan backend, which is why whisper.cpp
# wins this matchup on our hardware. See:
# https://github.com/ggerganov/whisper.cpp
# https://www.phoronix.com/news/Whisper-cpp-1.8.3-12x-Perf
#
# Multi-model design (added 2026-05-20). whisper-server itself loads one model
# at startup; per-request switching would force a reload from disk and burn
# 1–2 s of latency every other call. Instead we run one whisper-server
# instance per ggml model on consecutive localhost ports, and a tiny Python
# dispatcher peeks at the multipart `model` form field and forwards to the
# matching backend. Dictate's "custom server" provider sends whatever string
# the user types in the model field, so switching models in the app is just
# changing one word (e.g. `small` / `medium` / `large`).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.whisper-server;

  modelNames = lib.attrNames cfg.models; # alphabetical, stable
  modelFile = name: "${cfg.dataDir}/models/ggml-${cfg.models.${name}}.bin";

  # Port layout: dispatcher on cfg.port, backends on cfg.port + 1 + i.
  backendPort = name: cfg.port + 1 + (lib.lists.findFirstIndex (n: n == name) null modelNames);

  backendsEnv = lib.concatStringsSep "," (map (n: "${n}=http://127.0.0.1:${toString (backendPort n)}") modelNames);

  dispatcher = pkgs.writers.writePython3Bin "whisper-dispatcher" {
    flakeIgnore = ["E501" "E402"];
  } ''
    """Whisper multi-model dispatcher.

    Reads the `model` multipart form field on incoming POSTs to
    /v1/audio/transcriptions and forwards the request unchanged to the
    backend whisper-server instance that has that model loaded. Falls back
    to WHISPER_DEFAULT when the field is missing or unknown.

    Environment:
      WHISPER_BACKENDS  comma-separated name=url pairs
      WHISPER_DEFAULT   name of the default backend (must appear in BACKENDS)
      HOST, PORT        listen address (default 127.0.0.1:9875)
    """
    import os
    import sys
    import urllib.request
    import urllib.error
    from http.server import HTTPServer, BaseHTTPRequestHandler
    from socketserver import ThreadingMixIn

    BACKENDS: dict[str, str] = {}
    DEFAULT_BACKEND: str | None = None

    HOP_HEADERS = {"connection", "transfer-encoding", "content-length", "host", "expect"}


    def parse_model_field(body: bytes, content_type: str) -> str | None:
        if "multipart/form-data" not in content_type.lower():
            return None
        boundary = None
        for part in content_type.split(";"):
            part = part.strip()
            if part.lower().startswith("boundary="):
                boundary = part[len("boundary="):].strip().strip('"')
                break
        if not boundary:
            return None
        sep = b"--" + boundary.encode()
        for chunk in body.split(sep):
            if b'name="model"' not in chunk:
                continue
            i = chunk.find(b"\r\n\r\n")
            if i < 0:
                return None
            value = chunk[i + 4:]
            # Trim trailing CRLF and any boundary suffix dashes.
            value = value.rstrip(b"-").rstrip(b"\r\n")
            try:
                return value.decode("utf-8").strip()
            except UnicodeDecodeError:
                return None
        return None


    class Handler(BaseHTTPRequestHandler):
        server_version = "whisper-dispatcher/1"

        def log_message(self, fmt, *args):
            sys.stderr.write("dispatcher: " + (fmt % args) + "\n")

        def do_GET(self):  # noqa: N802 (stdlib signature)
            self._proxy("GET", b"")

        def do_POST(self):  # noqa: N802
            length = int(self.headers.get("content-length", "0") or "0")
            body = self.rfile.read(length) if length > 0 else b""
            self._proxy("POST", body)

        def _proxy(self, method: str, body: bytes) -> None:
            ctype = self.headers.get("content-type", "")
            model = parse_model_field(body, ctype) if body else None
            backend = BACKENDS.get(model) if model else None
            picked = model if backend else "default"
            if backend is None:
                backend = DEFAULT_BACKEND
            if backend is None:
                self.send_error(503, "no backends configured")
                return
            target = backend.rstrip("/") + self.path
            req = urllib.request.Request(target, data=body if body else None, method=method)
            for k, v in self.headers.items():
                if k.lower() in HOP_HEADERS:
                    continue
                req.add_header(k, v)
            if body:
                req.add_header("content-length", str(len(body)))
            sys.stderr.write(f"dispatcher: {method} {self.path} model={model!r} backend={picked} -> {target}\n")
            try:
                with urllib.request.urlopen(req, timeout=600) as up:
                    payload = up.read()
                    self.send_response(up.status)
                    for k, v in up.headers.items():
                        if k.lower() in HOP_HEADERS:
                            continue
                        self.send_header(k, v)
                    self.send_header("content-length", str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
            except urllib.error.HTTPError as e:
                payload = e.read()
                self.send_response(e.code)
                for k, v in e.headers.items():
                    if k.lower() in HOP_HEADERS:
                        continue
                    self.send_header(k, v)
                self.send_header("content-length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            except Exception as e:  # noqa: BLE001
                self.send_error(502, f"upstream error: {e}")


    class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True
        allow_reuse_address = True


    def main() -> None:
        global DEFAULT_BACKEND
        spec = os.environ.get("WHISPER_BACKENDS", "")
        for entry in spec.split(","):
            entry = entry.strip()
            if not entry:
                continue
            name, _, url = entry.partition("=")
            name = name.strip()
            url = url.strip()
            if not name or not url:
                continue
            BACKENDS[name] = url
        default_name = os.environ.get("WHISPER_DEFAULT", "").strip()
        DEFAULT_BACKEND = BACKENDS.get(default_name)
        if DEFAULT_BACKEND is None and BACKENDS:
            DEFAULT_BACKEND = next(iter(BACKENDS.values()))
        host = os.environ.get("HOST", "127.0.0.1")
        port = int(os.environ.get("PORT", "9875"))
        sys.stderr.write(
            f"dispatcher: listening on {host}:{port} backends={BACKENDS} default={DEFAULT_BACKEND}\n"
        )
        ThreadedHTTPServer((host, port), Handler).serve_forever()


    if __name__ == "__main__":
        main()
  '';

  pkg = pkgs.whisper-cpp-vulkan;

  mkBackendService = name: let
    bport = backendPort name;
    mfile = modelFile name;
  in {
    description = "whisper.cpp server (model=${name}, ggml=${cfg.models.${name}})";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"];
    wants = ["network-online.target"];

    # whisper-server's --convert shells out to ffmpeg for mp3/m4a/opus → wav.
    path = [pkgs.ffmpeg-headless];

    preStart = ''
      if [ ! -f ${mfile} ]; then
        echo "whisper-server[${name}]: downloading model ${cfg.models.${name}}..."
        cd ${cfg.dataDir}/models
        ${pkg}/bin/whisper-cpp-download-ggml-model ${cfg.models.${name}} .
      fi
    '';

    serviceConfig = {
      User = "whisper-server";
      Group = "whisper-server";
      SupplementaryGroups = ["video" "render"];

      ExecStart = lib.concatStringsSep " " ([
          "${pkg}/bin/whisper-server"
          "--host"
          "127.0.0.1"
          "--port"
          (toString bport)
          "--model"
          mfile
          "--inference-path"
          cfg.inferencePath
          "--threads"
          (toString cfg.threads)
          "--convert"
          "--tmp-dir"
          "/tmp"
        ]
        ++ cfg.extraArgs);

      Restart = "on-failure";
      RestartSec = "10s";

      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ReadWritePaths = [cfg.dataDir];
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      ProtectClock = true;
      ProtectHostname = true;
      PrivateTmp = true;
      RestrictSUIDSGID = true;
      RestrictNamespaces = true;
      LockPersonality = true;
      RestrictRealtime = true;
      SystemCallArchitectures = "native";
      RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX"];
    };
  };
in {
  options.homelab.services.whisper-server = {
    enable = lib.mkEnableOption "Self-hosted whisper.cpp transcription server (OpenAI-compatible)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9875;
      description = ''
        Localhost port for the dispatcher. Backend whisper-server instances
        bind to port + 1, port + 2, … in alphabetical order of the models
        attrset.
      '';
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "whisper.ablz.au";
      description = ''
        Tailnet-only FQDN proxied to the dispatcher. Cloudflare A record
        points at the host's Tailscale IP via
        homelab.localProxy.tailscaleOnly, so the endpoint is only routable
        from inside the tailnet.
      '';
    };

    models = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        small = "tiny.en";
        medium = "small.en";
        large = "large-v3-turbo";
      };
      example = {
        en = "small.en";
        multi = "large-v3-turbo";
      };
      description = ''
        Mapping of short model alias → ggml model name. One whisper-server
        instance is spawned per entry, loading the named ggml model. The
        dispatcher routes a Dictate request to the instance whose alias
        matches the `model` form field. Aliases should be short and
        memorable since they are typed into the app.

        ggml options (size, English-only marker, notes):
          tiny.en        ~75MB, en, fastest
          base.en        ~142MB, en
          small.en       ~466MB, en, robust to mild noise
          medium.en      ~1.5GB, en, very accurate
          large-v3       ~3GB, multilingual
          large-v3-turbo ~1.6GB, multilingual, faster than v3
      '';
    };

    defaultModel = lib.mkOption {
      type = lib.types.str;
      default = "large";
      description = ''
        Alias used when an incoming request omits the `model` form field or
        sends an unknown alias. Must be a key in `models`.
      '';
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/whisper-server";
      description = "Where GGML model files are downloaded and cached.";
    };

    inferencePath = lib.mkOption {
      type = lib.types.str;
      default = "/v1/audio/transcriptions";
      description = ''
        HTTP path for transcription requests. Defaults to OpenAI's path so
        any OpenAI-compatible client (Dictate Keyboard, Speaches-clients,
        etc.) works without a per-client suffix tweak.
      '';
    };

    threads = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "CPU threads for whisper-server's preprocessing/fallback paths.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["--language" "en" "--no-fallback"];
      description = "Extra command-line flags passed to every whisper-server backend.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.models != {};
        message = "homelab.services.whisper-server.models must define at least one alias.";
      }
      {
        assertion = builtins.hasAttr cfg.defaultModel cfg.models;
        message = "homelab.services.whisper-server.defaultModel (\"${cfg.defaultModel}\") must be a key in models.";
      }
    ];

    users.users.whisper-server = {
      isSystemUser = true;
      group = "whisper-server";
      extraGroups = ["video" "render"];
      home = cfg.dataDir;
      createHome = false;
    };
    users.groups.whisper-server = {};

    users.users.whisper-dispatcher = {
      isSystemUser = true;
      group = "whisper-dispatcher";
    };
    users.groups.whisper-dispatcher = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 whisper-server whisper-server -"
      "d ${cfg.dataDir}/models 0750 whisper-server whisper-server -"
    ];

    # One backend systemd unit per model alias.
    systemd.services =
      lib.listToAttrs (map (n: {
          name = "whisper-server-${n}";
          value = mkBackendService n;
        })
        modelNames)
      // {
        whisper-dispatcher = {
          description = "Whisper multi-model dispatcher (OpenAI-compatible front door)";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target"] ++ (map (n: "whisper-server-${n}.service") modelNames);
          wants = ["network-online.target"];
          environment = {
            HOST = "127.0.0.1";
            PORT = toString cfg.port;
            WHISPER_BACKENDS = backendsEnv;
            WHISPER_DEFAULT = cfg.defaultModel;
          };
          serviceConfig = {
            User = "whisper-dispatcher";
            Group = "whisper-dispatcher";
            ExecStart = "${dispatcher}/bin/whisper-dispatcher";
            Restart = "on-failure";
            RestartSec = "5s";

            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            PrivateTmp = true;
            PrivateDevices = true;
            RestrictSUIDSGID = true;
            RestrictNamespaces = true;
            LockPersonality = true;
            RestrictRealtime = true;
            SystemCallArchitectures = "native";
            RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
            MemoryDenyWriteExecute = true;
          };
        };
      };

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = cfg.port;
        tailscaleOnly = true;
        maxBodySize = "100M";
      }
    ];

    homelab.monitoring.monitors = [
      {
        name = "Whisper Server (Tailnet)";
        url = "https://${cfg.fqdn}/";
      }
    ];

    # See #253 audit. Skipped — transcription service where transient
    # OOMs and per-request failures are normal operation, not an
    # actionable failure fingerprint. Outages surface via the Kuma HTTP
    # monitor above.
    homelab.monitoring.errorPatterns = [];
  };
}
