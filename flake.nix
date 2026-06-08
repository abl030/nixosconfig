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
            igpu=age17pejn8m9tz063y3waahgyyn365n22hzgg5hr64ey7wk79ee8ccmsh8z294
            epi=age1gr4papzzdqfxd34ushr88303f2ypdwvgx9cw2xqs87yn4zf8lpxqc0rur5
            fw=age1ysfdznu87vwwqtpudchkyx0wlhuhteqljrqkt6963pcmhwprlgcqasg0gv
            wsl=age10hqxw3uxvg9nkc56rm495ty0rge0yhkcqp95gx00tgsv8ptg93mqwywlja
            cache=age1cd4wnte9ffe65ysqzvtkwu5uzvvxn9xeln7n5ctkjsk4c589fc5qkt397e
            allhosts="$doc1 $doc2 $igpu $epi $fw $wsl $cache"
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
                cache) own=$cache ;;
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
        in
          {inherit errorPatternsCheck onLanMatcherCheck bastionInvariantCheck sopsRecipientScopeCheck;}
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
