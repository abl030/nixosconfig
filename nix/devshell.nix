# Developer UX: repo-wide formatter, dev shell, and helper apps.
# - `nix fmt` uses nixfmt
# - `nix develop` drops you into a shell with deadnix/statix/etc.
# - `lint-nix` runs deadnix + statix together with robust flag detection and
#   panic handling so CI/local runs are stable across tool versions.

{ pkgs, lib, ... }:
let
  lintNix = pkgs.writeShellApplication {
    name = "lint-nix";
    text = ''
      set -uo pipefail

      # ---- deadnix: build flags dynamically based on what's supported ----
      DEADNIX_FLAGS=""
      if deadnix --help 2>&1 | grep -q -- "--no-progress"; then
        DEADNIX_FLAGS="$DEADNIX_FLAGS --no-progress"
      fi
      # Many deadnix builds already exit non-zero on findings; if a future
      # build supports --fail-on-warnings, we add it transparently:
      if deadnix --help 2>&1 | grep -q -- "--fail-on-warnings"; then
        DEADNIX_FLAGS="$DEADNIX_FLAGS --fail-on-warnings"
      fi

      ec=0
      echo "▶ deadnix"
      if ! eval "deadnix $DEADNIX_FLAGS ."; then
        # bit 1 indicates deadnix reported issues or failed
        ec=$((ec | 1))
      fi
      echo

      # ---- statix: capture output, detect panics, convert to stable exit ----
      echo "▶ statix"
      tmp="$(mktemp -t lint-nix.statix.XXXXXX)"
      # Use tee so the user sees output as well as we can parse it.
      if statix check . 2>&1 | tee "$tmp"; then
        statix_rc=0
      else
        statix_rc=1
      fi

      if grep -q "thread 'main' panicked" "$tmp"; then
        echo
        echo "note: statix crashed (upstream bug). Treating as a failure but continuing."
        statix_rc=1
      fi
      rm -f "$tmp"

      if [ "$statix_rc" -ne 0 ]; then
        # bit 2 indicates statix reported issues or crashed
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

