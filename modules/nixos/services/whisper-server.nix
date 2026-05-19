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
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.whisper-server;
  pkg = pkgs.whisper-cpp-vulkan;
  modelFile = "${cfg.dataDir}/models/ggml-${cfg.model}.bin";
in {
  options.homelab.services.whisper-server = {
    enable = lib.mkEnableOption "Self-hosted whisper.cpp transcription server (OpenAI-compatible)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9876;
      description = "Localhost port for the whisper-server binary.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "whisper.ablz.au";
      description = ''
        Tailnet-only FQDN proxied to this service. Cloudflare A record points
        at the host's Tailscale IP via homelab.localProxy.tailscaleOnly, so
        the endpoint is only routable from inside the tailnet.
      '';
    };

    model = lib.mkOption {
      type = lib.types.str;
      default = "small.en";
      example = "large-v3-turbo";
      description = ''
        GGML model name. The matching ggml-<name>.bin will be downloaded on
        first start via whisper-cpp-download-ggml-model. Trade-offs:
          tiny.en        ~75MB, fastest, OK for command-style dictation
          base.en        ~150MB, balanced
          small.en       ~466MB, good accuracy, fast on iGPU (default)
          medium.en      ~1.5GB, very accurate, slower
          large-v3       ~3GB, multilingual, slowest
          large-v3-turbo ~1.6GB, multilingual, faster than v3
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
      description = "Extra command-line flags passed to whisper-server.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.whisper-server = {
      isSystemUser = true;
      group = "whisper-server";
      # video + render needed for /dev/dri/* access (Vulkan).
      extraGroups = ["video" "render"];
      home = cfg.dataDir;
      createHome = false;
    };
    users.groups.whisper-server = {};

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 whisper-server whisper-server -"
      "d ${cfg.dataDir}/models 0750 whisper-server whisper-server -"
    ];

    systemd.services.whisper-server = {
      description = "whisper.cpp transcription server (Vulkan/iGPU, OpenAI-compatible)";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      # whisper-server's --convert flag shells out to ffmpeg to transcode
      # incoming audio (mp3/m4a/opus) to WAV before transcribing. Without this
      # in PATH the service exits at startup.
      path = [pkgs.ffmpeg-headless];

      # First-start: fetch the model file. The helper script bundled with the
      # nix package uses wget and writes ggml-<model>.bin into CWD.
      preStart = ''
        if [ ! -f ${modelFile} ]; then
          echo "whisper-server: downloading model ${cfg.model}..."
          cd ${cfg.dataDir}/models
          ${pkg}/bin/whisper-cpp-download-ggml-model ${cfg.model} .
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
            (toString cfg.port)
            "--model"
            modelFile
            "--inference-path"
            cfg.inferencePath
            "--threads"
            (toString cfg.threads)
            "--convert" # let the server transcode mp3/m4a → wav via ffmpeg
          ]
          ++ cfg.extraArgs);

        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening — read-only fs, write only to dataDir.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [cfg.dataDir];
        # Vulkan needs /dev/dri/*; do not enable PrivateDevices.
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

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = cfg.port;
        tailscaleOnly = true;
        # Audio uploads can be a few MB; cap generously but not unbounded.
        maxBodySize = "100M";
      }
    ];

    homelab.monitoring.monitors = [
      {
        name = "Whisper Server (Tailnet)";
        url = "https://${cfg.fqdn}/";
      }
    ];
  };
}
