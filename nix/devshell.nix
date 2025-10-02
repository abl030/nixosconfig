# Developer UX: repo-wide formatter, dev shell, and helper apps.
# - `nix fmt` uses nixfmt
# - `nix develop` drops you into a shell with deadnix/statix/etc.
# - `lint-nix` runs deadnix + statix together (also exposed as a flake app)

{ pkgs, lib, ... }:
let
  lintNix = pkgs.writeShellApplication {
    name = "lint-nix";
    text = ''
      set -uo pipefail
      ec=0

      echo "▶ deadnix"
      if ! deadnix --no-progress --fail-on-warnings .; then
        ec=$((ec | 1))
      fi
      echo

      echo "▶ statix"
      if ! statix check .; then
        ec=$((ec | 2))
      fi
      echo

      if [ "$ec" -eq 0 ]; then
        echo "✓ no issues found by deadnix or statix"
      else
        echo "✗ issues detected (exit=$ec) — (1=deadnix, 2=statix, 3=both)"
      fi
      exit "$ec"
    '';
  };
in
{
  # Repo-wide formatter so `nix fmt` is consistent locally and in CI.
  formatter = pkgs.nixfmt;

  # Publish helper both as a package and an app (so `nix run .#lint-nix` works).
  packages.lint-nix = lintNix;
  apps.lint-nix = { type = "app"; program = "${lib.getExe lintNix}"; };

  # Standard dev shell for this repo.
  devShells.default = pkgs.mkShellNoCC {
    packages = [
      pkgs.git
      pkgs.home-manager
      pkgs.nixd
      pkgs.nixfmt
      pkgs.deadnix
      pkgs.statix
      lintNix
    ];
    shellHook = ''
      echo "Dev shell ready. Try: lint-nix"
    '';
  };
}

