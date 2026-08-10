{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.podman;

  podmanBin = "${config.virtualisation.podman.package}/bin/podman";
  podmanVersion = config.virtualisation.podman.package.version;
  netavarkVersion = pkgs.netavark.version;
  aardvarkVersion = pkgs.aardvark-dns.version;
  buildahVersion = pkgs.buildah.version;
  skopeoVersion = pkgs.skopeo.version;
  graphRoot = config.virtualisation.containers.storage.settings.storage.graphroot;

  databaseBackendGuardPackage = pkgs.writeShellScript "podman-database-backend-guard" ''
    if [ "$#" -ne 1 ]; then
      echo "usage: podman-database-backend-guard GRAPH_ROOT" >&2
      exit 2
    fi
    bolt_db="$1/libpod/bolt_state.db"
    if [ -e "$bolt_db" ]; then
      echo "ERROR: Podman BoltDB state remains at $bolt_db" >&2
      echo "Run 'podman system migrate --migrate-db' under Podman 5, then retry activation." >&2
      exit 1
    fi
  '';

  # OCI container attr-names that get a dedicated, isolated network (#232). We
  # derive them from the registry: only entries that are real per-container
  # `virtualisation.oci-containers` units — unit `podman-<name>.service` with a
  # concrete image. Compose-style stacks (e.g. musicbrainz.service, which has a
  # non-podman- unit name) manage their own networking and are excluded; hermes
  # isn't in the registry at all. `podman-<name>.service` → `<name>`.
  isolatedNames =
    map (e: lib.removeSuffix ".service" (lib.removePrefix "podman-" e.unit))
    (lib.filter (e: e.isolate && e.image != null && lib.hasPrefix "podman-" e.unit) cfg.containers);

  lifecycleServiceNames =
    ["podman" "podman-prune"]
    ++ lib.optional (cfg.containers != []) "podman-update-containers"
    ++ map (entry: lib.removeSuffix ".service" entry.unit) cfg.containers;

  containerType = lib.types.submodule {
    options = {
      unit = lib.mkOption {
        type = lib.types.str;
        description = "Systemd unit name (e.g. podman-youtarr.service).";
      };
      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OCI image reference. When set, only restart if a newer image was pulled. When null, always restart (for compose stacks).";
      };
      isolate = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Give this container its own dedicated `isolated-<name>` bridge (#232).
          Set false for containers that manage their own networking and would
          break if an extra `--network` were injected — e.g. a sidecar that uses
          `--network=container:<other>` to share another container's netns
          (tailscale-share's caddy), or the tailscale node it pairs with.
        '';
      };
    };
  };

  # Build the update script from registered container entries
  restartScript = let
    podman = config.virtualisation.podman.package;
  in
    pkgs.writeShellScript "podman-update-containers" ''
      set -euo pipefail

      podman=${podman}/bin/podman
      failed=""
      updated=0
      skipped=0
      total=0

      ${lib.concatMapStringsSep "\n" (entry: ''
          total=$((total + 1))
          unit=${lib.escapeShellArg entry.unit}
          ${
            if entry.image != null
            then ''
              image=${lib.escapeShellArg entry.image}
              old_id=$($podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "missing")
              $podman pull "$image" >/dev/null 2>&1 || true
              new_id=$($podman image inspect "$image" --format '{{.Id}}' 2>/dev/null || echo "missing")

              if [[ "$old_id" == "$new_id" ]]; then
                echo "Skipping $unit (image $image unchanged)"
                skipped=$((skipped + 1))
              else
                echo "Updating $unit (image $image changed)"
                if systemctl restart "$unit"; then
                  updated=$((updated + 1))
                else
                  failed="$failed\n  $unit"
                fi
              fi
            ''
            else ''
              echo "Restarting $unit (no image tracking)"
              if systemctl restart "$unit"; then
                updated=$((updated + 1))
              else
                failed="$failed\n  $unit"
              fi
            ''
          }
        '')
        cfg.containers}

      if [[ -n "$failed" ]]; then
        echo "Container update: $updated updated, $skipped unchanged, failures:" >&2
        echo -e "$failed" >&2
        exit 1
      fi

      echo "Container update complete: $updated updated, $skipped unchanged (of $total)"
    '';
in {
  options.homelab.podman = {
    enable = lib.mkEnableOption "Rootful podman OCI container infrastructure";

    # Runtime-hardening baseline prepended to every homelab OCI container's
    # extraOptions. We never pin images — `:latest` + auto-pull stays on
    # fleet-wide by explicit policy (#232 TIER-4 is WONTFIX). So the
    # compensating control for a compromised auto-pulled image is to shrink
    # its runtime authority: drop ALL Linux capabilities and forbid privilege
    # escalation via setuid. Each container --cap-add=<CAP> back only the
    # minimal set it needs (s6/LSIO inits that chown then drop to PUID need
    # CHOWN,SETUID,SETGID,DAC_OVERRIDE,FOWNER,KILL; privileged-port binders
    # need NET_BIND_SERVICE). readOnly so a module can't silently weaken the
    # baseline — exceptions are additive via cap-add, never by dropping this.
    # See docs/wiki/nixos-service-modules.md "Container runtime hardening".
    hardenOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      internal = true;
      default = [
        "--security-opt=no-new-privileges"
        "--cap-drop=all"
      ];
      description = "Baseline cap-drop + no-new-privileges flags for OCI containers; prepend to extraOptions, cap-add minimal caps back per container.";
    };

    updateSchedule = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 06:00:00";
      description = "OnCalendar schedule for pulling and restarting containers.";
    };

    pruneSchedule = lib.mkOption {
      type = lib.types.str;
      default = "weekly";
      description = "OnCalendar schedule for podman system prune.";
    };

    containers = lib.mkOption {
      type = lib.types.listOf containerType;
      default = [];
      internal = true;
      description = "Registry of container units for the update timer. Set image to enable smart pull-compare updates.";
    };

    databaseBackendGuardPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "Executable BoltDB pre-activation guard used by the cutover invariant test.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.versions.major podmanVersion == "6";
        message = "homelab.podman requires Podman 6.x during the #13 cutover; got ${podmanVersion}";
      }
      {
        assertion = lib.versionAtLeast netavarkVersion "2.1" && lib.versionOlder netavarkVersion "3";
        message = "Podman 6 requires Netavark >=2.1 and <3; got ${netavarkVersion}";
      }
      {
        assertion = lib.versionAtLeast aardvarkVersion "2" && lib.versionOlder aardvarkVersion "3";
        message = "Podman 6 requires Aardvark DNS 2.x; got ${aardvarkVersion}";
      }
      {
        assertion = lib.versionAtLeast buildahVersion "1.44";
        message = "Podman 6 requires Buildah >=1.44; got ${buildahVersion}";
      }
      {
        assertion = lib.versionAtLeast skopeoVersion "1.23";
        message = "Podman 6 requires Skopeo >=1.23; got ${skopeoVersion}";
      }
      {
        assertion = config.networking.nftables.enable;
        message = "Podman 6 / Netavark 2 requires networking.nftables.enable = true";
      }
    ];

    virtualisation.podman = {
      enable = true;
      defaultNetwork.settings.dns_enabled = true;
      autoPrune = {
        enable = true;
        dates = cfg.pruneSchedule;
        flags = ["--all"];
      };
    };

    virtualisation.oci-containers.backend = "podman";

    # Podman 6 removed BoltDB support. Refuse the activation before the new
    # generation can stop or replace containers; migrate with the still-running
    # Podman 5 generation (`podman system migrate --migrate-db`) and retry.
    homelab.podman.databaseBackendGuardPackage = databaseBackendGuardPackage;
    system.activationScripts.podmanDatabaseBackendGuard = {
      deps = ["specialfs"];
      text = "${databaseBackendGuardPackage} ${lib.escapeShellArg graphRoot}";
    };

    # Per-container network isolation (#232). Each registered standalone OCI
    # container gets its OWN bridge (`isolated-<name>`) instead of sharing the
    # default `podman` bridge, where every container can L3-reach — and DNS-
    # resolve by name — every other on 10.88.0.0/16. A compromised container can
    # then no longer pivot to its siblings. `--network=<name>` REPLACES the
    # default attachment, so the container is ONLY on its own bridge. External
    # DNS, outbound NAT, published ports, and nspawn-DB auth (src is still
    # rewritten to the DB's hostAddress) all keep working — verified live on
    # doc2 2026-06-19 (incl. a real psql auth from an isolated net). The list is
    # merged (concatenated) with each module's own extraOptions.
    virtualisation.oci-containers.containers = lib.genAttrs isolatedNames (name: {
      extraOptions = ["--network=isolated-${name}"];
    });

    # Allow DNS from containers on the default podman bridge. Isolated bridges
    # do not need an equivalent host-firewall opening. Podman 6 + Netavark 2 use
    # native nftables fleet-wide; the package and backend lockstep is asserted
    # above so a future partial update cannot recreate #13.
    networking.nftables.enable = true;
    networking.firewall.interfaces.podman0.allowedUDPPorts = [53];

    systemd = {
      services = lib.mkMerge [
        {
          podman-database-backend-guard = {
            description = "Refuse Podman 6 startup while legacy BoltDB state remains";
            unitConfig.RequiresMountsFor = [graphRoot];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "${databaseBackendGuardPackage} ${lib.escapeShellArg graphRoot}";
            };
          };

          podman-update-containers = lib.mkIf (cfg.containers != []) {
            description = "Pull and restart OCI containers";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = restartScript;
            };
          };
        }
        (lib.genAttrs lifecycleServiceNames (_: {
          requires = ["podman-database-backend-guard.service"];
          after = ["podman-database-backend-guard.service"];
        }))
        # Create each isolated network just before its container starts.
        # `--ignore` makes it idempotent (no-op if it already exists); mkBefore
        # sequences it ahead of the unit's podman-rm/pull/run ExecStartPres.
        (lib.listToAttrs (map (name: {
            name = "podman-${name}";
            value.serviceConfig.ExecStartPre =
              lib.mkBefore ["${podmanBin} network create isolated-${name} --ignore"];
          })
          isolatedNames))
      ];

      timers.podman-update-containers = lib.mkIf (cfg.containers != []) {
        description = "Daily OCI container update timer";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = cfg.updateSchedule;
          Persistent = true;
        };
      };
    };
  };
}
