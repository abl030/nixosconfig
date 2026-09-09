# homelab.services.comfyuiGpu — ComfyUI on a passed-through NVIDIA GPU, as an
# OCI container behind the fleet's nginx/ACME local proxy.
#
# Why a container and not nixpkgs' `services.comfyui` (which the CPU sibling
# used): nixpkgs' ComfyUI is PyTorch, and this host pins cudaCapabilities to
# ["6.1"] for its Pascal card, so a CUDA-enabled torch would be an uncached,
# multi-hour, all-cores compile on prom — the exact load this host exists to
# take OFF the hypervisor. The yanwk/comfyui-boot image ships prebuilt CUDA
# wheels instead. The `cu126` line is load-bearing: CUDA 12.6 wheels still
# carry sm_61 (Pascal); the cu130 line dropped Maxwell/Pascal/Volta and would
# import fine, then fail at the first kernel launch. It is a floating tag for a
# CUDA line, not a version pin — the update timer still tracks it.
#
# Models: ComfyUI wants a directory per model type; our weights are one flat
# GGUF directory shared with sd-cli. Nesting bind mounts under the image's own
# install dir would defeat its first-run `git clone` of ComfyUI, so the flat
# dir is mounted at /models and ComfyUI is handed an extra_model_paths.yaml
# via --extra-model-paths-config. Every type points at the same directory; the
# loaders filter by extension anyway.
#
# GGUF loading needs the ComfyUI-GGUF custom node. The image runs
# /root/user-scripts/pre-start.sh on every boot, so a declarative script there
# clones it and installs its requirements — no manual step survives a rebuild.
# The script is copied onto the data volume by the unit's ExecStartPre rather
# than bind-mounted from the store: the launcher chmods it first, and a
# read-only store file makes that chmod (and the whole start) fail.
#
# Not public. ComfyUI has no authentication and executes arbitrary node
# graphs; the vhost's Cloudflare A record points at the LAN IP and nginx binds
# there, so the name only resolves usefully from inside the house.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.comfyuiGpu;

  extraModelPaths = pkgs.writeText "comfyui-extra-model-paths.yaml" ''
    imagegen:
      base_path: /models
      checkpoints: .
      diffusion_models: .
      unet: .
      text_encoders: .
      clip: .
      vae: .
      loras: lora
  '';

  # Runs INSIDE the container, so it must not reference the Nix store: plain
  # /bin/bash and whatever the image puts on PATH (git, pip in its venv).
  preStart = pkgs.writeTextFile {
    name = "comfyui-pre-start.sh";
    executable = true;
    text = ''
      #!/bin/bash
      # Ensure the GGUF loader nodes exist before ComfyUI scans custom_nodes.
      set -u
      nodes=/root/ComfyUI/custom_nodes
      [ -d "$nodes" ] || exit 0
      cd "$nodes"
      if [ ! -d ComfyUI-GGUF ]; then
        git clone --depth 1 https://github.com/city96/ComfyUI-GGUF.git || exit 0
      fi
      pip install --no-cache-dir -q -r ComfyUI-GGUF/requirements.txt || true
    '';
  };
in {
  options.homelab.services.comfyuiGpu = {
    enable = lib.mkEnableOption "ComfyUI on the passed-through GPU (OCI container)";

    image = lib.mkOption {
      type = lib.types.str;
      default = "docker.io/yanwk/comfyui-boot:cu126-slim";
      description = "ComfyUI image. Keep to a CUDA 12.x line on Pascal hardware — see header.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/comfyui";
      description = "Persistent container home: the ComfyUI checkout, custom nodes, user workflows.";
    };

    modelsDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/imagegen/models";
      description = "Flat directory of GGUF / safetensors weights, mounted read-only at /models.";
    };

    outputDir = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/out";
      description = "Share root. Renders go to <outputDir>/comfyui, the input picker reads <outputDir>/in.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8188;
      description = "Loopback port the container publishes on; nginx fronts it.";
    };

    fqdn = lib.mkOption {
      type = lib.types.str;
      default = "imagegen.ablz.au";
      description = "Name served by the local proxy with a real certificate.";
    };

    tailscaleOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the vhost to the host's tailnet address only and point its DNS
        record there, so the UI is reachable solely through the tailnet ACL.
        Requires homelab.localProxy.tailscaleIp (hosts.nix tailscaleIp).
        This is the intended posture: ComfyUI has no authentication, so the
        ACL grant list is the whole access control.
      '';
    };

    workflows = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = {};
      example = lib.literalExpression ''{ "Edit - FLUX Kontext.json" = ./workflows/edit-flux-kontext.json; }'';
      description = ''
        Saved workflows to seed into ComfyUI's user workflow directory, keyed
        by the filename the UI shows. Installed only when absent, so edits
        made in the UI are never clobbered; to push a new version, delete the
        file under <dataDir>/ComfyUI/user/default/workflows/ and restart.
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = ["--disable-dynamic-vram" "--lowvram"];
      description = ''
        Extra ComfyUI CLI flags. This pair is what makes an 8 GB card run a
        12B editor at full speed, and the reasoning is not obvious:

        ComfyUI 0.34's default "dynamic VRAM" manager would rather load a new
        model partially than evict one already resident. So after encoding
        the prompt the 3.7 GB T5 stays on the card, the 5 GB Kontext unet gets
        the ~3.5 GB left, and 1.7 GB of it is shuttled over PCIe every step —
        a 20-step edit took 34 minutes. Neither --lowvram nor
        --disable-smart-memory changes that: per `--help`, --lowvram "doesn't
        do anything if dynamic vram is enabled".

        --disable-dynamic-vram restores classic estimate-based loading with
        eviction, and --lowvram then does what it says: text encoders run on
        the CPU. The unet fits whole. Same split stable-diffusion.cpp needed
        (`--backend te=cpu`) to fit the same model on the same card.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    homelab.podman.enable = true;
    hardware.nvidia-container-toolkit.enable = true;

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root -"
    ];

    virtualisation.oci-containers.containers.comfyui = {
      image = cfg.image;
      autoStart = true;
      pull = "newer";
      ports = ["127.0.0.1:${toString cfg.port}:8188"];
      environment = {
        TZ = "Australia/Perth";
        CLI_ARGS = lib.concatStringsSep " " (
          [
            "--extra-model-paths-config /etc/comfyui/extra_model_paths.yaml"
            "--output-directory /output"
            "--input-directory /input"
          ]
          ++ cfg.extraArgs
        );
      };
      volumes = [
        "${cfg.dataDir}:/root:rw"
        "${cfg.modelsDir}:/models:ro"
        "${cfg.outputDir}/comfyui:/output:rw"
        "${cfg.outputDir}/in:/input:rw"
        "${extraModelPaths}:/etc/comfyui/extra_model_paths.yaml:ro"
      ];
      # Root inside the container is what the image expects (it installs
      # ComfyUI into /root on first run), but it needs no Linux capabilities
      # for that: cap-drop=all + no-new-privileges via hardenOptions. The GPU
      # arrives through CDI, which is a runtime injection, not a capability.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--device=nvidia.com/gpu=all"
          # Renders land on the tower share and get opened, edited and deleted
          # from other machines. The NFS server squashes every writer to one
          # uid, so the mode bits are all that decide that — write them
          # world-writable rather than the default 0644.
          "--umask=0000"
        ];
    };

    systemd.services.podman-comfyui = {
      # The share is an NFS automount; do not race it at boot, and make the
      # output/input dirs world-writable like the CPU sibling's, because the
      # NFS server squashes every writer to one uid and the mode bits are all
      # that decide whether other machines can delete what lands there.
      unitConfig.RequiresMountsFor = [cfg.outputDir];
      preStart = ''
        mkdir -p ${cfg.outputDir}/comfyui ${cfg.outputDir}/in
        chmod 0777 ${cfg.outputDir}/comfyui ${cfg.outputDir}/in || true
        # The image's launcher chmods this hook before running it, so it must
        # live on the writable data volume — bind-mounting it from the Nix
        # store (read-only) made the launcher abort on that chmod. Refresh it
        # from the store on every start so it stays declarative.
        install -D -m 0755 ${preStart} ${cfg.dataDir}/user-scripts/pre-start.sh
        # Seed saved workflows (only if absent — see the option description).
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: src: ''
            w=${lib.escapeShellArg "${cfg.dataDir}/ComfyUI/user/default/workflows/${name}"}
            if [ ! -e "$w" ]; then install -D -m 0644 ${src} "$w"; fi
          '')
          cfg.workflows)}
      '';
    };

    homelab.podman.containers = [
      {
        unit = "podman-comfyui.service";
        image = cfg.image;
      }
    ];

    homelab.localProxy.hosts = [
      {
        host = cfg.fqdn;
        port = cfg.port;
        # ComfyUI streams progress over a websocket; without this the UI
        # connects but never shows the queue moving.
        websocket = true;
        # Photo uploads for editing.
        maxBodySize = "0";
        inherit (cfg) tailscaleOnly;
      }
    ];
  };
}
