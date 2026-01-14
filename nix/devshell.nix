# Developer UX: repo-wide formatter, dev shell, and helper apps.
# - `nix fmt` uses Alejandra and writes only if content changes.
# - `nix run .#fmt-nix -- --check` lists files that WOULD change (no writes).
# - `nix run .#fmt-nix -- --diff` prints unified diffs (no writes).
# - `lint-nix` runs deadnix + statix with flag detection + panic handling.
#
# Important detail:
# - Alejandra writes in-place when given real paths. To keep --check/--diff pure,
#   we always format a *copy* in a temp dir, compare with `cmp`, and only replace
#   the original file during --write (via a same-dir temp for near-atomic mv).
{
  pkgs,
  lib,
  terranixConfig,
  ...
}: let
  # OpenTofu wrapper scripts
  tofuInit = pkgs.writeShellApplication {
    name = "tofu-init";
    runtimeInputs = [pkgs.opentofu];
    text = ''
      set -euo pipefail
      WORKDIR="''${TOFU_WORKDIR:-$PWD/vms/tofu/.state}"
      mkdir -p "$WORKDIR"
      cp ${terranixConfig} "$WORKDIR/config.tf.json"
      cd "$WORKDIR"
      tofu init "$@"
    '';
  };

  tofuPlan = pkgs.writeShellApplication {
    name = "tofu-plan";
    runtimeInputs = [pkgs.opentofu];
    text = ''
      set -euo pipefail
      WORKDIR="''${TOFU_WORKDIR:-$PWD/vms/tofu/.state}"
      mkdir -p "$WORKDIR"
      cp ${terranixConfig} "$WORKDIR/config.tf.json"
      cd "$WORKDIR"
      [ -d .terraform ] || tofu init
      tofu plan -out=tfplan "$@"
    '';
  };

  tofuApply = pkgs.writeShellApplication {
    name = "tofu-apply";
    runtimeInputs = [pkgs.opentofu];
    text = ''
      set -euo pipefail
      WORKDIR="''${TOFU_WORKDIR:-$PWD/vms/tofu/.state}"
      mkdir -p "$WORKDIR"
      cp ${terranixConfig} "$WORKDIR/config.tf.json"
      cd "$WORKDIR"
      [ -d .terraform ] || tofu init
      if [ -f tfplan ]; then
        tofu apply tfplan
        rm tfplan
      else
        tofu apply "$@"
      fi
    '';
  };

  tofuDestroy = pkgs.writeShellApplication {
    name = "tofu-destroy";
    runtimeInputs = [pkgs.opentofu];
    text = ''
      set -euo pipefail
      WORKDIR="''${TOFU_WORKDIR:-$PWD/vms/tofu/.state}"
      mkdir -p "$WORKDIR"
      cp ${terranixConfig} "$WORKDIR/config.tf.json"
      cd "$WORKDIR"
      [ -d .terraform ] || tofu init
      tofu destroy "$@"
    '';
  };

  tofuOutput = pkgs.writeShellApplication {
    name = "tofu-output";
    runtimeInputs = [pkgs.opentofu];
    text = ''
      set -euo pipefail
      WORKDIR="''${TOFU_WORKDIR:-$PWD/vms/tofu/.state}"
      cd "$WORKDIR"
      tofu output "$@"
    '';
  };

  tofuShow = pkgs.writeShellApplication {
    name = "tofu-show";
    runtimeInputs = [pkgs.opentofu pkgs.jq];
    text = ''
      set -euo pipefail
      echo "=== Terranix Generated Config ==="
      ${pkgs.jq}/bin/jq . ${terranixConfig}
    '';
  };

  # Alejandra-based formatter wrapper with write/check/diff modes.
  fmtNix = pkgs.writeShellApplication {
    name = "fmt-nix";
    runtimeInputs = [
      pkgs.alejandra
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
        --write  (default) format files in place (only if content changes)
        --check  report files that would change; no writes; exit 1 if any
        --diff   print diffs of changes; no writes; exit 1 if any
      If FILES are omitted, formats all tracked *.nix files (or falls back to find).
      EOF
                  exit 0
                  ;;
              esac
            fi

            # Collect targets
            files=()
            if [ $# -gt 0 ]; then
              for f in "$@"; do
                [ -f "$f" ] || continue
                case "$f" in *.nix) files+=("$f");; esac
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

            # Format $1 in a temp directory; never touches the original.
            # Prints the temp file path; caller must clean up its parent dir.
            format_to_tmp() {
              local src="$1"
              local tmpdir tmpfile
              tmpdir="$(mktemp -d)"
              tmpfile="$tmpdir/$(basename "$src")"
              cp "$src" "$tmpfile"
              # Alejandra writes in-place; run it on the COPY and be quiet.
              if ! alejandra --quiet "$tmpfile" >/dev/null 2>&1; then
                rm -rf "$tmpdir"
                echo "formatter failed on: $src" >&2
                return 2
              fi
              printf '%s\n' "$tmpfile"
              return 0
            }

            changed=0
            case "$MODE" in
              --write)
                for f in "''${files[@]}"; do
                  tmp="$(format_to_tmp "$f")" || exit $?
                  # Only replace if content actually changed; use same-dir temp for near-atomic mv
                  if ! cmp -s "$f" "$tmp"; then
                    final="$(mktemp -p "$(dirname "$f")")"
                    cp "$tmp" "$final"
                    mv "$final" "$f"
                  fi
                  rm -rf "$(dirname "$tmp")"
                done
                ;;

              --check|--diff)
                for f in "''${files[@]}"; do
                  tmp="$(format_to_tmp "$f")" || exit $?
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
                  rm -rf "$(dirname "$tmp")"
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
    runtimeInputs = [pkgs.deadnix pkgs.statix pkgs.coreutils];
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

  # VM Provisioning Tools
  vmTools = import ../vms/package.nix {inherit pkgs;};
in {
  # Make `nix fmt` use Alejandra across the whole repo (defaults to --write).
  formatter = fmtNix;

  # Expose helpers as packages + apps so you can `nix run .#...`
  packages = {
    lint-nix = lintNix;
    fmt-nix = fmtNix;
    inherit (vmTools) proxmox-ops provision-vm post-provision-vm new-vm;
    # OpenTofu/Terranix tools
    tofu-init = tofuInit;
    tofu-plan = tofuPlan;
    tofu-apply = tofuApply;
    tofu-destroy = tofuDestroy;
    tofu-output = tofuOutput;
    tofu-show = tofuShow;
  };

  apps = {
    lint-nix = {
      type = "app";
      program = "${lib.getExe lintNix}";
      meta.description = "Run deadnix + statix with robust flags and panic detection.";
    };
    fmt-nix = {
      type = "app";
      program = "${lib.getExe fmtNix}";
      meta.description = "Format Nix files with Alejandra.";
    };
    proxmox-ops = {
      type = "app";
      program = "${lib.getExe vmTools.proxmox-ops}";
      meta.description = "Proxmox VM operations via SSH";
    };
    provision-vm = {
      type = "app";
      program = "${lib.getExe vmTools.provision-vm}";
      meta.description = "Provision a new VM from definition";
    };
    new-vm = {
      type = "app";
      program = "${lib.getExe vmTools.new-vm}";
      meta.description = "Interactive VM creation wizard";
    };
    post-provision-vm = {
      type = "app";
      program = "${lib.getExe vmTools.post-provision-vm}";
      meta.description = "Post-provisioning fleet integration";
    };
    # OpenTofu/Terranix apps
    tofu-init = {
      type = "app";
      program = "${lib.getExe tofuInit}";
      meta.description = "Initialize OpenTofu working directory";
    };
    tofu-plan = {
      type = "app";
      program = "${lib.getExe tofuPlan}";
      meta.description = "Generate OpenTofu execution plan for Proxmox VMs";
    };
    tofu-apply = {
      type = "app";
      program = "${lib.getExe tofuApply}";
      meta.description = "Apply OpenTofu plan to create/update Proxmox VMs";
    };
    tofu-destroy = {
      type = "app";
      program = "${lib.getExe tofuDestroy}";
      meta.description = "Destroy OpenTofu-managed Proxmox VMs";
    };
    tofu-output = {
      type = "app";
      program = "${lib.getExe tofuOutput}";
      meta.description = "Show OpenTofu outputs (VM IPs, etc.)";
    };
    tofu-show = {
      type = "app";
      program = "${lib.getExe tofuShow}";
      meta.description = "Show generated Terranix/OpenTofu config";
    };
  };

  # Standard dev shell for this repo.
  devShells.default = pkgs.mkShellNoCC {
    packages = [
      pkgs.git
      pkgs.home-manager
      pkgs.nixd
      pkgs.alejandra
      pkgs.deadnix
      pkgs.statix
      pkgs.opentofu
      lintNix
      fmtNix
      # VM Provisioning tools
      vmTools.proxmox-ops
      vmTools.provision-vm
      vmTools.new-vm
      vmTools.post-provision-vm
      # OpenTofu/Terranix tools
      tofuInit
      tofuPlan
      tofuApply
      tofuDestroy
      tofuOutput
      tofuShow
    ];
    shellHook = ''
      echo "Dev shell ready."
      echo "  - lint-nix"
      echo "  - nix fmt                (write with Alejandra)"
      echo "  - nix run .#fmt-nix -- --check"
      echo "  - nix run .#fmt-nix -- --diff"
      echo ""
      echo "VM Provisioning:"
      echo "  - nix run .#new-vm                 Create config + provision"
      echo "  - provision-vm <name>         Provision a new VM"
      echo "  - post-provision-vm <name> <ip> <vmid>  Integrate VM into fleet"
      echo "  - proxmox-ops <command>       Proxmox operations"
      echo ""
      echo "OpenTofu (Terranix):"
      echo "  - tofu-show               Show generated config"
      echo "  - tofu-plan               Plan VM changes"
      echo "  - tofu-apply              Apply VM changes"
      echo "  - tofu-output             Show outputs (IPs)"
    '';
  };
}
