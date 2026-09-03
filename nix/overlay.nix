# Central list of overlays applied across the repo.
# Purpose:
# - Keep all package customisations in one place.
# - Ensure devShells, checks, NixOS, and Home Manager see the same pkgs.
#
# Notes:
# - nvchad is sourced from the nvchad4nix flake for the current system.
# - yt-dlp tracks upstream git tip; its package version includes that tip's rev.
# - If an overlay needs the system string, prefer prev.stdenv.hostPlatform.system
#   (that keeps it correct under cross and matches flake-parts guidance).
{inputs}: [
  # nvchad overlay: expose nvchad for the active platform
  (final: _prev: {
    # Use `inherit` to bring a variable into scope, which is idiomatic when the attribute name matches.
    inherit (inputs.nvchad4nix.packages.${final.stdenv.hostPlatform.system}) nvchad;
  })

  # yt-dlp overlay: keep riding upstream tip while retaining a PEP 440 version.
  (
    _final: prev: let
      rev = inputs.yt-dlp-src.rev or (throw "yt-dlp-src must have a locked git revision");
      short = builtins.substring 0 7 rev;
      versionLine =
        prev.lib.findFirst
        (prev.lib.hasPrefix "__version__ = '")
        (throw "yt-dlp-src/yt_dlp/version.py has no __version__")
        (prev.lib.splitString "\n" (builtins.readFile (inputs.yt-dlp-src + "/yt_dlp/version.py")));
      upstreamVersion =
        prev.lib.removeSuffix "'"
        (prev.lib.removePrefix "__version__ = '" versionLine);
    in {
      yt-dlp = prev.yt-dlp.overrideAttrs (old: {
        src = inputs.yt-dlp-src;
        version = "${upstreamVersion}+git.${short}";
        nativeBuildInputs = (old.nativeBuildInputs or []) ++ [prev.python3Packages.pyprojectVersionPatchHook];
        # Upstream tip moves fast; retain nixpkgs patches except curl-cffi
        # compatibility patches that target its older packaged source.
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

  # Hermes Agent CLI: use the full upstream package output with optional
  # integrations included. This is only a package; the gateway service remains
  # disabled unless a host explicitly enables it.
  #
  # Upstream's pyproject.toml module list currently omits these two imported
  # state-store modules, so the built wheel cannot open state.db. Keep this
  # narrow supplement until upstream ships both modules in its Python package.
  (
    final: _prev: let
      stateStoreModules = final.python312Packages.buildPythonPackage {
        pname = "hermes-agent-state-store-modules";
        version = "${inputs.hermes-agent.lastModifiedDate or "unstable"}";
        format = "other";
        dontUnpack = true;
        installPhase = ''
          mkdir -p "$out/${final.python312.sitePackages}"
          copied=0
          for module in hermes_state_holders hermes_state_registry; do
            if ! grep -q "\"$module\"" ${inputs.hermes-agent}/pyproject.toml; then
              cp "${inputs.hermes-agent}/$module.py" "$out/${final.python312.sitePackages}/"
              copied=1
            fi
          done

          if [[ $copied -eq 0 ]]; then
            echo "Upstream now packages both state-store modules; remove this supplement." >&2
            exit 1
          fi
        '';
      };
    in {
      hermes-agent = inputs.hermes-agent.packages.${final.stdenv.hostPlatform.system}.default.override {
        extraPythonPackages = [stateStoreModules];
      };
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

  # slskd overlay: truncate local path segments to the filesystem's name limit.
  #
  # slskd sanitizes remote path segments for invalid characters but never for length
  # (FileSafety.SanitizePathSegment), so a peer directory name longer than 255 bytes makes every
  # download from that folder fail permanently with "the path is too long, or a component of the
  # specified path is too long". The limit is bytes on Unix, so names heavy in combining marks or
  # CJK overflow while still looking short. Reported upstream as slskd/slskd#1818.
  #
  # Truncation stops 24 bytes short of the cap. FileService.MoveFile resolves a destination
  # collision by appending "_{DateTime.UtcNow.Ticks}" (19 bytes) before the extension, so a name
  # truncated to exactly 255 overflows the moment that suffix is applied. Because truncation is
  # deterministic, a re-download collides at a byte-identical name every time; the move then throws
  # and the completed file is stranded in the incomplete directory with no completion event, which
  # is how this was found.
  #
  # Deliberately unguarded by version: if upstream lands a fix or reworks FileSafety, the patch
  # stops applying and the build fails loudly. That is the signal to drop this block, which is
  # better than silently carrying a stale delta behind a version check.
  (
    _final: prev: {
      slskd = prev.slskd.overrideAttrs (old: {
        patches = (old.patches or []) ++ [./pkgs/slskd-truncate-path-segments.patch];
      });
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

  # Temporary Podman 6 cutover (#13/#136). nixpkgs still carries Podman 5 and
  # Netavark 1.x even though the fleet needs Podman 6's synchronized networking
  # API and Netavark 2.1's missing-netns teardown fix. Keep the override surgical:
  # current nixpkgs already has compatible Buildah/Skopeo/Aardvark releases.
  # The version guard makes this a no-op as soon as nixpkgs ships Podman 6; remove
  # the block after the unmodified package set passes the Podman cutover check.
  (
    final: prev: let
      podmanNeedsOverride = prev.lib.versions.major prev.podman.version == "5";
      netavarkNeedsOverride = prev.lib.versionOlder prev.netavark.version "2.1";
      netavark =
        if netavarkNeedsOverride
        then
          prev.netavark.overrideAttrs (_old: rec {
            version = "2.1.0";
            src = prev.fetchFromGitHub {
              owner = "containers";
              repo = "netavark";
              tag = "v${version}";
              hash = "sha256-nTmbPKTIne4iIrX5KPWTkFc+SD1Th9/sOciAzThin9M=";
            };
            cargoDeps = prev.rustPlatform.fetchCargoVendor {
              inherit src;
              hash = "sha256-6ZYVQVLm9b71s5FPgTSzDmscEVLE9ZxKCg+4R+0hkUk=";
            };
          })
        else prev.netavark;
      podmanBase = prev.podman.override {
        inherit netavark;
        inherit (final) aardvark-dns;
      };
    in {
      inherit netavark;
      podman =
        if podmanNeedsOverride
        then
          podmanBase.overrideAttrs (_old: rec {
            version = "6.0.2";
            src = prev.fetchFromGitHub {
              owner = "podman-container-tools";
              repo = "podman";
              tag = "v${version}";
              hash = "sha256-hFUXo0q4KpH5YfnpfwKqfdOWe5rqXANjlUf/guZ3LTY=";
            };
          })
        else prev.podman;
    }
  )
]
