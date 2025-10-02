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
  (final: prev: {
    nvchad =
      inputs.nvchad4nix.packages.${final.stdenv.hostPlatform.system}.nvchad;
  })

  # yt-dlp overlay: build from flake input and stamp version with short rev
  (
    final: prev: let
      rev = inputs.yt-dlp-src.rev or null;
      short =
        if rev == null
        then "unknown"
        else builtins.substring 0 7 rev;
    in {
      yt-dlp = prev.yt-dlp.overrideAttrs (_old: {
        src = inputs.yt-dlp-src; # pinned source for reproducibility
        version = "master-${short}"; # human-friendly debugging aid
        # doCheck = false;                    # unblock if upstream toggles tests
      });
    }
  )
]
