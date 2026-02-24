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

  # loki-mcp overlay: AI-friendly MCP server for Grafana Loki
  (
    final: _prev: {
      loki-mcp = inputs.loki-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )

  # lidarr-mcp overlay: MCP server for Lidarr music management
  (
    final: _prev: {
      lidarr-mcp = inputs.lidarr-mcp.packages.${final.stdenv.hostPlatform.system}.default;
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

  # plexamp overlay: pin to 4.12.3 — audio broken on Linux since 4.12.4
  # https://forums.plex.tv/t/plexamp-flatpak-appimage-does-not-start-playback-until-audio-device-switched/929631
  (
    _final: prev: {
      plexamp = prev.plexamp.overrideAttrs (_old: rec {
        version = "4.12.3";
        src = prev.fetchurl {
          url = "https://plexamp.plex.tv/plexamp.plex.tv/desktop/Plexamp-${version}.AppImage";
          name = "plexamp-${version}.AppImage";
          hash = "sha512-gjOjk/JtHbhEDGzWH/bBtNd7qsYS97hBlPbRw7uWH/PCXD4urUWBrlihNWAOgYClVwl7nbrx/y7mhCrI2N6c1w==";
        };
      });
    }
  )

  # beads overlay: git-native issue tracker for AI agent memory
  # TODO: drop overlay once nixpkgs beads catches up (currently 0.42.0, PR #483469 pending)
  # Upstream flake broken: https://github.com/steveyegge/beads/issues/1373
  (
    final: _prev: {
      beads = final.stdenv.mkDerivation rec {
        pname = "beads";
        version = "0.56.1";
        src = final.fetchurl {
          url = "https://github.com/steveyegge/beads/releases/download/v${version}/beads_${version}_linux_amd64.tar.gz";
          hash = "sha256-T59sxERloRYT/1KQCZAeqvhBxrH5HBXgArDs2iAVoVw=";
        };
        sourceRoot = ".";
        installPhase = ''
          install -Dm755 bd $out/bin/bd
          ln -s bd $out/bin/beads
        '';
        meta = with final.lib; {
          description = "Git-native issue tracker for AI agent memory";
          homepage = "https://github.com/steveyegge/beads";
          license = licenses.mit;
          platforms = ["x86_64-linux"];
          mainProgram = "bd";
        };
      };
    }
  )
]
