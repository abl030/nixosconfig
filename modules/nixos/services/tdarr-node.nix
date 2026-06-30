# See docs/wiki/services/tdarr-node.md for role, passthrough, and gotchas.
# See docs/wiki/infrastructure/igpu-passthrough.md for /dev/dri health checks.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.tdarrNode;
  tdarrUid = 2010;
  tdarrGid = 2010;
in {
  options.homelab.services.tdarrNode = {
    enable = lib.mkEnableOption "Tdarr worker node (OCI container with /dev/dri passthrough)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/docker/tdarr";
      description = "Directory for tdarr node configs and logs (subdirs: configs/, logs/).";
    };

    mediaRoot = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media";
      description = "Host path holding the media tree; mounted to /mnt/media inside the container.";
    };

    transcodeTemp = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media/Transcode Temp";
      description = "Host path for transcode scratch space; mounted to /temp inside the container.";
    };

    nodeName = lib.mkOption {
      type = lib.types.str;
      default = "IGPNode";
      description = "Node name reported to the Tdarr server.";
    };

    serverIp = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.2";
      description = "Tdarr server address (runs on tower/Unraid).";
    };

    serverPort = lib.mkOption {
      type = lib.types.port;
      default = 8266;
      description = "Tdarr server port.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/haveagitgat/tdarr_node:latest";
      description = "Tdarr node container image.";
    };

    renderDevice = lib.mkOption {
      type = lib.types.str;
      default = "/dev/dri/renderD128";
      description = ''
        Host DRM render node passed to the container for VAAPI. Defaults to
        renderD128, but on a host with multiple GPUs the iGPU may enumerate at a
        different node (e.g. renderD129 in the igpu LXC, where the GTX 1080 takes
        renderD128). Set this to the actual iGPU render node.
      '';
    };

    vaapiHealthcheckFilter = lib.mkOption {
      type = lib.types.str;
      default = "hwdownload,format=nv12";
      description = ''
        FFmpeg filter script content for Tdarr GPU thorough health checks.
        Tdarr's VAAPI health check decodes to GPU frames and then writes to a
        null sink; on this AMD iGPU path it must download frames back to software
        before the null output, otherwise FFmpeg can fail with Parsed_null_0 /
        auto_scale_0 conversion errors on valid files. Keep this as a filter
        script because Tdarr splits comma-containing extra args.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      users.tdarr = {
        isSystemUser = true;
        uid = tdarrUid;
        group = "tdarr";
        extraGroups = ["users" "render" "video"];
        home = cfg.dataDir;
      };
      groups.tdarr.gid = tdarrGid;
    };

    homelab = {
      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-tdarr-node.service";
          inherit (cfg) image;
        }
      ];

      nfsWatchdog.podman-tdarr-node.path = "${cfg.mediaRoot}/Movies";
    };

    virtualisation.oci-containers.containers.tdarr-node = {
      inherit (cfg) image;
      autoStart = true;
      pull = "newer";
      environment = {
        TZ = "Australia/Perth";
        PUID = toString tdarrUid;
        PGID = "100";
        UMASK_SET = "002";
        inherit (cfg) nodeName;
        serverIP = cfg.serverIp;
        serverPort = toString cfg.serverPort;
        inContainer = "true";
        ffmpegVersion = "7";
      };
      volumes = [
        "${cfg.dataDir}/configs:/app/configs:rw"
        "${cfg.dataDir}/logs:/app/logs:rw"
        "${cfg.mediaRoot}/Movies:/mnt/media/Movies:ro"
        "${cfg.mediaRoot}/TV Shows:/mnt/media/TV Shows:ro"
        "${cfg.transcodeTemp}:/temp:rw"
      ];
      # Upstream s6 init starts as root, chowns state, then drops to PUID/PGID,
      # so it needs the file-ownership + setuid/setgid drop caps; cap-drop=all
      # removes everything else. GPU access is device-perm based, not a cap.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--cap-add=CHOWN"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=KILL"
          # Pass the iGPU render node through UNCHANGED (same path in/out). Do NOT
          # rename it to renderD128: mesa/libva resolve the GPU via /sys/class/drm/
          # <name>, and on a multi-GPU host renderD128 is a DIFFERENT card's sysfs,
          # so a rename makes VAAPI init fail ("Cannot open a VA display").
          "--device=${cfg.renderDevice}:${cfg.renderDevice}"
        ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
      "d ${cfg.dataDir}/configs 0750 tdarr tdarr - -"
      "d ${cfg.dataDir}/logs 0750 tdarr tdarr - -"
      "f ${cfg.dataDir}/configs/vaapi-hevc.filter 0644 tdarr tdarr - format=nv12,hwupload"
      "f ${cfg.dataDir}/configs/vaapi-healthcheck.filter 0644 tdarr tdarr - ${cfg.vaapiHealthcheckFilter}"
      "Z ${cfg.dataDir}/configs - tdarr tdarr - -"
      "Z ${cfg.dataDir}/logs - tdarr tdarr - -"
    ];

    systemd.services.podman-tdarr-node = {
      requires = ["mnt-data.mount"];
      after = ["mnt-data.mount" "network-online.target"];
      wants = ["network-online.target"];

      postStart = ''
        set -eu
        for _ in $(seq 1 30); do
          if ${pkgs.podman}/bin/podman exec tdarr-node test -f /app/Tdarr_Node/srcug/node/workers/healthCheckUtils.js; then
            break
          fi
          sleep 1
        done

        # Tdarr Node 2.81.01 hardcodes VAAPI health checks to renderD128 in its
        # bundled worker code. The igpu LXC's actual AMD iGPU node is renderD129;
        # keep the upstream image but patch the runtime file after container start
        # so GPU health checks exercise the real device.
        ${pkgs.podman}/bin/podman exec tdarr-node /bin/sh -lc ${lib.escapeShellArg ''
          set -eu
          f=/app/Tdarr_Node/srcug/node/workers/healthCheckUtils.js
          cp -a "$f" "$f.nixos-prepatch" 2>/dev/null || true
          perl -0pi -e 's#/dev/dri/renderD128#${cfg.renderDevice}#g' "$f"
        ''}
      '';
    };

    systemd.services.tdarr-node-gpu-healthcheck-config = {
      description = "Declaratively seed Tdarr GPU health-check args for the igpu node";
      after = ["podman-tdarr-node.service" "network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        NoNewPrivileges = true;
      };
      script = ''
        set -eu
        ${pkgs.python3}/bin/python3 - <<'PY'
        import json
        import time
        import urllib.request

        base = "http://${cfg.serverIp}:${toString cfg.serverPort}/api/v2"
        node_name = ${builtins.toJSON cfg.nodeName}
        updates = {
            "thoroughHealthCheckGpuExtraInputArgs": "",
            "thoroughHealthCheckGpuExtraArgs": "-filter_script:v /app/configs/vaapi-healthcheck.filter",
        }

        def call(method, path, data=None, timeout=10):
            body = None if data is None else json.dumps({"data": data}).encode()
            req = urllib.request.Request(
                base + path,
                data=body,
                headers={"content-type": "application/json"},
                method=method,
            )
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read().decode("utf-8", "replace")
                try:
                    return json.loads(raw)
                except Exception:
                    return raw

        last_error = None
        for _ in range(60):
            try:
                nodes = call("GET", "/get-nodes")
                for node_id, node in nodes.items():
                    if node.get("nodeName") == node_name:
                        call("POST", "/update-node", {"nodeID": node_id, "nodeUpdates": updates})
                        print(f"seeded GPU health-check args for {node_name} ({node_id})")
                        raise SystemExit(0)
                last_error = f"node {node_name!r} not registered yet"
            except SystemExit:
                raise
            except Exception as exc:
                last_error = repr(exc)
            time.sleep(2)
        raise SystemExit(f"failed to seed Tdarr GPU health-check args: {last_error}")
        PY
      '';
    };
  };
}
