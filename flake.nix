# ===== ./flake.nix =====
{
  description = "My first flake!";

  inputs = {
    # --- 1. The Anchors (Standard Libraries) ---
    # use the following for unstable:
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

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
    #NVCHAD is best chad.
    nvchad4nix = {
      url = "github:nix-community/nix4nvchad";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
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
    # 0.18.2 (614dc194) is missing packages/shared/src/charge-settlement.ts.
    # Pin the last known-good revision until upstream repairs the release.
    hermes-agent = {
      url = "github:nousresearch/hermes-agent?rev=07be37d996be7df1965441ca8bdacdb3f884c7e2";
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
            allhosts="$doc1 $doc2 $igpu $epi $fw $wsl $servarr"
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

              make_key human
              make_key bot
              {
                printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")"
                printf '"nix bot <acme@ablz.au>" namespaces="git" %s\n' "$(cat "$TMPDIR/bot.pub")"
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

              if run_fleet no-anchor "$linear_remote" "not-a-sha"; then
                echo "missing anchor was accepted without --accept-new-root" >&2
                exit 1
              fi

              : > "$TMPDIR/rebuilds"
              run_fleet accept-root "$linear_remote" "not-a-sha" --accept-new-root "$linear_base"
              test "$(cat "$TMPDIR/accept-root-anchor")" = "$linear_target"
              grep -q "rev=$linear_target#fixture-host" "$TMPDIR/rebuilds"

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
                printf '{"locks":{"root":"root","nodes":{"root":{"inputs":{}}}}}\n'
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

              run_update() {
                local remote="$1"
                local allowed="$2"
                local anchor_file="$3"
                REPO_DIR="$TMPDIR/local-source" \
                RFU_REMOTE_URL="file://$remote" \
                RFU_REQUIRE_SIGNED_BASE=1 \
                RFU_GIT_SIGNING_KEY="$TMPDIR/bot" \
                RFU_ALLOWED_SIGNERS_FILE="$allowed" \
                RFU_BASE_ANCHOR_FILE="$anchor_file" \
                RFU_FAILURE_DIR="$TMPDIR/failures" \
                ONLY_GROUP=none \
                ${pkgs.bash}/bin/bash ${./scripts/rolling_flake_update.sh}
              }

              make_key human
              make_key bot
              make_key other

              allowed_all="$TMPDIR/allowed-all"
              {
                printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")"
                printf '"nix bot <acme@ablz.au>" namespaces="git" %s\n' "$(cat "$TMPDIR/bot.pub")"
              } > "$allowed_all"

              allowed_human_only="$TMPDIR/allowed-human-only"
              printf 'fixture-human namespaces="git" %s\n' "$(cat "$TMPDIR/human.pub")" > "$allowed_human_only"

              valid_remote="$(make_signed_remote valid "$TMPDIR/human")"
              valid_anchor="$TMPDIR/valid-anchor"
              valid_before="$(git --git-dir="$valid_remote" rev-parse refs/heads/master)"
              printf '%s\n' "$valid_before" > "$valid_anchor"
              run_update "$valid_remote" "$allowed_all" "$valid_anchor"
              git clone -q "$valid_remote" "$TMPDIR/valid-inspect"
              git -C "$TMPDIR/valid-inspect" -c "gpg.ssh.allowedSignersFile=$allowed_all" verify-commit HEAD
              test "$(git -C "$TMPDIR/valid-inspect" log --format=%s -1)" = "rolling: freshness heartbeat ($(date +%F))"
              test "$(cat "$valid_anchor")" = "$(git --git-dir="$valid_remote" rev-parse refs/heads/master)"

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

          # Claude Code and Codex share authored instructions, skills, agents,
          # MCP declarations, and durable memory. Fail closed when a symlink is
          # broken, a generated Codex adapter drifts, a skill is undiscoverable,
          # or always-loaded context grows past its explicit budget.
          # See docs/wiki/claude-code/poly-ai-shared-surfaces.md.
          aiPortabilityCheck = pkgs.runCommand "ai-portability" {} ''
            ${pkgs.python3}/bin/python3 ${./.}/scripts/generate-ai-adapters.py --check
            ${pkgs.python3}/bin/python3 ${./.}/scripts/merge-toml-settings.py --self-test
            touch $out
          '';
        in
          {inherit errorPatternsCheck hostBindAuditCheck containerNetworkAuditCheck unitHardeningAuditCheck onLanMatcherCheck bastionInvariantCheck fleetBastionRoleCheck sopsRecipientScopeCheck allowedSignersCheck fleetUpdateCheck rollingFlakeUpdateSigningCheck nixpkgsFollowsCheck aiPortabilityCheck;}
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
