# ===== ./flake.nix =====
{
  description = "My first flake!";

  inputs = {
    # --- 1. The Anchors (Standard Libraries) ---
    # use the following for unstable:
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # (No dedicated MongoDB input any more — forgejo #142. UniFi's MongoDB is a
    # digest-pinned official container managed in
    # modules/nixos/services/unifi-controller.nix, so nothing in the fleet
    # builds MongoDB from source.)

    # We add these explicitly so we can force others to follow them
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-utils.url = "github:numtide/flake-utils";
    systems.url = "github:nix-systems/default";

    # --- 2. Primary Tools ---
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #sops-nix for secrets
    sops-nix = {
      url = "github:mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # disko for declarative disk partitioning (used by nixos-anywhere)
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # microvm.nix — declarative lightweight VMs (cloud-hypervisor). Hosts the
    # isolated qBittorrent guest on its own VLAN, nested inside the servarr VM
    # (Forgejo #1). Follows nixpkgs so it shares the fleet's pin.
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # --- 3. Hardware & WSL ---
    #nixos-hardware
    nixos-hardware = {
      url = "github:NixOS/nixos-hardware/master";
      # Follow the fleet nixpkgs. nixos-hardware's modules take the importing
      # system's `pkgs`, so its own nixpkgs input was only feeding its flake
      # outputs (which we don't build) while leaving a stale duplicate nixpkgs
      # node in flake.lock. Enforced by the nixpkgsFollowsCheck audit.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # --- 4. Applications & Extensions ---
    bdday = {
      url = "git+https://git.ablz.au/abl030/bdday";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    #NVCHAD is best chad.
    nvchad4nix = {
      url = "github:nix-community/nix4nvchad";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    fzf-preview = {
      url = "github:niksingh710/fzf-preview";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };

    # Spicetify for Spotify Theming
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # --- 5. Static Sources (Non-flake) ---
    # Moving upstream tip. The rolling updater advances this independently so
    # YouTube extractor fixes do not wait for a nixpkgs release.
    yt-dlp-src = {
      url = "github:yt-dlp/yt-dlp";
      flake = false;
    };

    musicbrainz-docker = {
      # Pinned to the PG18 cutover rev (PR #339). The on-disk cluster is being
      # migrated 16→18 via upstream's admin/upgrade-to-postgres18 ceremony.
      # Stay pinned until the migration is verified, then revisit unpinning
      # in #228 (own PG via mk-pg-container).
      url = "github:metabrainz/musicbrainz-docker/9d3b9026f3de23f4774af85cfa3c99242e2fc589";
      flake = false;
    };

    lrclib-src = {
      url = "github:tranxuanthang/lrclib";
      flake = false;
    };

    # Public-tracker list for qBittorrent (servarr/qbt). flake=false → just the repo
    # source; the qbt module reads trackers_best.txt at build time and bakes it into
    # qBittorrent's "append to new torrents" pref. The nightly rolling-flake-update
    # bumps this input, so the list auto-refreshes on the nightly deploy (applied on the
    # next qbt microVM restart). See hosts/servarr/qbt-microvm.nix.
    trackerslist = {
      url = "github:ngosang/trackerslist";
      flake = false;
    };

    # Claude Code plugins
    claude-plugin-ha-skills = {
      url = "github:homeassistant-ai/skills";
      flake = false;
    };

    claude-plugin-compound-engineering = {
      url = "github:EveryInc/compound-engineering-plugin";
      flake = false;
    };

    cratedigger-src = {
      url = "github:abl030/cratedigger";
      # Follow the fleet nixpkgs so cratedigger-src does not carry its own
      # (previously a stale orphan node pinned at nixos-unstable 2026-04-14,
      # the lone reference keeping that node in flake.lock). The deployed
      # service already builds against the host's pkgs (module.nix uses
      # `pkgs.callPackage`), so this only affects cratedigger-src's own
      # checks/devShells and removes the misleading April-dated nixpkgs node.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    discogs-src = {
      url = "github:abl030/discogs-api";
      flake = false;
    };

    # Grafana dashboards — rfmoz is the upstream author of the canonical
    # "Node Exporter Full" dashboard (grafana.com/dashboards/1860). Tracking
    # the repo auto-updates the dashboard on nightly rolling-flake-update.
    grafana-dashboards-rfmoz = {
      url = "github:rfmoz/grafana-dashboards";
      flake = false;
    };

    # pfSense exporter ships its own Grafana dashboards (carp/firewall/
    # gateways/interface/services/system/traffic) co-versioned with the
    # exporter metric schema. Track the same repo we already scrape from
    # (see homelab.loki.pfsenseExporter).
    pfsense-exporter-src = {
      url = "github:pfrest/pfsense_exporter";
      flake = false;
    };

    # ntopng-exporter — per-client IP traffic metrics (bytes/packets by
    # ip+ifname+mac). Repo ships a Grafana dashboard at resources/
    # co-versioned with its metric schema. See homelab.loki.ntopngExporter.
    ntopng-exporter-src = {
      url = "github:aauren/ntopng-exporter";
      flake = false;
    };

    # Claude Code - auto-updating flake with hourly GitHub Actions updates
    claude-code-nix = {
      url = "github:sadjow/claude-code-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Codex CLI - fast-updating community flake
    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Hermes Agent CLI (Nous Research). Installed on doc1 as a local CLI package
    # only; no Hermes gateway service or Telegram integration is enabled here.
    hermes-agent = {
      url = "github:nousresearch/hermes-agent";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };

    # UniFi MCP - auto-generated MCP server for UniFi Network Controller
    unifi-mcp = {
      url = "github:abl030/unifi-mcp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # pfSense MCP - auto-generated MCP server for pfSense REST API v2
    pfsense-mcp = {
      url = "github:abl030/pfsense-mcp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # slskd MCP - MCP server for slskd (Soulseek client)
    slskd-mcp = {
      url = "github:abl030/slskd-mcp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Vinsight MCP - MCP server for Vinsight winery API.
    # Private repo: fetched via github: using the read-only GitHub PAT in
    # nix-netrc (access-tokens), NOT git+ssh. Moved off SSH in #270 so that no
    # fleet host except the doc1 bastion needs an SSH key — siblings are keyless
    # and a popped sibling holds nothing fleet-trusted.
    # Trade-off (supersedes the #210 git+ssh rationale): a broken/expired PAT
    # breaks eval of this input fleet-wide (vinsight is enabled by default in
    # base.nix → in every host's closure). Keep the fine-grained token
    # (vinsight-mcp + cellar-manager, Contents:read) on a long expiry and rotate
    # before it lapses. On a rejected PAT, refresh-access-tokens.nix blanks the
    # token so PUBLIC inputs still resolve — but this input and cellar-manager
    # are PRIVATE, so they fail eval until the PAT is rotated. Prefer a no-expiry
    # fine-grained token (scope is the protection, not the clock) to avoid a
    # silent fleet-wide eval break. Old broad PAT must be revoked post-cutover.
    vinsight-mcp = {
      url = "github:abl030/vinsight-mcp";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # cellar-manager - source tree for vinsight-local (FastAPI + sync tool)
    # served on wsl at cullen.ablz.au. Private repo (fetched via the same
    # nix-netrc PAT as vinsight-mcp); consumed as plain source because the repo
    # has no flake of its own — overlay.nix builds the vinsight-local Python
    # package from this tree.
    cellar-manager = {
      url = "github:abl030/cellar-manager";
      flake = false;
    };

    # netwatch - real-time network diagnostics TUI (Rust)
    # UNPINNED 2026-06-07 (#259): nixpkgs-unstable now carries the static.crates.io
    # fix (fetchCrate #525067), so nix crate fetches no longer hit crates.io's
    # `curl/` User-Agent 403. netwatch follows our nixpkgs, so its crate FODs now
    # download from static.crates.io. History/rationale: docs/wiki/infrastructure/cratesio-403-ua.md
    netwatch = {
      url = "github:matthart1983/netwatch";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = inputs @ {
    self,
    nixpkgs,
    flake-parts,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux"];

      imports = [
        ./nix/pkgs.nix
      ];

      perSystem = {...}: {
        imports = [./nix/devshell.nix];
      };

      flake = let
        system = "x86_64-linux";
        inherit (nixpkgs) lib;

        # Global overlays
        overlays = import ./nix/overlay.nix {inherit inputs;};

        pkgs = import nixpkgs {
          inherit system;
          inherit overlays;
          config.allowUnfree = true; # Ensure unfree is allowed for Spotify
        };

        hosts = import ./hosts.nix;
        signing = import ./nix/fleet-signing.nix {inherit lib;};

        # Import the Configuration Factory Library
        # Pass self as flake-root to match what nix/lib.nix expects
        mylib = import ./nix/lib.nix {
          inherit inputs overlays;
          flake-root = self;
        };
      in {
        nixosConfigurations =
          lib.mapAttrs
          (hostname: cfg: mylib.mkNixosSystem hostname cfg hosts)
          (lib.filterAttrs (_hostname: cfg: cfg ? "configurationFile") hosts);

        homeConfigurations =
          lib.mapAttrs
          (hostname: cfg: mylib.mkHomeConfiguration hostname cfg hosts pkgs)
          (lib.filterAttrs (_: cfg: cfg ? "homeFile") hosts);

        # Evaluation-only checks - catches config errors without building
        checks.x86_64-linux = let
          fullCheck = builtins.getEnv "FULL_CHECK" == "1";
          hostFilterRaw = builtins.getEnv "HOST_CHECKS";
          hostFilter =
            if hostFilterRaw == ""
            then null
            else
              lib.filter (name: name != "")
              (lib.splitString "," (lib.replaceStrings [" "] [","] hostFilterRaw));
          hostChecks =
            lib.mapAttrs
            (name: cfg:
              pkgs.runCommand "check-nixos-${name}" {} ''
                echo "Checking NixOS config: ${name}"
                echo "System name: ${cfg.config.system.name}"
                echo "Toplevel: ${cfg.config.system.build.toplevel}"
                touch $out
              '')
            self.nixosConfigurations
            // lib.mapAttrs
            (name: cfg:
              pkgs.runCommand "check-home-${name}" {} ''
                echo "Checking Home Manager config: ${name}"
                echo "Activation package: ${cfg.activationPackage}"
                touch $out
              '')
            self.homeConfigurations;
          pushDeployEnabledHosts = lib.sort builtins.lessThan (
            lib.attrNames (
              lib.filterAttrs
              (_name: cfg: cfg.config.homelab.update.pushDeploy.enable)
              self.nixosConfigurations
            )
          );
          pushDeployConfiguredHosts = lib.sort builtins.lessThan self.nixosConfigurations.proxmox-vm.config.homelab.ci.rollingFlakeUpdate.pushDeployHosts;
          pushDeployMissingHosts = lib.filter (name: !(lib.elem name pushDeployConfiguredHosts)) pushDeployEnabledHosts;
          pushDeployUnexpectedHosts = lib.filter (name: !(lib.elem name pushDeployEnabledHosts)) pushDeployConfiguredHosts;
          pushDeployDuplicateHosts = lib.unique (lib.filter (name: lib.count (candidate: candidate == name) pushDeployConfiguredHosts > 1) pushDeployConfiguredHosts);
          # Sender/receiver enrollment invariant: enabling a target-side
          # push-activate receiver without adding it to doc1's nightly sender
          # silently strands the host on its bootstrap generation. The metadata
          # LXCs exposed this gap because their local auto-upgrade is deliberately
          # disabled and the nightly summary only covered configured senders.
          pushDeployEnrollmentCheck = pkgs.runCommand "push-deploy-enrollment-invariant" {} ''
            if [ -n "${lib.concatStringsSep " " pushDeployMissingHosts}" ] || [ -n "${lib.concatStringsSep " " pushDeployUnexpectedHosts}" ] || [ -n "${lib.concatStringsSep " " pushDeployDuplicateHosts}" ]; then
              echo "PUSH-DEPLOY ENROLLMENT INVARIANT VIOLATED:"
              echo "  receiver enabled but not sent: ${lib.concatStringsSep " " pushDeployMissingHosts}"
              echo "  sender configured without receiver: ${lib.concatStringsSep " " pushDeployUnexpectedHosts}"
              echo "  duplicate sender entries: ${lib.concatStringsSep " " pushDeployDuplicateHosts}"
              echo "Every homelab.update.pushDeploy.enable host must be listed exactly once"
              echo "in doc1 homelab.ci.rollingFlakeUpdate.pushDeployHosts."
              exit 1
            fi
            echo "Push-deploy enrollment OK: ${lib.concatStringsSep " " pushDeployConfiguredHosts}"
            touch $out
          '';
          # Lightweight text-based check: every service module declaring
          # `homelab.localProxy.hosts` must also declare
          # `homelab.monitoring.errorPatterns` (or an explicit empty list
          # with a justifying comment). Catches the omission introduced
          # in #253 — without an errorPatterns declaration the service's
          # real failure logs are invisible to alerting.
          errorPatternsCheck = pkgs.runCommand "errorPatterns-coverage" {} ''
            fail=0
            for f in ${./modules/nixos/services}/*.nix; do
              base=$(basename "$f")
              if ${pkgs.gnugrep}/bin/grep -q "localProxy.hosts" "$f"; then
                if ! ${pkgs.gnugrep}/bin/grep -q "errorPatterns" "$f"; then
                  echo "MISSING errorPatterns: $base declares localProxy.hosts but not homelab.monitoring.errorPatterns"
                  fail=1
                fi
              fi
            done
            if [ $fail -ne 0 ]; then
              echo ""
              echo "Each module declaring localProxy.hosts must also declare"
              echo "homelab.monitoring.errorPatterns. Use \`errorPatterns = [];\`"
              echo "with a one-line justifying comment for services whose"
              echo "failure modes are genuinely covered by the Kuma HTTP"
              echo "monitor alone. See docs/wiki/nixos-service-modules.md"
              echo "\"Per-service errorPatterns\" section."
              exit 1
            fi
            echo "All service modules with localProxy.hosts declare errorPatterns."
            touch $out
          '';

          # All-interface bind audit (#232 Tier-3). A service that binds 0.0.0.0
          # is reachable, unauthenticated, by the WHOLE TAILNET — tailscale0 is a
          # trusted firewall interface (modules/nixos/services/tailscale), so an
          # all-interfaces bind sails past the localProxy nginx that's supposed to
          # front it (auth, rate-limit, ACL) and past any LAN-scoped firewalling.
          # Empirically verified 2026-06-19: doc2:8888/2283/3001 answered over the
          # tailnet IP. Default is 127.0.0.1 + homelab.localProxy.hosts. A
          # genuinely off-host endpoint (ingest, scrape target, fleet write root)
          # must carry a `BIND-ALL-INTERFACES-OK` marker comment saying why and how
          # exposure is otherwise scoped. The detector ignores comment lines (so a
          # comment that merely mentions 0.0.0.0 is fine) and CIDRs (…/0).
          hostBindAuditCheck = pkgs.runCommand "host-bind-audit" {} ''
            fail=0
            for f in $(${pkgs.findutils}/bin/find ${./modules/nixos/services} -name '*.nix' | sort); do
              if ${pkgs.gnugrep}/bin/grep -vE '^[[:space:]]*#' "$f" \
                   | ${pkgs.gnugrep}/bin/grep -oE '0\.0\.0\.0[^/]' >/dev/null 2>&1; then
                if ! ${pkgs.gnugrep}/bin/grep -q 'BIND-ALL-INTERFACES-OK' "$f"; then
                  echo "UNJUSTIFIED all-interface bind: $(basename "$f")"
                  fail=1
                fi
              fi
            done
            if [ $fail -ne 0 ]; then
              echo ""
              echo "A service module binds 0.0.0.0 (all interfaces). Because tailscale0"
              echo "is a trusted firewall interface, that exposes the service to the"
              echo "whole tailnet, unauthenticated, bypassing the localProxy nginx."
              echo "Fix: bind 127.0.0.1 and surface via homelab.localProxy.hosts."
              echo "If it genuinely must be reached off-host (ingest/scrape target,"
              echo "fleet write root), add a 'BIND-ALL-INTERFACES-OK' marker comment"
              echo "stating why and how exposure is scoped (firewall/auth)."
              echo "See docs/wiki/nixos-service-modules.md \"Host binding\" section."
              exit 1
            fi
            echo "All service-module 0.0.0.0 binds are justified (BIND-ALL-INTERFACES-OK)."
            touch $out
          '';

          # Per-unit NoNewPrivileges baseline (#232 host-hardening). NNP is a
          # PER-UNIT serviceConfig flag, so — unlike the centralized sysctl/sshd
          # baseline in base.nix — a brand-new service module silently skips it
          # unless something forces the decision. This check is that forcing
          # function: any module under modules/nixos/services/ that AUTHORS a unit
          # (an `ExecStart`/`script`/`preStart =` it owns) must either set
          # `NoNewPrivileges` (= true on every unit it can) or carry a
          # `# NNP-OK:` marker explaining why a unit legitimately needs to gain
          # privileges (e.g. tailscaled = privileged net daemon; OCI containers
          # already get no-new-privileges via homelab.podman hardenOptions; a unit
          # that activates the system / execs a setuid helper). File-level (like
          # the bind/network checks): catches the new unit that ships with no NNP
          # decision at all. lib/ + autoupdate/ infra units are out of scope (not
          # a growth surface); they carry markers for documentation only.
          unitHardeningAuditCheck = pkgs.runCommand "unit-hardening-audit" {} ''
            fail=0
            for f in $(${pkgs.findutils}/bin/find ${./modules/nixos/services} -name '*.nix' | sort); do
              # Only units we AUTHOR (`ExecStart =`/`script =`). A bare
              # ExecStartPre/preStart usually just augments an UPSTREAM unit whose
              # serviceConfig (incl. NNP) we don't own — don't force a decision there.
              if ${pkgs.gnugrep}/bin/grep -vE '^[[:space:]]*#' "$f" \
                   | ${pkgs.gnugrep}/bin/grep -qE '(ExecStart[[:space:]]*=|^[[:space:]]*script[[:space:]]*=)' ; then
                if ! ${pkgs.gnugrep}/bin/grep -q 'NoNewPrivileges' "$f" \
                   && ! ${pkgs.gnugrep}/bin/grep -q 'NNP-OK' "$f"; then
                  echo "unit without NoNewPrivileges decision: $(basename "$f")"
                  fail=1
                fi
              fi
            done
            if [ $fail -ne 0 ]; then
              echo ""
              echo "A service module authors a systemd unit but makes no"
              echo "NoNewPrivileges decision. NNP is per-unit, so new units silently"
              echo "skip it as the fleet grows. Fix: set"
              echo "  serviceConfig.NoNewPrivileges = true;"
              echo "on every unit that doesn't legitimately need to gain privileges."
              echo "If a unit MUST (privileged daemon, system activation, setuid"
              echo "helper, or an OCI container hardened at the podman layer), add a"
              echo "'# NNP-OK: <reason>' marker comment. See"
              echo "docs/wiki/nixos-service-modules.md \"NoNewPrivileges\" section."
              exit 1
            fi
            echo "All unit-authoring service modules set NoNewPrivileges or are marked."
            touch $out
          '';

          # Evaluated contract for the LAN-only bdday service. Keep this focused
          # check alongside the global source audits: it proves the generated
          # unit/vhost and the host-assignment boundary, not merely module text.
          bddayIntegrationCheck = let
            doc1 = self.nixosConfigurations.proxmox-vm.config;
            bddayPackage = inputs.bdday.packages.${system}.default;
            bddayCfg = doc1.homelab.services.bdday;
            service = doc1.systemd.services.bdday.serviceConfig;
            unit = doc1.systemd.units."bdday.service".unit;
            nginxConfig = doc1.environment.etc."nginx/nginx.conf".source;
            proxy = lib.findFirst (entry: entry.host == bddayCfg.fqdn) null doc1.homelab.localProxy.hosts;
            monitor = lib.findFirst (entry: entry.url == "https://${bddayCfg.fqdn}/healthz") null doc1.homelab.monitoring.monitors;
            errorPattern = lib.findFirst (entry: entry.unit == "bdday.service") null doc1.homelab.monitoring.errorPatterns;
            unrelatedEnabled = lib.filter (
              name: self.nixosConfigurations.${name}.config.homelab.services.bdday.enable
            ) (lib.remove "proxmox-vm" (lib.attrNames self.nixosConfigurations));
            firewallText = lib.concatStringsSep "\n" [
              doc1.networking.firewall.extraCommands
              doc1.networking.firewall.extraInputRules
            ];
            expectedExecStart = "${bddayPackage}/bin/bdday serve --listen 127.0.0.1:${toString bddayCfg.port}";
          in
            pkgs.runCommand "bdday-integration" {} ''
              set -euo pipefail

              test '${lib.boolToString bddayCfg.enable}' = true
              test '${lib.boolToString (bddayCfg.package == bddayPackage)}' = true
              test ${lib.escapeShellArg bddayCfg.fqdn} = bd.ablz.au
              test ${toString bddayCfg.port} -eq 8849
              test ${lib.escapeShellArg service.ExecStart} = ${lib.escapeShellArg expectedExecStart}
              test -x ${bddayPackage}/bin/bdday

              test '${lib.boolToString service.DynamicUser}' = true
              test '${lib.boolToString service.NoNewPrivileges}' = true
              test ${lib.escapeShellArg service.ProtectSystem} = strict
              test '${lib.boolToString service.ProtectHome}' = true
              test '${lib.boolToString service.PrivateTmp}' = true
              test '${lib.boolToString service.PrivateDevices}' = true
              test -z ${lib.escapeShellArg service.CapabilityBoundingSet}
              test -z ${lib.escapeShellArg service.AmbientCapabilities}
              test '${lib.boolToString service.RestrictNamespaces}' = true
              test '${lib.boolToString service.LockPersonality}' = true
              test ${lib.escapeShellArg service.SystemCallArchitectures} = native
              test '${lib.boolToString (service.RestrictAddressFamilies == ["AF_INET" "AF_INET6"])}' = true
              test ${lib.escapeShellArg service.IPAddressDeny} = any
              test ${lib.escapeShellArg service.IPAddressAllow} = localhost

              test '${lib.boolToString (proxy != null)}' = true
              test ${lib.escapeShellArg proxy.upstreamHost} = 127.0.0.1
              test ${toString proxy.port} -eq 8849
              test '${lib.boolToString (!proxy.tailscaleOnly)}' = true
              test '${lib.boolToString (lib.hasPrefix "192.168." doc1.homelab.localProxy.localIp)}' = true
              test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${bddayCfg.fqdn}.locations."/".proxyPass} = http://127.0.0.1:8849
              test ${lib.escapeShellArg doc1.services.nginx.virtualHosts.${bddayCfg.fqdn}.useACMEHost} = bd.ablz.au
              test '${lib.boolToString (builtins.hasAttr bddayCfg.fqdn doc1.security.acme.certs)}' = true
              ${pkgs.gnugrep}/bin/grep -F '"proxied":false' ${./modules/nixos/services/local_proxy.nix} >/dev/null

              test '${lib.boolToString (monitor != null)}' = true
              test ${lib.escapeShellArg monitor.name} = 'Biodynamic day dashboard'
              test '${lib.boolToString (errorPattern != null)}' = true
              test ${lib.escapeShellArg errorPattern.pattern} = 'panicked at|fatal runtime error'
              test ${toString errorPattern.threshold} -eq 0

              test '${lib.boolToString (!(lib.elem bddayCfg.port doc1.networking.firewall.allowedTCPPorts))}' = true
              test '${lib.boolToString (!(lib.elem bddayCfg.port doc1.networking.firewall.allowedUDPPorts))}' = true
              test '${lib.boolToString (!(lib.hasInfix (toString bddayCfg.port) firewallText))}' = true
              test -z ${lib.escapeShellArg (lib.concatStringsSep " " unrelatedEnabled)}

              ${pkgs.gnugrep}/bin/grep -F "ExecStart=${expectedExecStart}" ${unit}/bdday.service >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'DynamicUser=true' ${unit}/bdday.service >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'IPAddressDeny=any' ${unit}/bdday.service >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'IPAddressAllow=localhost' ${unit}/bdday.service >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'server_name bd.ablz.au;' ${nginxConfig} >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'proxy_pass http://127.0.0.1:8849;' ${nginxConfig} >/dev/null
              touch $out
            '';

          # Cullen's split-horizon bd route terminates at WSL but preserves
          # doc1 as the one bdday authority. Assert the generated vhost's
          # numeric upstream/SNI boundary and retain the independent Cullen
          # dashboard vhost.
          cullenBdProxyCheck = let
            wsl = self.nixosConfigurations.wsl.config;
            bdVhost = wsl.services.nginx.virtualHosts."bd.ablz.au";
            cullenVhost = wsl.services.nginx.virtualHosts."cullen.ablz.au";
            bdIsLocalProxyHost = lib.any (entry: entry.host == "bd.ablz.au") wsl.homelab.localProxy.hosts;
          in
            pkgs.runCommand "cullen-bd-proxy" {} ''
              set -euo pipefail

              test '${lib.boolToString (builtins.hasAttr "bd.ablz.au" wsl.security.acme.certs)}' = true
              test ${lib.escapeShellArg bdVhost.useACMEHost} = bd.ablz.au
              test ${lib.escapeShellArg bdVhost.locations."/".proxyPass} = https://192.168.1.29:443
              test '${lib.boolToString bdIsLocalProxyHost}' = false
              case ${lib.escapeShellArg bdVhost.locations."/".extraConfig} in
                *'proxy_ssl_server_name on;'*'proxy_ssl_name bd.ablz.au;'*'proxy_ssl_verify on;'*'proxy_ssl_trusted_certificate '*';'*'proxy_ssl_verify_depth 4;'*) ;;
                *) echo "bd proxy is missing its upstream TLS or Host boundary" >&2; exit 1 ;;
              esac

              test ${lib.escapeShellArg cullenVhost.useACMEHost} = cullen.ablz.au
              touch $out
            '';

          # Timer-driven cleanup commands must resolve to real executables in
          # the evaluated host closure. lib.getExe' does not validate that an
          # arbitrary package actually provides the requested binary.
          audiobookshelfCacheCleanupCheck = let
            command = self.nixosConfigurations.doc2.config.systemd.services.audiobookshelf-cache-cleanup.serviceConfig.ExecStart;
            executable = builtins.head (lib.splitString " " command);
          in
            pkgs.runCommand "audiobookshelf-cache-cleanup-executable" {} ''
              if [ ! -x ${lib.escapeShellArg executable} ]; then
                echo "Audiobookshelf cleanup ExecStart is not executable: ${executable}"
                exit 1
              fi
              touch $out
            '';

          # Keep the doc2 crash evidence path structurally independent of the
          # guest and lock the SSH-identity regression that broke the 2026-08-03
          # automatic reset. Generated scripts are checked, not only Nix source,
          # so interpolation/shadowing mistakes cannot hide behind evaluation.
          doc2CrashCaptureCheck = let
            doc2 = self.nixosConfigurations.doc2.config;
            observer = self.nixosConfigurations.proxmox-vm.config;
            recovery = observer.systemd.services.doc2-recovery.serviceConfig.ExecStart;
            receiverSync = observer.systemd.services.doc2-netconsole-prom-sync.serviceConfig.ExecStart;
            saveVmcore = doc2.systemd.services.crash-capture-save-vmcore.serviceConfig.ExecStart;
            dumpMount = doc2.systemd.services.crash-capture-save-vmcore.unitConfig.RequiresMountsFor;
            dumpFailureAction = doc2.systemd.services.crash-capture-save-vmcore.unitConfig.FailureAction;
            dumpTimeout = doc2.systemd.services.crash-capture-save-vmcore.serviceConfig.TimeoutStartSec;
            hasStaleDoc1Socket = observer.systemd.sockets ? doc2-netconsole;
          in
            pkgs.runCommand "doc2-crash-capture-invariants" {} ''
              recovery=${lib.escapeShellArg recovery}
              receiver_sync=${lib.escapeShellArg receiverSync}
              save_vmcore=${lib.escapeShellArg saveVmcore}

              ${pkgs.gnugrep}/bin/grep -F 'ssh -i "$ssh_key"' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'IdentitiesOnly=yes' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'StrictHostKeyChecking=yes' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'for sysrq_key in w t' "$recovery" >/dev/null
              if ${pkgs.gnugrep}/bin/grep -F 'ssh -i "$key"' "$recovery" >/dev/null; then
                echo "recovery script still permits the sysrq loop to overwrite its SSH identity"
                exit 1
              fi
              ${pkgs.gnugrep}/bin/grep -F 'info registers -a' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'qm pending $vmid' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'qm showcmd $vmid --pretty' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'captured-qga-only' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'recovered-during-capture' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'consecutive-dual-failures' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'last-observation' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'doc2_secondary_address' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'final_vm_pid' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'receiver-unhealthy' "$recovery" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'mktemp -d /run/doc2-netconsole-sync.XXXXXX' "$receiver_sync" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'StrictHostKeyChecking=yes' "$receiver_sync" >/dev/null
              if ${pkgs.gnugrep}/bin/grep -F '/tmp/doc2-netconsole-' "$receiver_sync" >/dev/null; then
                echo "receiver sync still stages privileged artifacts under shared /tmp"
                exit 1
              fi
              ${pkgs.gnugrep}/bin/grep -F 'fallocate -l "${"$"}{minimum_free_gib}G"' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'deadline-exceeded' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'configured_vmlinux=' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'kernel-modules-' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'partial="$target.partial"' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'prune_generations' "$save_vmcore" >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'kill -KILL -- "-$gzip_pid"' "$save_vmcore" >/dev/null
              if ${pkgs.gnugrep}/bin/grep -F 'df -P' "$save_vmcore" >/dev/null; then
                echo "vmcore writer regressed to a polling-only free-space guard"
                exit 1
              fi

              test ${toString doc2.homelab.crashCapture.netconsole.collectorPort} -eq 6667
              test ${lib.boolToString doc2.homelab.crashCapture.kdump.enable} = true
              test ${toString doc2.homelab.crashCapture.kdump.maxDumpMinutes} -eq 15
              test ${lib.escapeShellArg dumpMount} = /var/crash
              test ${lib.escapeShellArg dumpFailureAction} = reboot-force
              test ${lib.escapeShellArg dumpTimeout} = 20min
              test ${toString observer.homelab.services.doc2Recovery.captureFailureThreshold} -eq 10
              test ${toString observer.homelab.services.doc2Recovery.resetFailureThreshold} -eq 25
              test ${toString doc2.boot.kernel.sysctl."kernel.panic_on_oops"} -eq 1
              test ${toString doc2.boot.kernel.sysctl."kernel.panic_print"} -eq 63
              test ${lib.boolToString hasStaleDoc1Socket} = false
              if ${pkgs.gnugrep}/bin/grep -F 'copytruncate' ${./modules/nixos/services/doc2-recovery.nix} >/dev/null; then
                echo "netconsole rotation must use rename plus receiver reopen"
                exit 1
              fi
              ${pkgs.gnugrep}/bin/grep -F 'SO_RXQ_OVFL' ${./modules/nixos/services/doc2-recovery.nix} >/dev/null
              ${pkgs.gnugrep}/bin/grep -F 'LogsDirectoryMode=0700' ${./modules/nixos/services/doc2-recovery.nix} >/dev/null
              touch $out
            '';

          # Podman 6 cutover invariant (#13/#136). Every rootful Podman host must
          # move as one transaction: Podman 6, the Netavark/Aardvark 2.x line that
          # contains missing-netns teardown, native nftables, no legacy firewall
          # commands, and a pre-activation BoltDB refusal.
          podman6CutoverCheck = let
            rootfulPodmanHosts = lib.filterAttrs (_: cfg: cfg.config.virtualisation.podman.enable) self.nixosConfigurations;
            checkHost = name: cfg: let
              host = cfg.config;
              podmanVersion = cfg.pkgs.podman.version;
              netavarkVersion = cfg.pkgs.netavark.version;
              aardvarkVersion = cfg.pkgs.aardvark-dns.version;
              buildahVersion = cfg.pkgs.buildah.version;
              skopeoVersion = cfg.pkgs.skopeo.version;
              legacyFirewall = host.networking.firewall.extraCommands;
              nativeFirewall = host.networking.firewall.extraInputRules;
              podman = cfg.pkgs.podman;
              buildah = cfg.pkgs.buildah;
              guardPackage = host.homelab.podman.databaseBackendGuardPackage;
              activationGuard = host.system.activationScripts.podmanDatabaseBackendGuard;
              guard = activationGuard.text or "";
              guardUnit = "podman-database-backend-guard.service";
              lifecycleServiceNames =
                ["podman" "podman-prune"]
                ++ lib.optional (host.homelab.podman.containers != []) "podman-update-containers"
                ++ map (entry: lib.removeSuffix ".service" entry.unit) host.homelab.podman.containers;
              lifecycleGuarded =
                lib.all (
                  serviceName:
                    lib.elem guardUnit host.systemd.services.${serviceName}.requires
                    && lib.elem guardUnit host.systemd.services.${serviceName}.after
                )
                lifecycleServiceNames;
              guardReachable = serviceName: let
                visit = seen: name:
                  if lib.elem name seen || !(builtins.hasAttr name host.systemd.services)
                  then false
                  else let
                    requiredUnits = host.systemd.services.${name}.requires or [];
                    requiredServices = map (unit: lib.removeSuffix ".service" unit) requiredUnits;
                  in
                    lib.elem guardUnit requiredUnits
                    || lib.any (visit ([name] ++ seen)) requiredServices;
              in
                visit [] serviceName;
              podmanServiceNames = lib.filter (
                serviceName:
                  serviceName
                  != "podman-database-backend-guard"
                  && !(lib.hasSuffix "-nfs-watchdog" serviceName)
                  && (serviceName == "podman" || lib.hasPrefix "podman-" serviceName)
              ) (builtins.attrNames host.systemd.services);
              allPodmanServicesGuarded = lib.all guardReachable podmanServiceNames;
              bootGuardExec = host.systemd.services.podman-database-backend-guard.serviceConfig.ExecStart;
              bootGuardMounts = host.systemd.services.podman-database-backend-guard.unitConfig.RequiresMountsFor;
              graphRoot = host.virtualisation.containers.storage.settings.storage.graphroot;
            in ''
              echo 'Checking Podman 6 cutover invariants on ${name}'
              test '${lib.versions.major podmanVersion}' = 6
              test '${lib.boolToString (lib.versionAtLeast netavarkVersion "2.1")}' = true
              test '${lib.boolToString (lib.versionOlder netavarkVersion "3")}' = true
              test '${lib.boolToString (lib.versionAtLeast aardvarkVersion "2")}' = true
              test '${lib.boolToString (lib.versionOlder aardvarkVersion "3")}' = true
              test '${lib.boolToString (lib.versionAtLeast buildahVersion "1.44")}' = true
              test '${lib.boolToString (lib.versionAtLeast skopeoVersion "1.23")}' = true
              test '${lib.boolToString host.networking.nftables.enable}' = true
              test '${lib.boolToString (lib.hasInfix ''iifname "podman*" meta l4proto { tcp, udp } th dport 53 accept'' nativeFirewall)}' = true
              test '${lib.boolToString lifecycleGuarded}' = true
              test '${lib.boolToString allPodmanServicesGuarded}' = true
              test '${lib.boolToString (lib.elem "specialfs" activationGuard.deps)}' = true
              test '${lib.boolToString (lib.elem graphRoot bootGuardMounts)}' = true
              test ${lib.escapeShellArg bootGuardExec} = ${lib.escapeShellArg "${guardPackage} ${graphRoot}"}
              test -z ${lib.escapeShellArg legacyFirewall}
              test "$(${pkgs.coreutils}/bin/readlink -f ${podman}/libexec/podman/netavark)" = '${cfg.pkgs.netavark}/bin/netavark'
              test "$(${pkgs.coreutils}/bin/readlink -f ${podman}/libexec/podman/aardvark-dns)" = '${cfg.pkgs.aardvark-dns}/bin/aardvark-dns'
              helper=$(${pkgs.binutils}/bin/strings ${buildah}/bin/buildah \
                | ${pkgs.gnugrep}/bin/grep -o '/nix/store/[^ ]*-buildah-helper-binary-wrapper-[^/]*/bin' \
                | ${pkgs.coreutils}/bin/head -n 1)
              test "$(${pkgs.coreutils}/bin/readlink -f "$helper/netavark")" = '${cfg.pkgs.netavark}/bin/netavark'
              test "$(${pkgs.coreutils}/bin/readlink -f "$helper/aardvark-dns")" = '${cfg.pkgs.aardvark-dns}/bin/aardvark-dns'
              guard=${lib.escapeShellArg guard}
              test -n "$guard"
              printf '%s' "$guard" | ${pkgs.gnugrep}/bin/grep -F '${guardPackage}' >/dev/null
              graph_root="$TMPDIR/${name}-graph-root"
              mkdir -p "$graph_root/libpod"
              ${guardPackage} "$graph_root"
              touch "$graph_root/libpod/bolt_state.db"
              if ${guardPackage} "$graph_root"; then
                echo 'BoltDB guard accepted bolt_state.db on ${name}' >&2
                exit 1
              fi
            '';
          in
            pkgs.runCommand "podman6-cutover-invariants" {} ''
              set -euo pipefail
              for source in \
                ${self}/modules/nixos/homelab/podman.nix \
                ${self}/modules/nixos/services/loki.nix \
                ${self}/modules/nixos/services/mailsearch.nix \
                ${self}/modules/nixos/services/musicbrainz.nix
              do
                if ${pkgs.gnugrep}/bin/grep -Eq '(^|[[:space:]])(ip6?tables|extra(Stop)?Commands)[[:space:]=]' "$source"; then
                  echo "legacy firewall command reintroduced in $source" >&2
                  exit 1
                fi
              done
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList checkHost rootfulPodmanHosts)}
              touch $out
            '';

          # Per-service container network isolation (#232). Standalone OCI
          # containers must NOT share the default podman bridge (where every
          # container can L3-reach + DNS-resolve every other on 10.88.0.0/16, a
          # lateral-movement surface). The cure is structural: register the
          # container in `homelab.podman.containers`, which auto-assigns it a
          # dedicated `isolated-<name>` bridge (see modules/nixos/homelab/podman.nix)
          # AND gives it auto-update + autoheal. So every module that defines a
          # `virtualisation.oci-containers.containers` must either register it, or
          # carry a `CONTAINER-NETWORK-OK` marker documenting a deliberate bespoke
          # model (e.g. tailscale-share's shared-netns sidecars, hermes' single-
          # tenant VM). Catches a new container silently landing on the default bridge.
          containerNetworkAuditCheck = pkgs.runCommand "container-network-audit" {} ''
            fail=0
            for f in $(${pkgs.findutils}/bin/find ${./modules/nixos/services} -name '*.nix' | sort); do
              if ${pkgs.gnugrep}/bin/grep -q 'oci-containers\.containers' "$f"; then
                if ! ${pkgs.gnugrep}/bin/grep -qE 'podman\.containers = \[' "$f" \
                   && ! ${pkgs.gnugrep}/bin/grep -q 'CONTAINER-NETWORK-OK' "$f"; then
                  echo "OCI container not isolated: $(basename "$f")"
                  fail=1
                fi
              fi
            done
            if [ $fail -ne 0 ]; then
              echo ""
              echo "A module defines an OCI container that neither registers in"
              echo "homelab.podman.containers (which auto-assigns a dedicated"
              echo "isolated-<name> bridge + auto-update + autoheal) nor declares a"
              echo "bespoke network model. On the shared default podman bridge a"
              echo "compromised container can L3-pivot to every sibling. Fix: add the"
              echo "container to homelab.podman.containers. If it genuinely needs a"
              echo "custom network model, add a 'CONTAINER-NETWORK-OK' marker comment"
              echo "explaining it. See docs/wiki/nixos-service-modules.md \"Host binding\""
              echo "/ Podman section."
              exit 1
            fi
            echo "All OCI-container modules are registered (auto-isolated) or marked."
            touch $out
          '';

          # Pin the home-LAN detection (`on_lan`) in subnet-priority.nix. That
          # function decides whether the roaming-laptop rule `to 192.168.1.0/24
          # lookup main` is installed; it regressed twice (address-presence
          # matching a foreign/container 192.168.1.x), so this locks the current
          # gateway-MAC behaviour: home iff `ip neigh show 192.168.1.1` resolves
          # to pfSense's LAN MAC. The MAC and pattern below MUST stay in sync
          # with homeGatewayMac in modules/nixos/services/tailscale/subnet-priority.nix.
          onLanMatcherCheck = pkgs.runCommand "on-lan-matcher" {} ''
                        mac="64:62:66:21:dd:cc"
                        matches() { printf '%s\n' "$1" | ${pkgs.gnugrep}/bin/grep -qi "lladdr $mac"; }
                        fail=0
                        # Should be ON-LAN (home gateway resolves to pfSense MAC):
                        for good in \
                          "192.168.1.1 dev wlp1s0 lladdr 64:62:66:21:dd:cc REACHABLE" \
                          "192.168.1.1 dev wlp1s0 lladdr 64:62:66:21:DD:CC STALE" ; do
                          if ! matches "$good"; then echo "FAIL: expected on_lan match: $good"; fail=1; fi
                        done
                        # Should be OFF-LAN. Fixtures are plausible `ip neigh show
                        # 192.168.1.1` outputs (the IP is already scoped by that command):
                        # a foreign gateway with a different MAC, or an unresolved entry.
                        while IFS= read -r bad; do
                          if matches "$bad"; then echo "FAIL: expected on_lan NON-match: $bad"; fail=1; fi
                        done <<'EOF'
            192.168.1.1 dev wlp1s0 lladdr aa:bb:cc:dd:ee:ff REACHABLE
            192.168.1.1 dev wlp1s0 FAILED
            EOF
                        # (empty neighbour table — nothing piped — must also be non-match)
                        if ${pkgs.gnugrep}/bin/grep -qi "lladdr $mac" </dev/null; then
                          echo "FAIL: empty neigh table matched"; fail=1
                        fi
                        if [ $fail -ne 0 ]; then
                          echo ""
                          echo "on_lan gateway-MAC detection regressed. Keep this check in"
                          echo "sync with homeGatewayMac in subnet-priority.nix. See"
                          echo "docs/wiki/infrastructure/tailscale-lan-priority.md."
                          exit 1
                        fi
                        echo "on_lan gateway-MAC matcher behaves as specified."
                        touch $out
          '';

          # Bastion invariant (#270): EXACTLY ONE host may hold the fleet identity
          # private key — i.e. exactly one `deployIdentity = true` in the tree (the
          # doc1 bastion; the module default is false). A future copy-paste that
          # re-sets it true on a second host would silently re-spread the fleet
          # skeleton key and undo the whole keyless-siblings model; 0 holders means
          # nothing can reach the siblings. Either way, fail the build first.
          bastionInvariantCheck = pkgs.runCommand "bastion-deployIdentity-invariant" {} ''
            matches=$(${pkgs.gnugrep}/bin/grep -rnE "deployIdentity = true" ${./hosts} ${./modules} || true)
            count=$(printf '%s' "$matches" | ${pkgs.gnugrep}/bin/grep -c . || true)
            if [ "$count" != "1" ]; then
              echo "BASTION INVARIANT VIOLATED (#270): expected exactly ONE host with"
              echo "deployIdentity = true (the doc1 bastion), found $count:"
              printf '%s\n' "$matches"
              echo ""
              echo "Only the doc1 bastion may hold the fleet identity private key."
              echo "See issue #270 and modules/nixos/services/ssh/default.nix."
              exit 1
            fi
            echo "Bastion invariant OK: exactly one deployIdentity=true (the doc1 bastion)."
            touch $out
          '';

          # Fleet role invariant (forgejo#2): EXACTLY ONE host may be the bastion
          # — i.e. exactly one `role = "bastion"` in the tree (doc1). Every other
          # host defaults to role = "locked" (no passwordless sudo, GTFOBins
          # gated off, accepts the deploy trigger). A copy-paste that sets a
          # second "bastion" would silently re-spread passwordless root; 0 means
          # nothing has the deploy key + wrapper. Either way, fail the build.
          # Mirrors bastionInvariantCheck (deployIdentity); the two move together.
          fleetBastionRoleCheck = pkgs.runCommand "fleet-deploy-role-invariant" {} ''
            # Match the ASSIGNMENT only — `... role = "bastion";` — and never a
            # comment line (the model is described in comments all over the tree).
            # `[^#]*` can't cross a `#`, so any `# … role = "bastion"` is skipped.
            matches=$(${pkgs.gnugrep}/bin/grep -rnE '^[[:space:]]*[^#]*role = "bastion";' ${./hosts} ${./modules} || true)
            count=$(printf '%s' "$matches" | ${pkgs.gnugrep}/bin/grep -c . || true)
            if [ "$count" != "1" ]; then
              echo "FLEET BASTION ROLE INVARIANT VIOLATED (forgejo#2): expected exactly"
              echo "ONE host with homelab.fleetDeploy.role = \"bastion\" (doc1), found $count:"
              printf '%s\n' "$matches"
              echo ""
              echo "Only the doc1 bastion may be unlocked; every other host defaults to"
              echo "role = \"locked\". See modules/nixos/services/fleet-deploy.nix."
              exit 1
            fi
            echo "Fleet role invariant OK: exactly one role=\"bastion\" (the doc1 bastion)."
            touch $out
          '';

          # Least-privilege sops invariant (#234): every secret under
          # secrets/hosts/<H>/ must be encrypted to EXACTLY {that host's age key,
          # editor, break-glass} — never a sibling host key. Grep over the
          # plaintext age-recipient stanzas (works for dotenv/yaml/binary alike;
          # no decryption needed). Catches a re-key that strands a host (missing
          # own key) or leaks a host-dir secret to a sibling. The recipient↔host
          # map below mirrors secrets/.sops.yaml.
          sopsRecipientScopeCheck = pkgs.runCommand "sops-recipient-scope" {} ''
            grep=${pkgs.gnugrep}/bin/grep
            ed=age17uw7vxe8x3nmg0lu5j33qlh8pxr538jlqhhjngmexdc0macccg8sc8rw63
            bg=age1y6nasu9gplutapjne4yv0uhzrwee6ayf2mygwhphf3nty6x5xddqy4zl4h
            doc1=age1y4sdqs8dnlrma395hjna6dmzcctaeqpr8rh0wx6ap626uv0mremqsgdn30
            doc2=age1w09y86s3rtp8f06rfrwx865p9nrxsklhlsf03qsqmrlpcudleplq26xujh
            igpu=age1qa8d22yxg78e74a433vh0laaqmjp7wdx0jw0g40wfvt8ngvttdhs5c6z4c
            epi=age1gr4papzzdqfxd34ushr88303f2ypdwvgx9cw2xqs87yn4zf8lpxqc0rur5
            fw=age1ysfdznu87vwwqtpudchkyx0wlhuhteqljrqkt6963pcmhwprlgcqasg0gv
            wsl=age10hqxw3uxvg9nkc56rm495ty0rge0yhkcqp95gx00tgsv8ptg93mqwywlja
            servarr=age1tdnkggnfqkav7zxw5r3ty4d8r0tavk34p8aclzmkdtzjp69smpusudf2k4
            musicbrainz=age1cde5nfss8lkstnpe5qjq357hw253lk5sedtpznulnq5gllsc33lsll5rrl
            discogs=age12u5yjh0wff8y2tdfx5yzewrpqnhadlrafhmmmctsy37vnu8mgdlsz2p7wc
            allhosts="$doc1 $doc2 $igpu $epi $fw $wsl $servarr $musicbrainz $discogs"
            fail=0
            for d in ${./secrets/hosts}/*/; do
              h=$(basename "$d")
              case "$h" in
                proxmox-vm) own=$doc1 ;;
                doc2) own=$doc2 ;;
                igpu) own=$igpu ;;
                epimetheus) own=$epi ;;
                framework) own=$fw ;;
                wsl) own=$wsl ;;
                servarr) own=$servarr ;;
                musicbrainz) own=$musicbrainz ;;
                discogs) own=$discogs ;;
                *) echo "unknown host dir: $h"; fail=1; continue ;;
              esac
              for f in "$d"*; do
                [ -f "$f" ] || continue
                case "$f" in *.pub) continue ;; esac
                for k in $allhosts; do
                  [ "$k" = "$own" ] && continue
                  if $grep -q "$k" "$f"; then echo "LEAK: hosts/$h/$(basename "$f") is encrypted to a sibling host key"; fail=1; fi
                done
                $grep -q "$own" "$f" || { echo "MISSING own-host key: hosts/$h/$(basename "$f")"; fail=1; }
                $grep -q "$ed" "$f" || { echo "MISSING editor key: hosts/$h/$(basename "$f")"; fail=1; }
                $grep -q "$bg" "$f" || { echo "MISSING break-glass key: hosts/$h/$(basename "$f")"; fail=1; }
              done
            done
            f=${./secrets/ntfy-server.env}
            for k in $allhosts; do
              [ "$k" = "$doc2" ] && continue
              if $grep -q "$k" "$f"; then echo "LEAK: ntfy-server.env is encrypted to a non-doc2 host key"; fail=1; fi
            done
            $grep -q "$doc2" "$f" || { echo "MISSING doc2 key: ntfy-server.env"; fail=1; }
            $grep -q "$ed" "$f" || { echo "MISSING editor key: ntfy-server.env"; fail=1; }
            $grep -q "$bg" "$f" || { echo "MISSING break-glass key: ntfy-server.env"; fail=1; }
            if [ $fail -ne 0 ]; then
              echo ""
              echo "sops recipient scope violated (#234): every secrets/hosts/<H>/ secret"
              echo "must be encrypted to EXACTLY {that host key, editor, break-glass}."
              echo "Re-key with 'sops updatekeys' after fixing secrets/.sops.yaml. See"
              echo "docs/wiki/infrastructure/sops-break-glass-recovery.md."
              exit 1
            fi
            echo "sops recipient scope OK: every hosts/<H>/ secret is host-scoped."
            touch $out
          '';

          # Signed fleet deploy trust anchor (#235): hosts.nix is the single
          # source of truth for commit-signing principals, and every closure
          # renders it to /etc/fleet-update/allowed_signers. Keep this in the
          # always-run tier so WSL and ordinary evals catch drift before
          # verification enforcement depends on it.
          allowedSignersCheck = let
            validationFile = pkgs.writeText "allowed-signers-validation-errors" (lib.concatStringsSep "\n" (signing.validationErrors hosts));
            allowedSignersFile = pkgs.writeText "fleet-update-allowed_signers" (signing.allowedSignersText hosts);
          in
            pkgs.runCommand "fleet-update-allowed-signers" {} ''
              fail=0

              if [ -s ${validationFile} ]; then
                echo "fleet signing hosts.nix validation failed:"
                cat ${validationFile}
                fail=1
              fi

              if ! ${pkgs.gnugrep}/bin/grep -q '^"nix bot <acme@ablz.au>" namespaces="git" ssh-ed25519 ' ${allowedSignersFile}; then
                echo "missing correctly quoted nix bot signing principal"
                fail=1
              fi

              tmp="$(${pkgs.coreutils}/bin/mktemp -d)"
              trap '${pkgs.coreutils}/bin/rm -rf "$tmp"' EXIT
              printf 'fixture' > "$tmp/msg"
              ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C fixture -f "$tmp/key"
              ${pkgs.openssh}/bin/ssh-keygen -Y sign -f "$tmp/key" -n git "$tmp/msg" >/dev/null
              printf '"nix bot <acme@ablz.au>" namespaces="git" %s\n' "$(${pkgs.coreutils}/bin/cat "$tmp/key.pub")" > "$tmp/allowed"
              if ! ${pkgs.openssh}/bin/ssh-keygen -Y verify -f "$tmp/allowed" -I 'nix bot <acme@ablz.au>' -n git -s "$tmp/msg.sig" < "$tmp/msg" >/dev/null; then
                echo "OpenSSH rejected whitespace principal allowed_signers quoting"
                fail=1
              fi

              if [ $fail -ne 0 ]; then
                echo ""
                echo "Fix hosts.nix signingKeys / _signingPrincipals or the allowed_signers renderer."
                exit 1
              fi

              echo "fleet-update allowed_signers OK:"
              cat ${allowedSignersFile}
              touch $out
            '';

          fleetUpdateCheck =
            pkgs.runCommand "fleet-update-verifier" {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
                pkgs.jq
                pkgs.openssh
              ];
            } ''
              set -euo pipefail

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME" "$TMPDIR/bin"
              git config --global init.defaultBranch master

              cat > "$TMPDIR/bin/nixos-rebuild" <<EOF
              #!${pkgs.bash}/bin/bash
              set -euo pipefail
              printf '%s\n' "\$*" >> "$TMPDIR/rebuilds"
              exit 0
              EOF
              chmod +x "$TMPDIR/bin/nixos-rebuild"

              make_key() {
                local name="$1"
                ssh-keygen -q -t ed25519 -N "" -C "$name" -f "$TMPDIR/$name"
              }

              signed_commit() {
                local repo="$1"
                local key="$2"
                local message="$3"
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$key" \
                  commit -q -S -m "$message"
              }

              forgejo_signed_commit() {
                local repo="$1"
                local key="$2"
                local message="$3"
                git -C "$repo" \
                  -c user.name="Forgejo Merge" \
                  -c user.email="forgejo-merge@ablz.au" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$key" \
                  commit -q -S -m "$message"
              }

              unsigned_commit() {
                local repo="$1"
                local message="$2"
                git -C "$repo" \
                  -c user.name="fixture attacker" \
                  -c user.email="attacker@example.invalid" \
                  commit -q -m "$message"
              }

              write_heartbeat() {
                local repo="$1"
                local key="$2"
                local epoch="$3"
                local status="$4"
                mkdir -p "$repo/fleet"
                jq -n \
                  --argjson epoch "$epoch" \
                  --arg timestamp "$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ')" \
                  --arg actor "nix bot <acme@ablz.au>" \
                  --arg host "fixture-host" \
                  --arg status "$status" \
                  '{epoch: $epoch, timestamp: $timestamp, actor: $actor, host: $host, status: $status, failed_groups: 0, summary_lines: 1}' \
                  > "$repo/fleet/freshness.json"
                git -C "$repo" add fleet/freshness.json
                signed_commit "$repo" "$key" "fixture freshness heartbeat"
              }

              make_linear_remote() {
                local name="$1"
                local human_key="$2"
                local bot_key="$3"
                local heartbeat_epoch="$4"
                local heartbeat_status="$5"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local base target

                mkdir "$repo"
                git -C "$repo" init -q -b master
                printf 'base\n' > "$repo/flake.nix"
                git -C "$repo" add flake.nix
                signed_commit "$repo" "$human_key" "fixture signed base"
                base="$(git -C "$repo" rev-parse HEAD)"

                printf 'target\n' >> "$repo/flake.nix"
                git -C "$repo" add flake.nix
                signed_commit "$repo" "$human_key" "fixture signed target"
                write_heartbeat "$repo" "$bot_key" "$heartbeat_epoch" "$heartbeat_status"
                target="$(git -C "$repo" rev-parse HEAD)"

                git clone -q --bare "$repo" "$remote"
                printf '%s %s %s\n' "$remote" "$base" "$target"
              }

              make_unsigned_tip_remote() {
                local name="$1"
                local key="$2"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local base target

                mkdir "$repo"
                git -C "$repo" init -q -b master
                printf 'base\n' > "$repo/flake.nix"
                git -C "$repo" add flake.nix
                signed_commit "$repo" "$key" "fixture signed base"
                base="$(git -C "$repo" rev-parse HEAD)"

                printf 'unsigned\n' >> "$repo/flake.nix"
                git -C "$repo" add flake.nix
                unsigned_commit "$repo" "fixture unsigned target"
                target="$(git -C "$repo" rev-parse HEAD)"

                git clone -q --bare "$repo" "$remote"
                printf '%s %s %s\n' "$remote" "$base" "$target"
              }

              make_signed_merge_unsigned_parent_remote() {
                local name="$1"
                local key="$2"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local base target

                mkdir "$repo"
                git -C "$repo" init -q -b master
                printf 'base\n' > "$repo/flake.nix"
                git -C "$repo" add flake.nix
                signed_commit "$repo" "$key" "fixture signed base"
                base="$(git -C "$repo" rev-parse HEAD)"

                git -C "$repo" checkout -q -b unsigned-side
                printf 'side\n' > "$repo/side.txt"
                git -C "$repo" add side.txt
                unsigned_commit "$repo" "fixture unsigned side"
                git -C "$repo" checkout -q master
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$key" \
                  merge -q --no-ff -S unsigned-side -m "fixture signed merge"
                target="$(git -C "$repo" rev-parse HEAD)"

                git clone -q --bare "$repo" "$remote"
                printf '%s %s %s\n' "$remote" "$base" "$target"
              }

              make_forgejo_merge_remote() {
                local name="$1"
                local human_key="$2"
                local forgejo_key="$3"
                local mode="$4"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local base target

                mkdir "$repo"
                git -C "$repo" init -q -b master
                printf 'base\n' > "$repo/flake.nix"
                git -C "$repo" add flake.nix
                signed_commit "$repo" "$human_key" "fixture signed base"
                base="$(git -C "$repo" rev-parse HEAD)"

                case "$mode" in
                  one-parent)
                    printf 'forged\n' > "$repo/forged.txt"
                    git -C "$repo" add forged.txt
                    forgejo_signed_commit "$repo" "$forgejo_key" "fixture forbidden Forgejo linear commit"
                    ;;
                  valid|altered-tree|wrong-identity|unsigned-parent)
                    git -C "$repo" checkout -q -b signed-side
                    printf 'side\n' > "$repo/side.txt"
                    git -C "$repo" add side.txt
                    if [ "$mode" = unsigned-parent ]; then
                      unsigned_commit "$repo" "fixture unsigned side"
                    else
                      signed_commit "$repo" "$human_key" "fixture signed side"
                    fi
                    git -C "$repo" checkout -q master
                    git -C "$repo" \
                      -c user.name="Forgejo Merge" \
                      -c user.email="forgejo-merge@ablz.au" \
                      merge -q --no-ff --no-commit signed-side
                    if [ "$mode" = altered-tree ]; then
                      printf 'not present in either signed parent\n' > "$repo/injected.txt"
                      git -C "$repo" add injected.txt
                    fi
                    if [ "$mode" = wrong-identity ]; then
                      git -C "$repo" \
                        -c user.name="fixture attacker" \
                        -c user.email="attacker@example.invalid" \
                        -c gpg.format=ssh \
                        -c user.signingkey="$forgejo_key" \
                        commit -q -S -m "fixture wrong-identity Forgejo merge"
                    else
                      forgejo_signed_commit "$repo" "$forgejo_key" "fixture Forgejo merge"
                    fi
                    ;;
                  *)
                    echo "unknown Forgejo fixture mode: $mode" >&2
                    exit 1
                    ;;
                esac

                target="$(git -C "$repo" rev-parse HEAD)"
                git clone -q --bare "$repo" "$remote"
                printf '%s %s %s\n' "$remote" "$base" "$target"
              }

              run_fleet() {
                local name="$1"
                local remote="$2"
                local current="$3"
                shift 3
                FLEET_UPDATE_STATE_DIR="$TMPDIR/state-$name" \
                FLEET_UPDATE_REPO_DIR="$TMPDIR/state-$name/repo" \
                FLEET_UPDATE_ALLOWED_SIGNERS_FILE="$TMPDIR/allowed" \
                FLEET_UPDATE_LAST_VERIFIED_REV_FILE="$TMPDIR/$name-anchor" \
                FLEET_UPDATE_ORIGINS="github=file://$remote" \
                FLEET_UPDATE_WRITE_ROOT=github \
                FLEET_UPDATE_CURRENT_REV="$current" \
                FLEET_UPDATE_HOSTNAME=fixture-host \
                FLEET_UPDATE_NOW=2000000100 \
                FLEET_UPDATE_FRESHNESS_MAX_AGE_SECONDS=1000 \
                FLEET_UPDATE_REBUILD_BIN="$TMPDIR/bin/nixos-rebuild" \
                FLEET_UPDATE_REBUILD_FLAGS="--no-write-lock-file -L" \
                FLEET_UPDATE_SKIP_PREFLIGHT=1 \
                FLEET_UPDATE_SUCCESS_TIMESTAMP_FILE="$TMPDIR/$name-success" \
                FLEET_UPDATE_FAILURE_LOG="$TMPDIR/$name-failure.log" \
                ${pkgs.bash}/bin/bash ${./modules/nixos/autoupdate/fleet-update.sh} "$@"
              }

              run_probe() {
                local remote="$1"
                FLEET_UPDATE_ORIGINS="github=file://$remote" \
                ${pkgs.bash}/bin/bash ${./modules/nixos/autoupdate/fleet-update.sh} --probe-origins
              }

              mkdir -p "$TMPDIR/fail-rev-list-bin"
              cat > "$TMPDIR/fail-rev-list-bin/git" <<'EOF'
              #!${pkgs.bash}/bin/bash
              for arg in "$@"; do
                if [ "$arg" = rev-list ]; then
                  exit 97
                fi
              done
              exec ${pkgs.git}/bin/git "$@"
              EOF
              chmod +x "$TMPDIR/fail-rev-list-bin/git"

              make_key human
              make_key bot
              make_key forgejo
              {
                printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")"
                printf '"nix bot <acme@ablz.au>" namespaces="git" %s\n' "$(cat "$TMPDIR/bot.pub")"
                printf 'forgejo-merge@doc2 namespaces="git" %s\n' "$(cat "$TMPDIR/forgejo.pub")"
              } > "$TMPDIR/allowed"

              read -r linear_remote linear_base linear_target < <(make_linear_remote linear "$TMPDIR/human" "$TMPDIR/bot" 2000000000 green)
              : > "$TMPDIR/rebuilds"
              run_fleet linear "$linear_remote" "$linear_base"
              test "$(cat "$TMPDIR/linear-anchor")" = "$linear_target"
              grep -q "rev=$linear_target#fixture-host" "$TMPDIR/rebuilds"
              test "$(jq -r '.heartbeat_epoch' "$TMPDIR/state-linear/last-verified-freshness")" = "2000000000"
              test "$(cat "$TMPDIR/state-linear/highest-seen-heartbeat")" = "2000000000"
              test -s "$TMPDIR/state-linear/last-source-contact"

              : > "$TMPDIR/rebuilds"
              run_fleet noop "$linear_remote" "$linear_target"
              test ! -s "$TMPDIR/rebuilds"
              test "$(jq -r '.heartbeat_epoch' "$TMPDIR/state-noop/last-verified-freshness")" = "2000000000"

              : > "$TMPDIR/rebuilds"
              run_fleet stale "$linear_remote" "$linear_target" --rev "$linear_base"
              test ! -s "$TMPDIR/rebuilds"
              test ! -e "$TMPDIR/state-stale/last-verified-freshness"

              read -r stale_heartbeat_remote stale_heartbeat_base _stale_heartbeat_target < <(make_linear_remote stale-heartbeat "$TMPDIR/human" "$TMPDIR/bot" 1999998000 green)
              if ! run_fleet stale-heartbeat "$stale_heartbeat_remote" "$stale_heartbeat_base" 2>"$TMPDIR/stale-heartbeat.log"; then
                cat "$TMPDIR/stale-heartbeat.log" >&2
                exit 1
              fi
              grep -q "FLEET-FRESHNESS FAIL heartbeat stale" "$TMPDIR/stale-heartbeat.log"
              test ! -e "$TMPDIR/state-stale-heartbeat/last-verified-freshness"

              mkdir -p "$TMPDIR/state-replay"
              printf '2000000100\n' > "$TMPDIR/state-replay/highest-seen-heartbeat"
              if ! run_fleet replay "$linear_remote" "$linear_base" 2>"$TMPDIR/replay.log"; then
                cat "$TMPDIR/replay.log" >&2
                exit 1
              fi
              grep -q "FLEET-FRESHNESS FAIL heartbeat moved backward" "$TMPDIR/replay.log"
              test "$(cat "$TMPDIR/state-replay/highest-seen-heartbeat")" = "2000000100"
              test ! -e "$TMPDIR/state-replay/last-verified-freshness"

              read -r human_heartbeat_remote human_heartbeat_base _human_heartbeat_target < <(make_linear_remote human-heartbeat "$TMPDIR/human" "$TMPDIR/human" 2000000000 green)
              if ! run_fleet human-heartbeat "$human_heartbeat_remote" "$human_heartbeat_base" 2>"$TMPDIR/human-heartbeat.log"; then
                cat "$TMPDIR/human-heartbeat.log" >&2
                exit 1
              fi
              grep -q "FLEET-FRESHNESS FAIL fleet/freshness.json last changed by untrusted" "$TMPDIR/human-heartbeat.log"
              test ! -e "$TMPDIR/state-human-heartbeat/last-verified-freshness"

              read -r partial_remote partial_base _partial_target < <(make_linear_remote partial "$TMPDIR/human" "$TMPDIR/bot" 2000000000 partial_failure)
              if ! run_fleet partial "$partial_remote" "$partial_base" 2>"$TMPDIR/partial.log"; then
                cat "$TMPDIR/partial.log" >&2
                exit 1
              fi
              grep -q "FLEET-FRESHNESS FAIL heartbeat status is 'partial_failure'" "$TMPDIR/partial.log"
              test ! -e "$TMPDIR/state-partial/last-verified-freshness"

              read -r unsigned_remote unsigned_base _unsigned_target < <(make_unsigned_tip_remote unsigned "$TMPDIR/human")
              if run_fleet unsigned "$unsigned_remote" "$unsigned_base"; then
                echo "unsigned target was accepted" >&2
                exit 1
              fi

              read -r merge_remote merge_base _merge_target < <(make_signed_merge_unsigned_parent_remote signed-merge "$TMPDIR/human")
              if run_fleet signed-merge "$merge_remote" "$merge_base"; then
                echo "signed merge with unsigned parent was accepted" >&2
                exit 1
              fi

              read -r forgejo_valid_remote forgejo_valid_base forgejo_valid_target < <(make_forgejo_merge_remote forgejo-valid "$TMPDIR/human" "$TMPDIR/forgejo" valid)
              : > "$TMPDIR/rebuilds"
              run_fleet forgejo-valid "$forgejo_valid_remote" "$forgejo_valid_base"
              grep -q "rev=$forgejo_valid_target#fixture-host" "$TMPDIR/rebuilds"

              read -r forgejo_linear_remote forgejo_linear_base _forgejo_linear_target < <(make_forgejo_merge_remote forgejo-linear "$TMPDIR/human" "$TMPDIR/forgejo" one-parent)
              if run_fleet forgejo-linear "$forgejo_linear_remote" "$forgejo_linear_base"; then
                echo "Forgejo merge signer was accepted on a one-parent commit" >&2
                exit 1
              fi

              read -r forgejo_altered_remote forgejo_altered_base _forgejo_altered_target < <(make_forgejo_merge_remote forgejo-altered "$TMPDIR/human" "$TMPDIR/forgejo" altered-tree)
              if run_fleet forgejo-altered "$forgejo_altered_remote" "$forgejo_altered_base"; then
                echo "Forgejo merge signer was accepted with a non-deterministic merge tree" >&2
                exit 1
              fi

              read -r forgejo_identity_remote forgejo_identity_base _forgejo_identity_target < <(make_forgejo_merge_remote forgejo-identity "$TMPDIR/human" "$TMPDIR/forgejo" wrong-identity)
              if run_fleet forgejo-identity "$forgejo_identity_remote" "$forgejo_identity_base"; then
                echo "Forgejo merge signer was accepted with a forged committer identity" >&2
                exit 1
              fi

              read -r forgejo_unsigned_remote forgejo_unsigned_base _forgejo_unsigned_target < <(make_forgejo_merge_remote forgejo-unsigned "$TMPDIR/human" "$TMPDIR/forgejo" unsigned-parent)
              if run_fleet forgejo-unsigned "$forgejo_unsigned_remote" "$forgejo_unsigned_base"; then
                echo "Forgejo merge signer was accepted over an unsigned parent" >&2
                exit 1
              fi

              if run_fleet no-anchor "$linear_remote" "not-a-sha"; then
                echo "missing anchor was accepted without --accept-new-root" >&2
                exit 1
              fi

              : > "$TMPDIR/rebuilds"
              run_fleet accept-root "$linear_remote" "not-a-sha" --accept-new-root "$linear_base"
              test "$(cat "$TMPDIR/accept-root-anchor")" = "$linear_target"
              grep -q "rev=$linear_target#fixture-host" "$TMPDIR/rebuilds"

              if run_fleet forgejo-accept-root "$forgejo_valid_remote" "not-a-sha" --accept-new-root "$forgejo_valid_target"; then
                echo "Forgejo merge signer was accepted as a new trust root without verifying parent histories" >&2
                exit 1
              fi

              if PATH="$TMPDIR/fail-rev-list-bin:$PATH" run_fleet rev-list-failure "$linear_remote" "$linear_base" 2>"$TMPDIR/rev-list-failure.log"; then
                echo "failed rev-list was accepted by the deployment verifier" >&2
                exit 1
              fi

              if run_fleet bad-branch "$linear_remote" "$linear_base" --branch test-branch; then
                echo "non-master branch was accepted without override" >&2
                exit 1
              fi

              run_probe "$linear_remote"
              if run_probe "$TMPDIR/missing.git"; then
                echo "missing origin probe succeeded" >&2
                exit 1
              fi

              touch $out
            '';

          rollingFlakeUpdateSigningCheck =
            pkgs.runCommand "rolling-flake-update-signing" {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.coreutils
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
                pkgs.jq
                pkgs.openssh
              ];
            } ''
              set -euo pipefail

              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              git config --global init.defaultBranch master
              mkdir "$TMPDIR/local-source"
              git -C "$TMPDIR/local-source" init -q -b master

              mkdir -p "$TMPDIR/bin"
              cat > "$TMPDIR/bin/nix" <<'EOF'
              #!${pkgs.bash}/bin/bash
              set -euo pipefail
              if [ "$#" -eq 3 ] && [ "$1" = "flake" ] && [ "$2" = "metadata" ] && [ "$3" = "--json" ]; then
                printf '{"locks":{"root":"root","nodes":{"root":{"inputs":{"nixpkgs":"nixpkgs","home-manager":"home-manager","claude-code-nix":"claude-code-nix","nvchad4nix":"nvchad4nix","yt-dlp-src":"yt-dlp-src","other-input":"other-input"}}}}}\n'
                exit 0
              fi
              echo "unexpected nix invocation in signing fixture: $*" >&2
              exit 99
              EOF
              chmod +x "$TMPDIR/bin/nix"
              export PATH="$TMPDIR/bin:$PATH"

              make_key() {
                local name="$1"
                ssh-keygen -q -t ed25519 -N "" -C "$name" -f "$TMPDIR/$name"
              }

              make_signed_remote() {
                local name="$1"
                local signer_key="$2"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local anchor
                mkdir "$repo"
                git -C "$repo" init -q -b master
                cat > "$repo/flake.nix" <<'EOF'
              {
                description = "rolling flake update signing fixture";
                outputs = { self }: {};
              }
              EOF
                git -C "$repo" add flake.nix
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$signer_key" \
                  commit -q -S -m "fixture signed base"
                git clone -q --bare "$repo" "$remote"
                printf '%s\n' "$remote"
              }

              make_unsigned_remote() {
                local name="$1"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                mkdir "$repo"
                git -C "$repo" init -q -b master
                cat > "$repo/flake.nix" <<'EOF'
              {
                description = "rolling flake update signing fixture";
                outputs = { self }: {};
              }
              EOF
                git -C "$repo" add flake.nix
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  commit -q -m "fixture unsigned base"
                git clone -q --bare "$repo" "$remote"
                printf '%s\n' "$remote"
              }

              make_signed_merge_unsigned_parent_remote() {
                local name="$1"
                local signer_key="$2"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                mkdir "$repo"
                git -C "$repo" init -q -b master
                cat > "$repo/flake.nix" <<'EOF'
              {
                description = "rolling flake update signing fixture";
                outputs = { self }: {};
              }
              EOF
                git -C "$repo" add flake.nix
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$signer_key" \
                  commit -q -S -m "fixture signed anchor"
                anchor="$(git -C "$repo" rev-parse HEAD)"
                git -C "$repo" checkout -q -b unsigned-side
                printf 'unsigned side\n' > "$repo/unsigned.txt"
                git -C "$repo" add unsigned.txt
                git -C "$repo" \
                  -c user.name="fixture attacker" \
                  -c user.email="attacker@example.invalid" \
                  commit -q -m "fixture unsigned side"
                git -C "$repo" checkout -q master
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$signer_key" \
                  merge -q --no-ff -S unsigned-side -m "fixture signed merge"
                git clone -q --bare "$repo" "$remote"
                printf '%s %s\n' "$remote" "$anchor"
              }

              make_forgejo_remote() {
                local name="$1"
                local human_key="$2"
                local forgejo_key="$3"
                local mode="$4"
                local repo="$TMPDIR/$name-src"
                local remote="$TMPDIR/$name.git"
                local anchor

                mkdir "$repo"
                git -C "$repo" init -q -b master
                cat > "$repo/flake.nix" <<'EOF'
              {
                description = "rolling flake update Forgejo fixture";
                outputs = { self }: {};
              }
              EOF
                git -C "$repo" add flake.nix
                git -C "$repo" \
                  -c user.name="fixture human" \
                  -c user.email="fixture@example.invalid" \
                  -c gpg.format=ssh \
                  -c user.signingkey="$human_key" \
                  commit -q -S -m "fixture signed anchor"
                anchor="$(git -C "$repo" rev-parse HEAD)"

                case "$mode" in
                  one-parent)
                    printf 'forged\n' > "$repo/forged.txt"
                    git -C "$repo" add forged.txt
                    ;;
                  valid|altered-tree|wrong-identity|unsigned-parent)
                    git -C "$repo" checkout -q -b signed-side
                    printf 'side\n' > "$repo/side.txt"
                    git -C "$repo" add side.txt
                    if [ "$mode" = unsigned-parent ]; then
                      git -C "$repo" \
                        -c user.name="fixture attacker" \
                        -c user.email="attacker@example.invalid" \
                        commit -q -m "fixture unsigned side"
                    else
                      git -C "$repo" \
                        -c user.name="fixture human" \
                        -c user.email="fixture@example.invalid" \
                        -c gpg.format=ssh \
                        -c user.signingkey="$human_key" \
                        commit -q -S -m "fixture signed side"
                    fi
                    git -C "$repo" checkout -q master
                    git -C "$repo" \
                      -c user.name="Forgejo Merge" \
                      -c user.email="forgejo-merge@ablz.au" \
                      merge -q --no-ff --no-commit signed-side
                    if [ "$mode" = altered-tree ]; then
                      printf 'not in either parent\n' > "$repo/injected.txt"
                      git -C "$repo" add injected.txt
                    fi
                    ;;
                  *) exit 1 ;;
                esac

                if [ "$mode" = wrong-identity ]; then
                  git -C "$repo" \
                    -c user.name="fixture attacker" \
                    -c user.email="attacker@example.invalid" \
                    -c gpg.format=ssh \
                    -c user.signingkey="$forgejo_key" \
                    commit -q -S -m "fixture wrong-identity Forgejo commit"
                else
                  git -C "$repo" \
                    -c user.name="Forgejo Merge" \
                    -c user.email="forgejo-merge@ablz.au" \
                    -c gpg.format=ssh \
                    -c user.signingkey="$forgejo_key" \
                    commit -q -S -m "fixture Forgejo commit"
                fi
                git clone -q --bare "$repo" "$remote"
                printf '%s %s\n' "$remote" "$anchor"
              }

              run_update() {
                local remote="$1"
                local allowed="$2"
                local anchor_file="$3"
                REPO_DIR="$TMPDIR/local-source" \
                RFU_REMOTE_URL="file://$remote" \
                RFU_REQUIRE_SIGNED_BASE=1 \
                RFU_GROUP_NVCHAD=other-input \
                RFU_GROUP_YTDLP=other-input \
                RFU_GIT_SIGNING_KEY="$TMPDIR/bot" \
                RFU_ALLOWED_SIGNERS_FILE="$allowed" \
                RFU_BASE_ANCHOR_FILE="$anchor_file" \
                RFU_FAILURE_DIR="$TMPDIR/failures" \
                ONLY_GROUP="''${ONLY_GROUP_OVERRIDE:-none}" \
                ${pkgs.bash}/bin/bash ${./scripts/rolling_flake_update.sh}
              }

              mkdir -p "$TMPDIR/rolling-fail-rev-list-bin"
              cat > "$TMPDIR/rolling-fail-rev-list-bin/git" <<'EOF'
              #!${pkgs.bash}/bin/bash
              for arg in "$@"; do
                if [ "$arg" = rev-list ]; then
                  exit 97
                fi
              done
              exec ${pkgs.git}/bin/git "$@"
              EOF
              chmod +x "$TMPDIR/rolling-fail-rev-list-bin/git"

              mkdir -p "$TMPDIR/rolling-fail-rollback-bin"
              cat > "$TMPDIR/rolling-fail-rollback-bin/git" <<'EOF'
              #!${pkgs.bash}/bin/bash
              if [ "$1" = checkout ] && [ "''${2:-}" = -- ] && [ "''${3:-}" = flake.lock ]; then
                exit 42
              fi
              exec ${pkgs.git}/bin/git "$@"
              EOF
              chmod +x "$TMPDIR/rolling-fail-rollback-bin/git"

              make_key human
              make_key bot
              make_key other
              make_key forgejo

              allowed_all="$TMPDIR/allowed-all"
              {
                printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")"
                printf '"nix bot <acme@ablz.au>" namespaces="git" %s\n' "$(cat "$TMPDIR/bot.pub")"
                printf 'forgejo-merge@doc2 namespaces="git" %s\n' "$(cat "$TMPDIR/forgejo.pub")"
              } > "$allowed_all"

              allowed_human_only="$TMPDIR/allowed-human-only"
              printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")" > "$allowed_human_only"

              valid_remote="$(make_signed_remote valid "$TMPDIR/human")"
              valid_anchor="$TMPDIR/valid-anchor"
              valid_before="$(git --git-dir="$valid_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$valid_before" > "$valid_anchor"
              run_update "$valid_remote" "$allowed_all" "$valid_anchor" | tee "$TMPDIR/valid-update.log"
              grep -F '[nix-rolling]    nvchad: nvchad4nix' "$TMPDIR/valid-update.log"
              grep -F '[nix-rolling]    yt-dlp: yt-dlp-src' "$TMPDIR/valid-update.log"
              grep -F '[nix-rolling]    rest: other-input' "$TMPDIR/valid-update.log"
              if grep -F '[nix-rolling]    rest:' "$TMPDIR/valid-update.log" | grep -F nvchad4nix; then
                echo "nvchad4nix leaked into the rest update group" >&2
                exit 1
              fi
              if grep -F '[nix-rolling]    rest:' "$TMPDIR/valid-update.log" | grep -F yt-dlp-src; then
                echo "yt-dlp-src leaked into the rest update group" >&2
                exit 1
              fi
              git clone -q "$valid_remote" "$TMPDIR/valid-inspect"
              git -C "$TMPDIR/valid-inspect" -c "gpg.ssh.allowedSignersFile=$allowed_all" verify-commit HEAD
              test "$(git -C "$TMPDIR/valid-inspect" log --format=%s -1)" = "rolling: freshness heartbeat ($(date +%F))"
              test "$(cat "$valid_anchor")" = "$(git --git-dir="$valid_remote" rev-parse refs/heads/master)"

              rev_list_fail_remote="$(make_signed_remote rev-list-fail "$TMPDIR/human")"
              rev_list_fail_before="$(git --git-dir="$rev_list_fail_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$rev_list_fail_before" > "$TMPDIR/rev-list-fail-anchor"
              if PATH="$TMPDIR/rolling-fail-rev-list-bin:$PATH" run_update "$rev_list_fail_remote" "$allowed_all" "$TMPDIR/rev-list-fail-anchor"; then
                echo "rolling update accepted a failed rev-list" >&2
                exit 1
              fi

              rollback_fail_remote="$(make_signed_remote rollback-fail "$TMPDIR/human")"
              rollback_fail_before="$(git --git-dir="$rollback_fail_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$rollback_fail_before" > "$TMPDIR/rollback-fail-anchor"
              if ONLY_GROUP_OVERRIDE=core PATH="$TMPDIR/rolling-fail-rollback-bin:$PATH" \
                run_update "$rollback_fail_remote" "$allowed_all" "$TMPDIR/rollback-fail-anchor" \
                >"$TMPDIR/rollback-fail.log" 2>&1; then
                echo "rolling update accepted a failed group rollback" >&2
                exit 1
              fi
              grep -F 'rollback failed; poisoning this update transaction' "$TMPDIR/rollback-fail.log"
              grep -F 'no commits were pushed or deployed' "$TMPDIR/rollback-fail.log"
              test "$(git --git-dir="$rollback_fail_remote" rev-parse refs/heads/master)" = "$rollback_fail_before"

              git --git-dir="$valid_remote" update-ref refs/heads/master "$valid_before"
              if run_update "$valid_remote" "$allowed_all" "$valid_anchor"; then
                echo "signed replay base was accepted" >&2
                exit 1
              fi
              test "$(git --git-dir="$valid_remote" rev-parse refs/heads/master)" = "$valid_before"

              unsigned_remote="$(make_unsigned_remote unsigned)"
              unsigned_before="$(git --git-dir="$unsigned_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$unsigned_before" > "$TMPDIR/unsigned-anchor"
              if run_update "$unsigned_remote" "$allowed_all" "$TMPDIR/unsigned-anchor"; then
                echo "unsigned base was accepted" >&2
                exit 1
              fi
              test "$(git --git-dir="$unsigned_remote" rev-parse refs/heads/master)" = "$unsigned_before"

              read -r merge_remote merge_anchor < <(make_signed_merge_unsigned_parent_remote signed-merge "$TMPDIR/human")
              printf '%s\n' "$merge_anchor" > "$TMPDIR/merge-anchor"
              merge_before="$(git --git-dir="$merge_remote" rev-parse refs/heads/master)"
              if run_update "$merge_remote" "$allowed_all" "$TMPDIR/merge-anchor"; then
                echo "signed merge with unsigned parent was accepted" >&2
                exit 1
              fi
              test "$(git --git-dir="$merge_remote" rev-parse refs/heads/master)" = "$merge_before"

              read -r forgejo_valid_remote forgejo_valid_anchor < <(make_forgejo_remote forgejo-valid "$TMPDIR/human" "$TMPDIR/forgejo" valid)
              printf '%s\n' "$forgejo_valid_anchor" > "$TMPDIR/forgejo-valid-anchor"
              run_update "$forgejo_valid_remote" "$allowed_all" "$TMPDIR/forgejo-valid-anchor"

              read -r forgejo_linear_remote forgejo_linear_anchor < <(make_forgejo_remote forgejo-linear "$TMPDIR/human" "$TMPDIR/forgejo" one-parent)
              printf '%s\n' "$forgejo_linear_anchor" > "$TMPDIR/forgejo-linear-anchor"
              if run_update "$forgejo_linear_remote" "$allowed_all" "$TMPDIR/forgejo-linear-anchor"; then
                echo "rolling updater accepted Forgejo merge signer on a one-parent commit" >&2
                exit 1
              fi

              read -r forgejo_altered_remote forgejo_altered_anchor < <(make_forgejo_remote forgejo-altered "$TMPDIR/human" "$TMPDIR/forgejo" altered-tree)
              printf '%s\n' "$forgejo_altered_anchor" > "$TMPDIR/forgejo-altered-anchor"
              if run_update "$forgejo_altered_remote" "$allowed_all" "$TMPDIR/forgejo-altered-anchor"; then
                echo "rolling updater accepted a non-deterministic Forgejo merge tree" >&2
                exit 1
              fi

              read -r forgejo_identity_remote forgejo_identity_anchor < <(make_forgejo_remote forgejo-identity "$TMPDIR/human" "$TMPDIR/forgejo" wrong-identity)
              printf '%s\n' "$forgejo_identity_anchor" > "$TMPDIR/forgejo-identity-anchor"
              if run_update "$forgejo_identity_remote" "$allowed_all" "$TMPDIR/forgejo-identity-anchor"; then
                echo "rolling updater accepted a forged Forgejo committer identity" >&2
                exit 1
              fi

              read -r forgejo_unsigned_remote forgejo_unsigned_anchor < <(make_forgejo_remote forgejo-unsigned "$TMPDIR/human" "$TMPDIR/forgejo" unsigned-parent)
              printf '%s\n' "$forgejo_unsigned_anchor" > "$TMPDIR/forgejo-unsigned-anchor"
              if run_update "$forgejo_unsigned_remote" "$allowed_all" "$TMPDIR/forgejo-unsigned-anchor"; then
                echo "rolling updater accepted a Forgejo merge over an unsigned parent" >&2
                exit 1
              fi

              wrong_bot_remote="$(make_signed_remote wrong-bot "$TMPDIR/human")"
              wrong_bot_before="$(git --git-dir="$wrong_bot_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$wrong_bot_before" > "$TMPDIR/wrong-bot-anchor"
              if run_update "$wrong_bot_remote" "$allowed_human_only" "$TMPDIR/wrong-bot-anchor"; then
                echo "bot commit verified against an allowed_signers file without the bot key" >&2
                exit 1
              fi
              test "$(git --git-dir="$wrong_bot_remote" rev-parse refs/heads/master)" = "$wrong_bot_before"

              missing_allowed_remote="$(make_signed_remote missing-allowed "$TMPDIR/human")"
              missing_allowed_before="$(git --git-dir="$missing_allowed_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$missing_allowed_before" > "$TMPDIR/missing-allowed-anchor"
              if run_update "$missing_allowed_remote" "$TMPDIR/does-not-exist" "$TMPDIR/missing-allowed-anchor"; then
                echo "missing allowed_signers file was accepted" >&2
                exit 1
              fi

              touch $out
            '';

          # Credential-to-argv ratchet (#49). Audit both authored source and the
          # evaluated systemd contracts. The unit text catches changes hidden by
          # Nix rendering; deterministic known-bad fixtures qualify every owned
          # detector before the real files are scanned.
          secretArgvAuditCheck = let
            discogsSystemd = self.nixosConfigurations.discogs.config.systemd;
            doc2Systemd = self.nixosConfigurations.doc2.config.systemd;
            renderedContracts = pkgs.writeText "secret-argv-rendered-contracts" (lib.concatStringsSep "\n" [
              discogsSystemd.units."discogs-api.service".text
              discogsSystemd.units."discogs-import.service".text
              doc2Systemd.services."kopia-mum".script
              doc2Systemd.services."kopia-photos".script
            ]);
            renderedKopiaExecutables = [
              doc2Systemd.services."kopia-mum-source-sync".serviceConfig.ExecStart
              doc2Systemd.services."kopia-photos-source-sync".serviceConfig.ExecStart
              doc2Systemd.services."deep-probe-kopia-mum-freshness".serviceConfig.ExecStart
              doc2Systemd.services."deep-probe-kopia-mum-backup".serviceConfig.ExecStart
              doc2Systemd.services."deep-probe-kopia-photos-freshness".serviceConfig.ExecStart
              doc2Systemd.services."deep-probe-kopia-photos-backup".serviceConfig.ExecStart
              "${pkgs.callPackage ./modules/nixos/services/probes/check-kopia-fresh.nix {}}/bin/check-kopia-fresh"
              "${pkgs.callPackage ./modules/nixos/services/probes/check-kopia-backup-errors.nix {}}/bin/check-kopia-backup-errors"
            ];
          in
            pkgs.runCommand "secret-argv-audit" {
              nativeBuildInputs = [pkgs.python3 pkgs.gnugrep];
            } ''
              SECRET_ARGV_AUDIT=${./nix/checks/secret-argv-audit.py} \
                python3 ${./nix/checks/test_secret_argv_audit.py}
              bash ${./nix/checks/test-kopia-curl-auth.sh} \
                ${./modules/nixos/services/probes/kopia-curl-auth.sh}
              python3 ${./nix/checks/secret-argv-audit.py} \
                ${renderedContracts} \
                ${lib.escapeShellArgs renderedKopiaExecutables} \
                ${./modules/nixos/services/discogs.nix} \
                ${./modules/nixos/services/kopia.nix} \
                ${./modules/nixos/services/probes/check-kopia-fresh.nix} \
                ${./modules/nixos/services/probes/check-kopia-backup-errors.nix}

              test "$(grep -c -- '--credential-file %d/postgres-password' ${renderedContracts})" -eq 2
              test "$(grep -c '^LoadCredential=postgres-password:' ${renderedContracts})" -eq 2
              if grep -q '^EnvironmentFile=.*discogs-pgpass' ${renderedContracts}; then
                echo "Discogs must not receive its PostgreSQL password through the environment" >&2
                exit 1
              fi
              touch "$out"
            '';

          # Every flake input must FOLLOW the fleet nixpkgs, never carry its own.
          # A duplicate nixpkgs node in flake.lock drifts stale on its own (the
          # rolling-flake-update only advances the ROOT pin), bloats every closure
          # that pulls the input, and makes tooling/agents misread the fleet
          # nixpkgs version — exactly the orphan that left a stale "nixpkgs from
          # April" node lying in the lock. Deny-by-default: a genuine exception
          # needs a `# NIXPKGS-OWN-OK: <input> — <reason>` marker in flake.nix.
          # Detection is list-vs-string in flake.lock (follows = list, own = string
          # node-ref); see nix/checks/nixpkgs-follows-audit.py and
          # docs/wiki/infrastructure/nixpkgs-follows-policy.md.
          nixpkgsFollowsCheck = pkgs.runCommand "nixpkgs-follows-audit" {} ''
            ${pkgs.python3}/bin/python3 ${./nix/checks/nixpkgs-follows-audit.py} \
              ${./flake.lock} ${./flake.nix} || exit 1
            touch $out
          '';

          cratediggerDailySummaryCheck = let
            notifier = self.nixosConfigurations.proxmox-vm.config.systemd.services.cratedigger-daily-checks-notify-failure.serviceConfig.ExecStart;
          in
            pkgs.runCommand "cratedigger-daily-summary" {
              nativeBuildInputs = [pkgs.gnugrep pkgs.jq pkgs.python3];
            } ''
              CRATEDIGGER_DAILY_SUMMARY=${./modules/nixos/ci/scripts/cratedigger-daily-summary.py} \
                python3 ${./nix/checks/test_cratedigger_daily_summary.py}
              CRATEDIGGER_WORLD_AUDIT_PROTOCOL=${./modules/nixos/ci/scripts/cratedigger-world-audit-protocol.jq} \
                python3 ${./nix/checks/test_cratedigger_world_audit_protocol.py}
              grep -q 'MONITOR_INVOCATION_ID' ${notifier}
              if grep -q 'systemctl show' ${notifier}; then
                echo "Cratedigger notifier must use the OnFailure invocation ID" >&2
                exit 1
              fi
              touch "$out"
            '';

          aliYotoZipCheck =
            pkgs.runCommand "ali-yoto-zip" {
              nativeBuildInputs = [pkgs.python3];
            } ''
              ALI_YOTO_ZIP=${./modules/nixos/services/ali-cratedigger/zip-albums.py} \
                python3 ${./nix/checks/test_ali_yoto_zip.py}
              touch "$out"
            '';

          aliCratediggerIntegrationCheck = let
            doc2 = self.nixosConfigurations.doc2.config;
            container = doc2.containers.ali-cratedigger;
            containerService = doc2.systemd.services."container@ali-cratedigger";
            share = doc2.homelab.tailscaleShare.ali-music;
            yoto = doc2.homelab.services.yotoShare;
            firewallPorts = doc2.networking.firewall.interfaces.podman0.allowedTCPPorts;
            tmpfilesRules = doc2.systemd.tmpfiles.rules;
          in
            assert lib.assertMsg container.autoStart "Ali Cratedigger container must autostart";
            assert lib.assertMsg (!container.privateNetwork) "Ali Cratedigger requires the host network namespace for the private podman bridge gateway";
            assert lib.assertMsg (container.bindMounts."/mnt/virtio/music/slskd".hostPath == "/mnt/virtio/music/slskd") "Ali Cratedigger must share only the canonical slskd handoff";
            assert lib.assertMsg (container.bindMounts."/mnt/data/Media/Yoto/Music".hostPath == "/mnt/data/Media/Yoto/Music") "Ali's Beets library must be the Yoto Music publication tree";
            assert lib.assertMsg (container.bindMounts."/var/lib/postgresql".hostPath == "/var/lib/ali-cratedigger/postgresql") "Ali's PostgreSQL state must be independently persisted";
            assert lib.assertMsg container.bindMounts."/run/beets".isReadOnly "Ali's Beets secret directory must be mounted read-only";
            assert lib.assertMsg (builtins.elem "beets-runtime-ready.service" containerService.requires && builtins.elem "cratedigger-secrets-split.service" containerService.requires) "Ali's container must require its rendered secrets";
            assert lib.assertMsg (builtins.elem "beets-runtime-ready.service" containerService.partOf && builtins.elem "cratedigger-secrets-split.service" containerService.partOf) "Ali's container must restart when a bound secret producer restarts";
            assert lib.assertMsg (share.upstream == "http://host.docker.internal:18088") "Ali's share must reach only the private bridge gateway";
            assert lib.assertMsg (share.tags == ["tag:share"]) "Ali's node must retain the default-deny share tag";
            assert lib.assertMsg (builtins.elem 18088 firewallPorts) "Ali's gateway must be admitted on podman0";
            assert lib.assertMsg (yoto.shareDir == "/mnt/data/Media/Yoto" && yoto.booksDir == "/mnt/data/Media/Yoto/Books") "Yoto must publish separate Books and Music roots";
            assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto 2755 99 100 -" tmpfilesRules) "The all-squash NFS Yoto root must retain the server's anonymous identity";
            assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto/Books 2755 99 100 -" tmpfilesRules) "The all-squash NFS Books root must retain the server's anonymous identity";
            assert lib.assertMsg (builtins.elem "d /mnt/data/Media/Yoto/Music 2775 99 100 -" tmpfilesRules) "The all-squash NFS Music root must retain the writable anonymous identity";
              pkgs.runCommand "ali-cratedigger-integration" {
                nativeBuildInputs = [pkgs.gnugrep];
              } ''
                test -e ${container.path}/etc/systemd/system/cratedigger.service
                test -e ${container.path}/etc/systemd/system/cratedigger-web.service
                test -e ${container.path}/etc/systemd/system/ali-yoto-zip.service
                beets_dir=$(grep -o '/nix/store/[^" ]*-ali-beets-config' ${container.path}/etc/systemd/system/ali-beets-catalog-ready.service)
                test -n "$beets_dir"
                grep -q '^library: /mnt/virtio/ali-cratedigger/beets-db/beets-library.db' "$beets_dir/config.yaml"
                redis_prep=$(grep -o '/nix/store/[^ ]*-redis-cratedigger-prep-conf' ${container.path}/etc/systemd/system/redis-cratedigger.service)
                redis_config=$(grep -o '"/nix/store/[^"]*-redis.conf"' "$redis_prep" | tr -d '"')
                grep -q '^bind 127.0.0.1' "$redis_config"
                grep -q '^port 6380' "$redis_config"
                postgres_prep=$(grep -o '/nix/store/[^ ]*-postgresql-pre-start' ${container.path}/etc/systemd/system/postgresql.service)
                postgres_config=$(grep -o '"/nix/store/[^"]*-postgresql.conf/postgresql.conf"' "$postgres_prep/bin/postgresql-pre-start" | tr -d '"')
                grep -q "^listen_addresses = 'localhost'" "$postgres_config"
                container_etc=$(readlink -f ${container.path}/etc)
                grep -q '^d /mnt/data/Media/Yoto/Music 2775 99 100 -$' "$container_etc/tmpfiles.d/00-nixos.conf"
                grep -q 'After=.*ali-beets-catalog-ready.service' ${container.path}/etc/systemd/system/cratedigger.service
                grep -q '127.0.0.1:18088' ${container.path}/etc/nginx/nginx.conf
                grep -q '10.88.0.1:18088' ${container.path}/etc/nginx/nginx.conf
                if grep -q '0.0.0.0:18088' ${container.path}/etc/nginx/nginx.conf; then
                  echo 'Ali gateway widened beyond loopback and podman0' >&2
                  exit 1
                fi
                touch "$out"
              '';

          cratediggerTipCanaryCheck = let
            systemd = self.nixosConfigurations.proxmox-vm.config.systemd;
            service = systemd.services.cratedigger-beets-tip-canary;
            dailyService = systemd.services.cratedigger-daily-checks;
            notifier = systemd.services.cratedigger-beets-tip-canary-notify-failure.serviceConfig.ExecStart;
            timer = systemd.timers.cratedigger-beets-tip-canary.timerConfig;
            dailyTimer = systemd.timers.cratedigger-daily-checks.timerConfig;
            dailyPath = lib.concatStringsSep ":" (map toString dailyService.path);
            tipPath = lib.concatStringsSep ":" (map toString service.path);
            dailyTmpfs = lib.toList dailyService.serviceConfig.TemporaryFileSystem;
          in
            pkgs.runCommand "cratedigger-tip-canary" {
              nativeBuildInputs = [pkgs.gnugrep];
            } ''
              case '${service.serviceConfig.ExecStart}' in
                *'/scripts/daily_beets_tip_update.sh') ;;
                *) echo "Beets tip canary must run only the tip candidate" >&2; exit 1 ;;
              esac
              grep -q 'MONITOR_INVOCATION_ID' ${notifier}
              grep -q 'cratedigger-beets-tip-canary.service' ${notifier}
              test '${service.environment.CRATEDIGGER_AUTOMATION_STATE_DIR}' = '/var/lib/cratedigger-daily-checks'
              test '${service.serviceConfig.StateDirectory}' = 'cratedigger-daily-checks'
              test '${dailyService.environment.GH_CONFIG_DIR}' != '${service.environment.GH_CONFIG_DIR}'
              test '${dailyService.environment.XDG_RUNTIME_DIR}' != '${service.environment.XDG_RUNTIME_DIR}'
              test '${dailyService.serviceConfig.RuntimeDirectory}' != '${service.serviceConfig.RuntimeDirectory}'
              test '${dailyService.serviceConfig.TimeoutStartSec}' = '17h'
              test '${service.serviceConfig.TimeoutStartSec}' = '17h'
              test '${toString (builtins.length dailyTmpfs)}' = '2'
              test '${toString (lib.count (entry: entry == "/mnt") dailyTmpfs)}' = '1'
              test '${toString (lib.count (entry: entry == "/run/cratedigger-daily-checks/scratch:rw,size=16G,nr_inodes=10000000,mode=0700,uid=1000,gid=100") dailyTmpfs)}' = '1'
              case '${dailyPath}' in *util-linux*) ;; *) echo "daily candidate lacks flock" >&2; exit 1 ;; esac
              case '${tipPath}' in *util-linux*) ;; *) echo "tip candidate lacks flock" >&2; exit 1 ;; esac
              test '${timer.OnCalendar}' = '*-*-* 18:05:00 Australia/Perth'
              test '${timer.OnCalendar}' != '${dailyTimer.OnCalendar}'
              touch "$out"
            '';

          ytDlpTipVersionCheck = let
            ytDlp = self.nixosConfigurations.proxmox-vm.pkgs.yt-dlp;
            shortRev = builtins.substring 0 7 inputs.yt-dlp-src.rev;
          in
            pkgs.runCommand "yt-dlp-tip-version" {
              nativeBuildInputs = [pkgs.python3Packages.packaging];
            } ''
              python -c 'from packaging.version import Version; Version("${ytDlp.version}")'
              case '${ytDlp.version}' in
                *'+git.${shortRev}') ;;
                *) echo 'yt-dlp version does not identify locked upstream tip ${shortRev}' >&2; exit 1 ;;
              esac
              touch "$out"
            '';

          # Claude Code and Codex share authored instructions, skills, agents,
          # MCP declarations, and durable memory. Fail closed when a symlink is
          # broken, a generated Codex adapter drifts, a skill is undiscoverable,
          # or always-loaded context grows past its explicit budget.
          # See docs/wiki/claude-code/poly-ai-shared-surfaces.md.
          aiPortabilityCheck = let
            ntfyRuntimeCheck = pkgs.writeText "check-hermes-ntfy-runtime.py" ''
              from gateway.platform_registry import platform_registry
              from hermes_cli.config import load_config
              from hermes_cli.plugins import discover_plugins, get_plugin_manager
              from hermes_cli.tools_config import _get_platform_tools

              discover_plugins(force=True)
              loaded = get_plugin_manager()._plugins.get("ntfy-platform")
              assert loaded is not None and loaded.enabled, "ntfy-platform plugin is not enabled"
              assert "ntfy" in {entry.name for entry in platform_registry.plugin_entries()}

              config = load_config()
              effective = set(_get_platform_tools(config, "ntfy"))
              cli_effective = set(_get_platform_tools(config, "cli"))
              assert effective == cli_effective, sorted(effective ^ cli_effective)
              required = {
                  "browser",
                  "code_execution",
                  "computer_use",
                  "delegation",
                  "file",
                  "homeassistant",
                  "nixos",
                  "pfsense",
                  "playwright",
                  "terminal",
                  "unifi",
              }
              assert required <= effective, sorted(required - effective)
            '';
          in
            pkgs.runCommand "ai-portability" {} ''
              ${pkgs.python3}/bin/python3 ${./.}/scripts/generate-ai-adapters.py --check
              ${pkgs.python3}/bin/python3 ${./.}/scripts/merge-toml-settings.py --self-test
              ${pkgs.yq-go}/bin/yq -o=json \
                ${./.}/hermes/config/default/config.yaml \
                | ${pkgs.jq}/bin/jq -e \
                  '.plugins.enabled | contains(["platforms/ntfy"])' >/dev/null
              ${pkgs.yq-go}/bin/yq -o=json \
                ${./.}/hermes/config/default/config.yaml \
                | ${pkgs.jq}/bin/jq -e \
                  '.platform_toolsets.ntfy == .platform_toolsets.cli' >/dev/null
              ${pkgs.yq-go}/bin/yq -o=json \
                ${./.}/hermes/config/default/config.yaml \
                | ${pkgs.jq}/bin/jq -e \
                  '.known_plugin_toolsets.ntfy == .known_plugin_toolsets.cli' >/dev/null
              hermes_python="$(${pkgs.gnugrep}/bin/grep '^export HERMES_PYTHON=' \
                ${pkgs.hermes-agent}/bin/hermes | ${pkgs.coreutils}/bin/cut -d"'" -f2)"
              test -x "$hermes_python"
              export HERMES_HOME="$TMPDIR/hermes-home"
              export HERMES_BUNDLED_PLUGINS=${pkgs.hermes-agent}/share/hermes-agent/plugins
              mkdir -p "$HERMES_HOME"
              cp ${./.}/hermes/config/default/config.yaml "$HERMES_HOME/config.yaml"
              "$hermes_python" ${ntfyRuntimeCheck}
              touch $out
            '';
        in
          {inherit errorPatternsCheck hostBindAuditCheck podman6CutoverCheck containerNetworkAuditCheck unitHardeningAuditCheck bddayIntegrationCheck cullenBdProxyCheck audiobookshelfCacheCleanupCheck doc2CrashCaptureCheck onLanMatcherCheck bastionInvariantCheck fleetBastionRoleCheck pushDeployEnrollmentCheck sopsRecipientScopeCheck allowedSignersCheck fleetUpdateCheck rollingFlakeUpdateSigningCheck secretArgvAuditCheck nixpkgsFollowsCheck cratediggerDailySummaryCheck aliYotoZipCheck aliCratediggerIntegrationCheck cratediggerTipCanaryCheck ytDlpTipVersionCheck aiPortabilityCheck;}
          // (
            if !fullCheck
            then {}
            else if hostFilter == null
            then hostChecks
            else lib.filterAttrs (name: _: lib.elem name hostFilter) hostChecks
          );
      };
    };
}
