# ===== ./flake.nix =====
{
  description = "My first flake!";

  inputs = {
    # --- 1. The Anchors (Standard Libraries) ---
    # use the following for unstable:
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # (No dedicated MongoDB input. UniFi's MongoDB is the separately named
    # `pkgs.mongodb80` package in the overlay, built from MongoDB's official
    # Ubuntu 24.04 precompiled archive and advanced only by the signed rolling
    # updater's protected 8.0 patch transaction.)

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

    mrnews = {
      url = "git+https://git.ablz.au/abl030/mrnews";
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

        checks.x86_64-linux = import ./nix/checks {
          inherit self lib pkgs system hosts inputs signing;
        };
      };
    };
}
