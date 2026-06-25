# Central list of overlays applied across the repo.
# Purpose:
# - Keep all package customisations in one place.
# - Ensure devShells, checks, NixOS, and Home Manager see the same pkgs.
#
# Notes:
# - nvchad is sourced from the nvchad4nix flake for the current system.
# - yt-dlp builds from the pinned flake input and carries a readable version tag.
# - If an overlay needs the system string, prefer prev.stdenv.hostPlatform.system
#   (that keeps it correct under cross and matches flake-parts guidance).
{inputs}: [
  # nvchad overlay: expose nvchad for the active platform
  (final: _prev: {
    # Use `inherit` to bring a variable into scope, which is idiomatic when the attribute name matches.
    inherit (inputs.nvchad4nix.packages.${final.stdenv.hostPlatform.system}) nvchad;
  })

  # yt-dlp overlay: build from flake input and stamp version with short rev
  (
    _final: prev: let
      rev = inputs.yt-dlp-src.rev or null;
      short =
        if rev == null
        then "unknown"
        else builtins.substring 0 7 rev;
    in {
      yt-dlp = prev.yt-dlp.overrideAttrs (old: {
        src = inputs.yt-dlp-src; # pinned source for reproducibility
        version = "master-${short}"; # human-friendly debugging aid
        # Upstream master moves fast; drop nixpkgs' curl-cffi patch when it no longer applies.
        patches = builtins.filter (
          patch: let
            name = toString patch;
          in
            builtins.match ".*curlcffi.*" name
            == null
            && builtins.match ".*curl-cffi.*" name == null
        ) (old.patches or []);
        postPatch = let
          oldPostPatch = old.postPatch or "";
          oldLine = ''--replace-fail "if curl_cffi_version != (0, 5, 10) and not (0, 10) <= curl_cffi_version < (0, 14)" \'';
          newLine = ''--replace "if curl_cffi_version != (0, 5, 10) and not (0, 10) <= curl_cffi_version < (0, 14)" \'';
        in
          prev.lib.replaceStrings [oldLine] [newLine] oldPostPatch;
        # doCheck = false;                    # unblock if upstream toggles tests
      });
    }
  )

  # jolt overlay: fix upstream feature flag regression (linux -> jolt-platform/linux)
  (
    final: _prev: let
      upstream = inputs.jolt.packages.${final.stdenv.hostPlatform.system}.default;
    in {
      jolt = upstream.overrideAttrs (_old: {
        cargoBuildFeatures = ["jolt-platform/linux"];
      });
    }
  )

  # claude-code overlay: use auto-updating flake (hourly GitHub Actions updates)
  (
    final: _prev: {
      inherit (inputs.claude-code-nix.packages.${final.stdenv.hostPlatform.system}) claude-code;
    }
  )

  # codex overlay: use fast-updating community flake
  (
    final: _prev: {
      inherit (inputs.codex-cli-nix.packages.${final.stdenv.hostPlatform.system}) codex codex-node;
    }
  )

  # unifi-mcp overlay: auto-generated MCP server for UniFi Network Controller
  (
    final: _prev: {
      unifi-mcp = inputs.unifi-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # pfsense-mcp overlay: auto-generated MCP server for pfSense REST API v2
  (
    final: _prev: {
      pfsense-mcp = inputs.pfsense-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # slskd-mcp overlay: MCP server for slskd (Soulseek client)
  (
    final: _prev: {
      slskd-mcp = inputs.slskd-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # vinsight-mcp overlay: MCP server for Vinsight winery API
  (
    final: _prev: {
      vinsight-mcp = inputs.vinsight-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # vinsight-local overlay: FastAPI server + SQLite mirror tool built from
  # the cellar-manager source tree. Consumed by the cullen-dashboard service
  # on wsl. Bundles spec/metadata under $out/share since pyproject.toml only
  # ships the python package itself.
  (
    final: _prev: {
      vinsight-local = final.python3Packages.buildPythonApplication {
        pname = "vinsight-local";
        version = "0.1.0";
        pyproject = true;
        src = inputs.cellar-manager + "/vinsight-local";

        build-system = with final.python3Packages; [hatchling];

        dependencies = with final.python3Packages; [
          httpx
          fastapi
          uvicorn
        ];

        postInstall = ''
          mkdir -p $out/share/vinsight-local
          cp -r ${inputs.cellar-manager + "/vinsight-local/spec"} $out/share/vinsight-local/spec
        '';

        doCheck = false;
      };
    }
  )

  # netwatch overlay: real-time network diagnostics TUI from upstream flake
  (
    final: _prev: {
      netwatch = inputs.netwatch.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # sheets overlay: terminal spreadsheet from upstream flake
  (
    final: _prev: {
      sheets = inputs.sheets.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # MusicBrainz PostgreSQL AMQP extension, pinned to upstream docker build ref.
  (
    _final: prev: {
      musicbrainz-pg-amqp = prev.callPackage ./pkgs/musicbrainz-pg-amqp.nix {
        postgresql = prev.postgresql_18;
        postgresqlBuildExtension = prev.callPackage "${inputs.nixpkgs}/pkgs/servers/sql/postgresql/postgresqlBuildExtension.nix" {
          postgresql = prev.postgresql_18;
        };
      };
    }
  )

  # netavark / aardvark-dns pin — last-known-good 1.17.x (nixpkgs rev 4a29d733,
  # 2026-05-21). nixpkgs bumped these to 2.0.0 (~2026-06-23); netavark 2.0.0
  # removed iptables support (nftables-only) and stopped installing the port-53
  # DNAT rule that steers container DNS to aardvark. Symptom: aardvark listens on
  # the bridge gateway with correct records, container-to-container traffic BY IP
  # works, but name lookups time out (`i/o timeout`). Every rootful-podman
  # service that resolves a sibling by name (immich/paperless DBs, the MusicBrainz
  # web stack → cratedigger) breaks on its NEXT reboot. doc2 hit it first
  # (incident 2026-06-25). Pin both back together (they are version-paired) until
  # upstream netavark 2.x applies the rules reliably. fetchTarball is sha256-pinned
  # so the nightly flake update can't drag it forward. Revisit when a verified
  # netavark >= 2.x lands. See docs/wiki/infrastructure/netavark-2.0-dns-regression.md
  (
    _final: prev: let
      goodPkgs = import (builtins.fetchTarball {
        url = "https://github.com/NixOS/nixpkgs/archive/4a29d733e8a7d5b824c3d8c958a946a9867b3eb2.tar.gz";
        sha256 = "1xgk8ph3k64719xmh1pwsq04c60rjirrvlk0yy39zkganh4l1qkz";
      }) {inherit (prev.stdenv.hostPlatform) system;};
    in {
      inherit (goodPkgs) netavark aardvark-dns;
    }
  )
]
