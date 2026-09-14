# Audiobook requests and delivery into ABS. Operational setup and recovery:
# docs/wiki/services/shelfarr.md
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.services.shelfarr;
  image = "ghcr.io/pedro-revez-silva/shelfarr:latest";
  library = "/mnt/data/Media/Books/Audiobooks/Shelfarr";
  torrents = "/mnt/data/Media/Temp/shelfarr";
  usenet = "/mnt/data/Media/Temp/completed/shelfarr";
  probe = pkgs.writeText "shelfarr-probe.rb" (builtins.readFile ./probes/shelfarr.rb);
  # Open Library TLS setup can exceed upstream's five-second deadline.
  # Remove this override when upstream makes that timeout configurable.
  # Evidence and rollback: docs/wiki/services/shelfarr.md.
  metadataTimeout = pkgs.writeText "shelfarr-metadata-timeout.rb" ''
    module HomelabOpenLibraryTimeout
      private

      def connection
        super.tap { |client| client.options.open_timeout = 15 }
      end
    end

    Rails.application.config.after_initialize do
      OpenLibraryClient.singleton_class.prepend(HomelabOpenLibraryTimeout)
    end
  '';
in {
  options.homelab.services.shelfarr = {
    enable = lib.mkEnableOption "Shelfarr audiobook requests";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/shelfarr";
      description = "Persistent SQLite databases, encryption keys and application scratch space.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 5056;
      description = "Loopback and Podman bridge port for the Tailscale sidecar.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Operator recovery only; never mounted into the application container.
    sops.secrets."shelfarr/admin-password" = {
      sopsFile = config.homelab.secrets.sopsFile "shelfarr-bootstrap.json";
      format = "json";
      key = "password";
    };
    users.groups.shelfarr.gid = 2020;
    users.users.shelfarr = {
      isSystemUser = true;
      # Unraid exports data with all_squash,anonuid=99. Shelfarr validates
      # ownership of every new staging directory against its effective UID.
      # UID 99 has no existing host account or sudo rights on doc2.
      uid = 99;
      group = "shelfarr";
      extraGroups = ["users"];
    };
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 shelfarr shelfarr - -"
      "d ${cfg.dataDir}/storage 0750 shelfarr shelfarr - -"
      "d ${cfg.dataDir}/tmp 0750 shelfarr shelfarr - -"
      "d ${cfg.dataDir}/log 0750 shelfarr shelfarr - -"
      "d ${library} 2775 shelfarr users - -"
      "d ${torrents} 2775 shelfarr users - -"
      "d ${usenet} 2775 shelfarr users - -"
    ];

    virtualisation.oci-containers.containers.shelfarr = {
      inherit image;
      # The bridge bind serves only the Caddy sidecar; neither host LAN nor
      # host tailnet addresses expose the application directly.
      ports = ["127.0.0.1:${toString cfg.port}:8080" "10.88.0.1:${toString cfg.port}:8080"];
      environment = {
        HTTP_PORT = "8080";
        SOLID_QUEUE_IN_PUMA = "1";
        TZ = "Australia/Perth";
      };
      volumes = [
        "${cfg.dataDir}/storage:/rails/storage"
        "${cfg.dataDir}/tmp:/rails/tmp"
        "${cfg.dataDir}/log:/rails/log"
        "${library}:/audiobooks"
        # Copy mode needs only read access. No other clients' downloads or
        # existing ABS books are visible to this container.
        "${torrents}:/downloads/shelfarr:ro"
        "${usenet}:/downloads/completed/shelfarr:ro"
        "${probe}:/etc/shelfarr-probe.rb:ro"
        "${metadataTimeout}:/rails/config/initializers/homelab_metadata_timeout.rb:ro"
      ];
      extraOptions =
        config.homelab.podman.hardenOptions
        ++ [
          "--user=99:2020"
          "--group-add=100"
          "--memory=2g"
          "--pids-limit=256"
          "--health-cmd=curl -fsS http://127.0.0.1:8080/up || exit 1"
          "--health-interval=30s"
          "--health-start-period=120s"
        ];
    };
    systemd.services.podman-shelfarr = {
      unitConfig.RequiresMountsFor = [cfg.dataDir library torrents usenet];
      serviceConfig = {
        TemporaryFileSystem = "/mnt";
        BindPaths = [cfg.dataDir library];
        BindReadOnlyPaths = [torrents usenet];
      };
    };

    homelab = {
      podman.containers = [
        {
          unit = "podman-shelfarr.service";
          inherit image;
        }
      ];
      tailscaleShare.shelfarr = {
        enable = true;
        fqdn = "shelfarr.ablz.au";
        upstream = "http://host.docker.internal:${toString cfg.port}";
        dataDir = "/mnt/virtio/tailscale-share/shelfarr";
        hostname = "shelfarr";
        authKeySecret = null;
        tags = ["tag:share"];
        publishIpv6 = true;
        firewallPorts = [cfg.port];
        monitorName = "Shelfarr (Tailnet)";
        monitorPath = "/up";
      };
      nfsWatchdog.podman-shelfarr.path = library;
      monitoring.deepProbes = [
        {
          name = "Shelfarr write-path";
          command = "${pkgs.callPackage ./probes/check-shelfarr.nix {}}/bin/check-shelfarr";
          interval = "5m";
          intervalSecs = 300;
        }
      ];
      # Initial fingerprints from SQLite and Shelfarr's queue supervisor.
      # Revisit against a month of live logs after this new deployment.
      monitoring.errorPatterns = [
        {
          name = "Shelfarr database or worker failure";
          unit = "podman-shelfarr.service";
          pattern = "SQLite3::(CorruptException|ReadOnlyException|FullException)|Solid Queue supervisor exited";
          severity = "critical";
          summary = "Shelfarr cannot persist requests or process its download queue";
          threshold = 0;
        }
      ];
    };
  };
}
