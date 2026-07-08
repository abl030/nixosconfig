{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.jdownloader2;

  # jlesage/jdownloader-2 v26.07.1 ships `/run` as a symlink to `/tmp/run`, and
  # `/tmp/run` does not exist in the image. Under podman that is fatal two ways:
  #   1. crun creates `/run/.containerenv` before the entrypoint runs → resolves
  #      through the dangling symlink to `/tmp/run/.containerenv` → ENOENT
  #      ("openat2 run: No such file or directory"). Fixed by --tmpfs=/run below
  #      (the mount follows the symlink and materialises /tmp/run).
  #   2. With /tmp/run now a mountpoint, the stock cont-init script
  #      `08-clear-tmp-dir.sh` does `rm -rf /tmp/run` and dies EBUSY on podman's
  #      `.containerenv` bind-mount ("Resource busy") → container crash-loops.
  # Docker never creates `.containerenv`, so the image works there — this is a
  # podman-only incompatibility. We can't pin the image (autoupdate is a hard
  # rule) and can't rebuild it, so we neutralise the one broken init script via
  # a read-only bind-mount. Retire this when upstream restores a real /run.
  # Verified end-to-end on doc2 (HTTP 200) 2026-07-09.
  # See docs/wiki/services/jdownloader2-podman-run-symlink.md
  clearTmpNoop = pkgs.writeTextFile {
    name = "jdownloader2-clear-tmp-noop.sh";
    executable = true;
    text = ''
      #!/bin/sh
      # No-op replacement for jlesage 08-clear-tmp-dir.sh: the stock script's
      # `rm -rf /tmp/run` dies EBUSY on podman's .containerenv bind-mount. /tmp
      # is a fresh overlay on every container (re)creation, so skipping the
      # clear is safe.
      exit 0
    '';
  };
in {
  options.homelab.services.jdownloader2 = {
    enable = lib.mkEnableOption "JDownloader2 download manager (OCI container)";

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/jdownloader2";
      description = "Directory where JDownloader2 stores its config.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/data/Media";
      description = "Root media path for download outputs.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 5800;
      description = "Port for the JDownloader2 web UI.";
    };
  };

  config = lib.mkIf cfg.enable {
    homelab = {
      nfsWatchdog.podman-jdownloader2.path = cfg.mediaDir;

      podman.enable = true;
      podman.containers = [
        {
          unit = "podman-jdownloader2.service";
          image = "docker.io/jlesage/jdownloader-2:latest";
        }
      ];

      localProxy.hosts = [
        {
          host = "download.ablz.au";
          inherit (cfg) port;
        }
      ];

      monitoring.monitors = [
        {
          name = "JDownloader2";
          url = "https://download.ablz.au/";
        }
      ];

      # See #253 audit. Skipped — download client where per-file errors
      # are normal operation, not an actionable failure fingerprint.
      # Outages surface via the Kuma HTTP monitor above.
      monitoring.errorPatterns = [];
    };

    virtualisation.oci-containers.containers.jdownloader2 = {
      image = "docker.io/jlesage/jdownloader-2:latest";
      autoStart = true;
      pull = "newer";
      ports = ["${toString cfg.port}:5800"];
      volumes = [
        "${cfg.dataDir}:/config"
        "${cfg.mediaDir}/Temp:/output"
        "${cfg.mediaDir}/Books/Unsorted/Books:/books"
        # Neutralise the image's broken /tmp clear script (see clearTmpNoop above).
        "${clearTmpNoop}:/etc/cont-init.d/08-clear-tmp-dir.sh:ro"
      ];
      environment = {
        TZ = "Australia/Perth";
        USER_ID = "0";
        GROUP_ID = "0";
        UMASK = "0002";
      };
      # jlesage init runs as root, chowns /config and the volumes, then runs
      # the GUI app. Keep the file-ownership + setuid/setgid drop caps.
      # NET_BIND_SERVICE is required even though the web UI port (:5800) is
      # unprivileged: the image's bundled `/opt/base/sbin/nginx` binary carries
      # a `cap_net_bind_service` file capability, and execve() refuses a binary
      # whose permitted file-caps exceed the process bounding set under
      # cap-drop=all (EPERM → "Operation not permitted", dead UI). cap-drop=all
      # removes everything else.
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          # Materialise /run (dangling symlink in the image) so crun can create
          # /run/.containerenv. Paired with the clearTmpNoop override above —
          # both are needed; see the let-binding for the full root cause.
          "--tmpfs=/run:rw,nosuid,nodev,exec,size=64m"
          "--cap-add=CHOWN"
          "--cap-add=SETUID"
          "--cap-add=SETGID"
          "--cap-add=DAC_OVERRIDE"
          "--cap-add=FOWNER"
          "--cap-add=KILL"
          "--cap-add=NET_BIND_SERVICE"
        ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 root root - -"
    ];
  };
}
