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

    # --- 3. Hardware & WSL ---
    #nixos-hardware
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

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
    gaj-shared = {
      url = "gitlab:gaj-nixos/shared";
      flake = false;
    };

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

    jolt = {
      url = "github:jordond/jolt/6dd559cc8038f901a1150cdf5add608f65a5c52a";
      inputs.nixpkgs.follows = "nixpkgs";
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
    # before it lapses. refresh-access-tokens.nix degrades to empty-tokens on a
    # rejected PAT, so public fetches still survive a lapse.
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

    # sheets - terminal spreadsheet (Go)
    sheets = {
      url = "github:maaslalani/sheets";
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
        in
          {inherit errorPatternsCheck onLanMatcherCheck;}
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
