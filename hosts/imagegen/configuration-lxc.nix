# imagegen — CPU image-generation appliance, unprivileged Proxmox LXC on prom (CT 110).
#
# Why an LXC rather than a VM: a cgroup memory limit is a *ceiling*, not a
# reservation, so the 24 GiB cap costs nothing while the container idles. A VM
# would pin the whole allocation (prom's doc1/doc2 already hold ~64 GiB
# resident that way, via memory-backend-memfd). The container also sees prom's
# 9950X unmasked — the full Zen 5 AVX-512 set including avx512_bf16 and
# avx512_vnni, which is what ggml actually accelerates on.
#
# Deliberately OFF by default at two independent levels:
#   1. the CT is created with `--onboot 0`      -> `pct start 110` on prom
#   2. comfyui's unit is wanted by no target    -> `systemctl start comfyui`
# so booting the CT to run a batch job from the CLI does not also spin up a
# torch server. Stopping the CT returns the whole cap to the host immediately.
#
# MUTUALLY EXCLUSIVE with VM 123 (imagegen-gpu) — only one runs at a time, and a
# Proxmox pre-start hookscript enforces it rather than trusting anyone to
# remember. Running both exhausted prom on 2026-09-08 and the *global* OOM
# killer took doc1 with it; the container never hit its own cgroup limit,
# because the host ran out first. A cgroup ceiling only protects the host when
# it is set BELOW the host's real headroom.
#
# LAN-only by design: no tailscale, no reverse proxy, no ACME, no public edge.
# ComfyUI has no authentication and executes arbitrary node graphs, so it must
# never face the internet.
#
# Recipe: docs/wiki/infrastructure/nixos-proxmox-lxc-guide.md
{
  lib,
  modulesPath,
  pkgs,
  ...
}: let
  # Batch runner. Reads one job per line from queue/pending.txt:
  #
  #   a red apple on a wooden table              -> generate
  #   in/holiday.jpg :: make the sky a sunset    -> edit that image
  #
  # Blank lines and #-comments are skipped; relative input paths resolve
  # against /mnt/out. Results land in /mnt/out/<date>/<time>-<slug>.png.
  #
  # Defaults run 2 jobs at 12 threads rather than 1 at 24 because thread
  # scaling measured badly on this box (2026-09-08: 24 threads bought only
  # 15% over 12, so it is memory-bandwidth bound). Two concurrent jobs give
  # roughly 1.7x the throughput of one wide one. Override anything in
  # queue/settings.env.
  imagegenBatch = pkgs.writeShellApplication {
    name = "imagegen-batch";
    runtimeInputs = with pkgs; [stable-diffusion-cpp coreutils findutils gnused gnugrep util-linux];
    text = ''
      MODELS=/var/lib/imagegen/models
      OUT=/mnt/out

      # The job queue lives on the tower share, NOT inside the container, so
      # jobs can be added from any machine on the LAN while this box is switched
      # off — which is its normal state. Starting the container drains whatever
      # is sitting there.
      PENDING="$OUT/queue.txt"
      ARCHIVE="$OUT/queue-done"

      # Settings deliberately stay INSIDE the container. The queue is parsed as
      # data, but settings.env is *sourced* — anything that can write it gets
      # arbitrary shell execution here, so it must not live on a share that
      # every LAN client can write.
      QUEUE=/var/lib/imagegen/queue

      STEPS=8
      WIDTH=1024
      HEIGHT=1024
      THREADS=12
      PARALLEL=2
      CFG_SCALE=1
      GEN_MODEL="$MODELS/z_image_turbo-Q8_0.gguf"
      GEN_VAE="$MODELS/ae.safetensors"
      GEN_LLM="$MODELS/qwen3-4b-Q4_K_M.gguf"

      # Editing needs a different model family; left empty until one is
      # installed, so an edit job fails loudly rather than silently generating.
      EDIT_STEPS=4
      EDIT_CFG_SCALE=2.5
      EDIT_MODEL=""
      EDIT_VAE=""
      EDIT_LLM=""
      EDIT_LLM_VISION=""
      EDIT_LORA_DIR=""
      EDIT_LORA_SUFFIX=""

      if [ -f "$QUEUE/settings.env" ]; then
        # shellcheck source=/dev/null
        . "$QUEUE/settings.env"
      fi

      run_one() {
        local spec="$1"
        local input prompt slug outfile day promptText
        local -a args
        input=$(sed -n 1p "$spec")
        prompt=$(sed -n 2p "$spec")

        # A template line left as "in/photo1.jpg ::" with nothing after it is a
        # half-filled job, not a request to edit with an empty prompt. Skip it
        # rather than burning ~20 minutes producing a no-op.
        if [ -z "''${prompt//[[:space:]]/}" ]; then
          echo "imagegen: skipping job with an empty prompt (input='$input')" >&2
          return 0
        fi

        day=$(date +%F)
        mkdir -p "$OUT/$day"
        slug=$(printf '%s' "$prompt" | tr -c '[:alnum:]' '-' | tr -s '-' | cut -c1-60)
        slug=''${slug%-}
        outfile="$OUT/$day/$(date +%H%M%S)-$slug.png"
        promptText="$prompt"

        if [ -n "$input" ]; then
          case "$input" in
            /*) ;;
            *) input="$OUT/$input" ;;
          esac
          if [ ! -f "$input" ]; then
            echo "imagegen: missing input image: $input" >&2
            return 1
          fi
          if [ -z "$EDIT_MODEL" ]; then
            echo "imagegen: edit job needs EDIT_MODEL in $QUEUE/settings.env" >&2
            return 1
          fi
          args=(--diffusion-model "$EDIT_MODEL" --vae "$EDIT_VAE" --llm "$EDIT_LLM")
          if [ -n "$EDIT_LLM_VISION" ]; then
            args+=(--llm_vision "$EDIT_LLM_VISION")
          fi
          if [ -n "$EDIT_LORA_DIR" ]; then
            args+=(--lora-model-dir "$EDIT_LORA_DIR")
            promptText="$prompt$EDIT_LORA_SUFFIX"
          fi
          args+=(-r "$input" --cfg-scale "$EDIT_CFG_SCALE" --steps "$EDIT_STEPS")
        else
          args=(--diffusion-model "$GEN_MODEL" --vae "$GEN_VAE" --llm "$GEN_LLM")
          args+=(--cfg-scale "$CFG_SCALE" --steps "$STEPS" -W "$WIDTH" -H "$HEIGHT")
        fi

        args+=(-t "$THREADS" --diffusion-fa -p "$promptText" -o "$outfile")
        echo "imagegen: starting -> $outfile"
        if sd-cli "''${args[@]}"; then
          echo "imagegen: done -> $outfile"
        else
          echo "imagegen: FAILED -> $outfile" >&2
          return 1
        fi
      }

      # Second entry point, used by xargs below to get parallelism.
      if [ "''${1:-}" = "--run-one" ]; then
        run_one "$2"
        exit $?
      fi

      # Fail closed: /mnt/out is a Proxmox bind mount of the tower share. If it
      # is missing, writing there would silently fill the container's 30G
      # rootfs instead of landing on the NAS.
      if ! mountpoint -q "$OUT"; then
        echo "imagegen: $OUT is not a mountpoint — refusing to write to the container rootfs" >&2
        exit 1
      fi

      if [ ! -s "$PENDING" ]; then
        echo "imagegen: queue empty ($PENDING), nothing to do"
        exit 0
      fi

      tmp=$(mktemp -d)
      # shellcheck disable=SC2064
      trap "rm -rf '$tmp'" EXIT

      n=0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          "" | \#*) continue ;;
        esac

        # Split on the first "::" if present. Tolerant of missing spaces, so
        # "in/x.jpg ::make it grey" works the same as "in/x.jpg :: make it grey".
        case "$line" in
          *"::"*)
            jobInput=$(printf '%s' "''${line%%::*}" | sed 's/[[:space:]]*$//')
            jobPrompt=$(printf '%s' "''${line#*::}" | sed 's/^[[:space:]]*//')
            ;;
          *)
            jobInput=""
            jobPrompt="$line"
            ;;
        esac

        # An unfilled template line ("in/photo1.jpg ::") is not a job yet. Skip
        # it AND leave it in the queue, so the watcher does not quietly eat the
        # template two minutes after it is written, before it can be filled in.
        if [ -z "''${jobPrompt//[[:space:]]/}" ]; then
          continue
        fi

        n=$((n + 1))
        spec=$(printf '%s/job-%04d' "$tmp" "$n")
        printf '%s\n%s\n' "$jobInput" "$jobPrompt" > "$spec"
      done < "$PENDING"

      if [ "$n" -eq 0 ]; then
        echo "imagegen: queue has no runnable lines"
        exit 0
      fi

      # Archive the queue before draining it, so a crash mid-run leaves a
      # record of what was asked for rather than losing it.
      mkdir -p "$ARCHIVE"
      cp "$PENDING" "$ARCHIVE/$(date +%F-%H%M%S).txt"
      # Consume only the filled-in jobs. Keep the comment header (so the file
      # stays self-documenting) and any still-blank template lines (so they are
      # there to fill in next time).
      grep -E '^#|::[[:space:]]*$' "$PENDING" > "$PENDING.tmp" 2>/dev/null || true
      mv "$PENDING.tmp" "$PENDING"

      echo "imagegen: $n job(s), $PARALLEL at a time, $THREADS threads each"
      find "$tmp" -name 'job-*' -print0 \
        | sort -z \
        | xargs -0 -r -P "$PARALLEL" -n1 "$0" --run-one
      echo "imagegen: queue drained"
    '';
  };
in {
  imports = [
    (modulesPath + "/virtualisation/proxmox-lxc.nix")
  ];

  proxmoxLXC = {
    privileged = false;
    manageNetwork = true;
    manageHostName = true;
  };

  # Neutralise the VM-isms inherited from base.nix — the container has no
  # bootloader, no block device of its own, no wifi, and prom owns firmware.
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = lib.mkForce false;
  services.fstrim.enable = lib.mkForce false;
  networking.wireless.enable = lib.mkForce false;
  hardware.enableRedistributableFirmware = lib.mkForce false;
  system.autoUpgrade.enable = lib.mkForce false;

  networking = {
    hostName = "imagegen";
    useDHCP = false;
    useHostResolvConf = false;
    interfaces.eth0.ipv4.addresses = [
      {
        address = "192.168.1.37";
        prefixLength = 24;
      }
    ];
    defaultGateway = "192.168.1.1";
    nameservers = ["192.168.1.1"];
    firewall.enable = true;
    # 22 = fleet deploy + operator SSH. 8188 = ComfyUI on the LAN only; the
    # host firewall is the sole gate, so keep this off any WAN-facing path.
    firewall.allowedTCPPorts = [22 8188];
  };

  homelab = {
    ssh.enable = true;
    # No tailnet membership: this box holds nothing worth reaching remotely and
    # ComfyUI is unauthenticated. Reach it from the LAN, or via doc1.
    tailscale.enable = false;
    gotify.enable = false;
    monitoring.deployOperatorApiKey = false;
    update = {
      enable = false;
      wakeOnUpdate = false;
      trim = lib.mkForce false;
      pushDeploy.enable = true;
    };
  };

  # ComfyUI is the WebUI half of the appliance. Its state — models, custom
  # nodes, inputs, outputs, db — lives under the /var/lib/imagegen bind mount
  # so weights survive a CT rebuild and stay out of PBS backups (mp0 is
  # backup=0; the weights are all re-downloadable).
  services.comfyui = {
    enable = true;
    listen = ["192.168.1.37"];
    port = 8188;
    dataDir = "/var/lib/imagegen/comfyui";
    extraArgs = [
      # PyTorch on CPU. Revisit if the GTX 1080 ever lands in a sibling host.
      "--cpu"
      # Read and write straight from the tower share, so ComfyUI's results land
      # beside the batch runner's and its input picker sees the same photos you
      # dropped in for editing. Done with the explicit flags rather than a
      # symlink inside dataDir: the unit's preStart copies its stock `output`
      # whenever that path is not a directory, and a symlink whose target does
      # not exist yet fails that test, so it crash-loops on `cp`.
      "--output-directory=/mnt/out/comfyui"
      "--input-directory=/mnt/out/in"
    ];
  };

  # ...but do not start it at boot. See the header: the CLI path is the one
  # that matters for long batch runs, and torch idling costs ~1 GiB.
  systemd.services.comfyui.wantedBy = lib.mkForce [];

  # Let ComfyUI write into the shared output mount too, and point its `output`
  # directory there so its results land beside the batch runner's. The upstream
  # unit is heavily sandboxed (ProtectSystem=strict), so /mnt/out has to be an
  # explicit BindPaths entry or the symlink below dangles at runtime.
  systemd.services.comfyui.serviceConfig = {
    BindPaths = ["/mnt/out"];
    # Same reason as imagegen-batch: its renders are opened and deleted from
    # other machines over NFS, so they must not be written read-only.
    UMask = "0000";
  };

  systemd.tmpfiles.settings."20-imagegen" = {
    "/var/lib/imagegen/queue".d = {
      user = "abl030";
      group = "users";
      mode = "0775";
    };
    "/var/lib/imagegen/queue/done".d = {
      user = "abl030";
      group = "users";
      mode = "0775";
    };
  };

  # Drain the batch queue whenever the container comes up. This is the whole
  # overnight workflow: write prompts into queue/pending.txt, `pct start 110`,
  # and starting the container *is* the trigger — no timer can fire against a
  # box that is off by default, which is the posture we want.
  systemd.services.imagegen-batch = {
    description = "Drain the imagegen prompt queue";
    wantedBy = ["multi-user.target"];
    # The Proxmox bind mounts are established by the container runtime before
    # init starts, so there is no .mount unit to order against; the script's
    # own mountpoint guard is what actually protects us.
    after = ["network.target"];
    serviceConfig = {
      Type = "oneshot";
      User = "abl030";
      Group = "users";
      # Long jobs: a 1024px edit on 20B weights can run for hours.
      TimeoutStartSec = "infinity";
      # Never let image generation starve interactive work on prom.
      Nice = 10;
      IOSchedulingClass = "idle";
      # Results land on the tower share and get opened, edited and deleted from
      # other machines. NFS squashes every writer to the same uid, so the mode
      # bits are the only thing standing in the way — default 0644 output is
      # read-only to everyone else. Write them world-writable.
      UMask = "0000";
      ExecStart = "${imagegenBatch}/bin/imagegen-batch";
    };
  };

  # Narrow, host-local exception to the locked-role default (passworded sudo).
  # abl030 may start and stop exactly the two image-generation units and nothing
  # else — these are literal command matches, so no shell, no wildcards, and no
  # general `systemctl`.
  #
  # Blast radius: the ability to start or stop image generation on a host that
  # holds no secrets, has no tailnet membership, and exposes nothing beyond the
  # LAN. It cannot edit units (that needs a fleet deploy) or touch any other
  # service. Rollback: delete this block and redeploy.
  #
  # Why it earns its keep: without it every run needs a root command on prom,
  # which makes the ordinary workflow require hypervisor access.
  security.sudo.extraRules = lib.mkAfter [
    {
      users = ["abl030"];
      commands = let
        systemctl = "/run/current-system/sw/bin/systemctl";
        verbs = ["start" "stop" "restart" "status"];
        units = ["imagegen-batch" "comfyui"];
      in
        lib.concatMap (
          unit:
            map (verb: {
              command = "${systemctl} ${verb} ${unit}";
              options = ["NOPASSWD"];
            })
            verbs
        )
        units;
    }
  ];

  # Watch the queue so the share IS the interface: drop a photo in in/, add a
  # line to queue.txt from any machine, and it starts on its own. No ssh.
  #
  # Polling, not a systemd .path unit: queue.txt lives on the tower NFS mount
  # and is edited from *other* NFS clients, so inotify here would never fire.
  # Two minutes is nothing against a ~20 minute job, and a poll that finds an
  # empty queue exits in milliseconds.
  systemd.timers.imagegen-watch = {
    description = "Poll the imagegen queue for new jobs";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "2min";
      AccuracySec = "30s";
      Unit = "imagegen-batch.service";
    };
  };

  # stable-diffusion.cpp is the CLI half and the reason this host exists: ggml
  # with GGUF k-quants, which on CPU is far faster and far leaner than torch
  # fp32. aria2 because model weights are multi-GB and HF likes to stall.
  environment.systemPackages = with pkgs; [
    stable-diffusion-cpp
    aria2
    curl
    imagegenBatch
  ];

  system.stateVersion = "26.11";
}
