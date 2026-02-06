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

  # unifi-mcp overlay: auto-generated MCP server for UniFi Network Controller
  (
    final: _prev: {
      unifi-mcp = inputs.unifi-mcp.packages.${final.stdenv.hostPlatform.system}.default;
    }
  )
]
