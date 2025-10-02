# Developer UX: repo-wide formatter, dev shell, and helper apps.
# - `nix fmt` runs a wrapper that formats all *.nix files in-place.
# - `nix run .#fmt-nix -- --check` shows which files WOULD change (exit 1 if any).
# - `nix run .#fmt-nix -- --diff` prints unified diffs (exit 1 if any).
# - `lint-nix` runs deadnix + statix with flag detection + panic handling.
#
# Notes:
# - Avoid NUL-delimited reads and `-d ''` to keep the Nix string stable.
# - Use newline-delimited collection via git/find; good enough for Git paths.

{ pkgs, lib, ... }:
let
  # Wrapper that formats all Nix files, with dry-run and diff modes.
  # Reason: `nix fmt` runs the formatter with *no args*; `nixfmt` then waits on stdin.
  # This wrapper discovers files and invokes nixfmt correctly across versions.
  fmtNix = pkgs.writeShellApplication {
    name = "fmt-nix";
    runtimeInputs = [
      pkgs.nixfmt
      pkgs.findutils
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
    ];
    text = ''
            set -euo pipefail

            MODE="--write"
            if [ $# -gt 0 ]; then
              case "$1" in
                --write|--check|--diff) MODE="$1"; shift ;;
                --help|-h)
                  cat <<'EOF'
      Usage: fmt-nix [--write|--check|--diff] [FILES...]
        --write  (default) format files in place
        --check  report files that would change; no writes; exit 1 if any
        --diff   print diffs of changes; no writes; exit 1 if any
      If FILES are omitted, formats all tracked *.nix files (or falls back to find).
      EOF
                  exit 0
                  ;;
              esac
            fi

            # Collect targets (newline-delimited; Git paths are newline-safe in practice)
            files=()
            if [ $# -gt 0 ]; then
              for f in "$@"; do
                [ -f "$f" ] || continue
                case "$f" in
                  *.nix) files+=("$f") ;;
                esac
              done
            else
              if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                while IFS= read -r f; do
                  [ -n "$f" ] && files+=("$f")
                done < <(git ls-files -- '*.nix')
              else
                while IFS= read -r f; do
                  [ -n "$f" ] && files+=("$f")
                done < <(find . -type f -name "*.nix" \
                           -not -path "./.git/*" \
                           -not -path "./.direnv/*" \
                           -not -path "./result*" \
                           -print)
              fi
            fi

            [ "''${#files[@]}" -eq 0 ] && exit 0

            # Detect nixfmt write flag support
            HAS_W=false
            if nixfmt --help 2>&1 | grep -qE '\s-w(,|\s|$)'; then
              HAS_W=true
            fi

            changed=0
            case "$MODE" in
              --write)
                if [ "$HAS_W" = true ]; then
                  nixfmt -w "''${files[@]}"
                else
                  for f in "''${files[@]}"; do
                    tmp="$(mktemp)"
                    nixfmt "$f" > "$tmp"
                    if ! cmp -s "$f" "$tmp"; then
                      mv "$tmp" "$f"
                    else
                      rm -f "$tmp"
                    fi
                  done
                fi
                ;;

              --check|--diff)
                for f in "''${files[@]}"; do
                  tmp="$(mktemp)"
                  if ! nixfmt "$f" > "$tmp"; then
                    echo "formatter failed on: $f" >&2
                    rm -f "$tmp"
                    exit 2
                  fi
                  if ! cmp -s "$f" "$tmp"; then
                    changed=1
                    if [ "$MODE" = "--check" ]; then
                      echo "would format: $f"
                    else
                      echo "diff: $f"
                      diff -u "$f" "$tmp" || true
                      echo
                    fi
                  fi
                  rm -f "$tmp"
                done
                if [ "$changed" -ne 0 ]; then
                  exit 1
                fi
                ;;
            esac
    '';
  };

  # Lint wrapper: deadnix + statix with robust flags and panic detection.
  lintNix = pkgs.writeShellApplication {
    name = "lint-nix";
    runtimeInputs = [ pkgs.deadnix pkgs.statix pkgs.coreutils ];
    text = ''
      set -uo pipefail

      # ---- deadnix: feature-detect flags ----
      DEADNIX_FLAGS=""
      if deadnix --help 2>&1 | grep -q -- "--no-progress"; then
        DEADNIX_FLAGS="$DEADNIX_FLAGS --no-progress"
      fi
      if deadnix --help 2>&1 | grep -q -- "--fail-on-warnings"; then
        DEADNIX_FLAGS="$DEADNIX_FLAGS --fail-on-warnings"
      fi

      ec=0
      echo "▶ deadnix"
      if ! eval "deadnix $DEADNIX_FLAGS ."; then
        ec=$((ec | 1))
      fi
      echo

      echo "▶ statix"
      tmp="$(mktemp -t lint-nix.statix.XXXXXX)"
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
  # Make `nix fmt` work on the whole repo (defaults to --write).
  formatter = fmtNix;

  # Expose helpers as packages + apps so you can `nix run .#...`
  packages.lint-nix = lintNix;
  packages.fmt-nix = fmtNix;

  apps.lint-nix = { type = "app"; program = "${lib.getExe lintNix}"; };
  apps.fmt-nix = { type = "app"; program = "${lib.getExe fmtNix}"; };

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
      fmtNix
    ];
    shellHook = ''
      echo "Dev shell ready."
      echo "  - lint-nix"
      echo "  - nix fmt                (write)"
      echo "  - nix run .#fmt-nix -- --check"
      echo "  - nix run .#fmt-nix -- --diff"
    '';
  };
}

