# Central overlay list for pkgs.
# This isolates package customisations from flake topology so they can be reused
# by both system and home builds without touching flake outputs.
# Keep overlays small and self-contained; each overlay declares only what it owns.

{ inputs }:

[
  # Expose nvchad from the nvchad4nix flake
  (final: prev: {
    # Use the current pkgs system so this works anywhere the overlay is applied.
    nvchad = inputs.nvchad4nix.packages.${prev.system}.nvchad;
  })

  # Track yt-dlp master from flake input; stamp version with short rev
  (final: prev:
    let
      # Guard for non-git sources; version string stays readable either way.
      rev = inputs.yt-dlp-src.rev or null;
      short = if rev == null then "unknown" else builtins.substring 0 7 rev;
    in
    {
      yt-dlp = prev.yt-dlp.overrideAttrs (_old: {
        # Build from the flake input so updates are explicit and reproducible.
        src = inputs.yt-dlp-src;

        # Version marker helps `yt-dlp --version` debugging across hosts.
        version = "master-${short}";

        # If upstream flips tests and it blocks builds, you can temporarily:
        # doCheck = false;
      });
    }
  )
]

