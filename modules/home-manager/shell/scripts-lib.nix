# modules/home-manager/shell/scripts-lib.nix
{pkgs}: let
  # Shared logic for copycr/copycf to avoid duplication
  copycrCommon = ''
    # ──────────────────────────────────────────────────────────────────────────────
    # Select subdirectories via TUI and print selections (one per line).
    # ──────────────────────────────────────────────────────────────────────────────
    _copycr_select_dirs() {
        local depth="''${1:-1}"
        local include_hidden="''${2:-0}"

        local -a find_args=(. -mindepth 1 -maxdepth "$depth" -type d)
        if [[ "$include_hidden" != "1" ]]; then
            find_args+=(-not -path "*/.*")
        fi

        local -a dirs=()
        local d
        while IFS= read -r d; do dirs+=("$d"); done < <(
            find "''${find_args[@]}" -printf '%P\n' | LC_ALL=C sort
        )

        if ((''${#dirs[@]} == 0)); then
            echo "No subdirectories found in $PWD (depth=$depth). Pass explicit paths to copycr." >&2
            return 1
        fi

        local header="DIR SELECT • Depth=$depth • Space=toggle • Enter=copy • Ctrl-A=all • Esc=abort"
        local out
        if command -v fzf >/dev/null 2>&1; then
            out=$(
                printf '%s\n' "''${dirs[@]}" | fzf \
                    --multi \
                    --marker='✓' \
                    --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
                    --header "$header" \
                    --height=80% \
                    --reverse \
                    --preview 'ls -la --color=always {} | sed -n "1,200p"' \
                    --preview-window 'right:60%:wrap'
            )
        elif command -v gum >/dev/null 2>&1; then
            out=$(
                printf '%s\n' "''${dirs[@]}" | gum choose --no-limit --header "Select directories ($header)"
            )
        else
            echo "fzf (preferred) or gum not found." >&2
            return 1
        fi

        [[ -z "$out" ]] && {
            echo "No directories selected. Aborting." >&2
            return 1
        }
        printf '%s\n' "$out"
    }

    # ──────────────────────────────────────────────────────────────────────────────
    # Select FILES via TUI and print selections (one per line).
    # ──────────────────────────────────────────────────────────────────────────────
    _copycr_select_files() {
        local depth="''${1:-1}"
        local include_hidden="''${2:-0}"
        local -a find_args=(. -mindepth 1 -maxdepth "$depth" -type f)
        local -a prune_args=(-name ".git" -o -name "node_modules" -o -name "result" -o -name ".direnv")

        if [[ "$include_hidden" != "1" ]]; then
            find_args+=(-not -path "*/.*")
        fi

        local -a files=()
        local f
        while IFS= read -r f; do files+=("$f"); done < <(
            find . -maxdepth "$depth" \( \( "''${prune_args[@]}" \) -prune \) -o -type f -print |
            sed 's|^\./||' |
            grep -v "^.$" |
            if [[ "$include_hidden" != "1" ]]; then grep -v "/\."; else cat; fi |
            LC_ALL=C sort
        )

        if ((''${#files[@]} == 0)); then
            echo "No files found in $PWD (depth=$depth). Pass explicit paths to copycf." >&2
            return 1
        fi

        local header="FILE SELECT • Depth=$depth • Space=toggle • Enter=copy • Ctrl-A=all • Esc=abort"
        local out
        if command -v fzf >/dev/null 2>&1; then
            out=$(
                printf '%s\n' "''${files[@]}" | fzf \
                    --multi \
                    --marker='✓' \
                    --bind 'space:toggle,ctrl-a:select-all,ctrl-d:deselect-all' \
                    --header "$header" \
                    --height=80% \
                    --reverse \
                    --preview 'if grep -Iq . {}; then head -n 100 {}; else echo "(Binary file)"; fi' \
                    --preview-window 'right:60%:wrap'
            )
        elif command -v gum >/dev/null 2>&1; then
            out=$(
                printf '%s\n' "''${files[@]}" | gum choose --no-limit --header "Select files ($header)"
            )
        else
            echo "fzf (preferred) or gum not found." >&2
            return 1
        fi

        [[ -z "$out" ]] && {
            echo "No files selected. Aborting." >&2
            return 1
        }
        printf '%s\n' "$out"
    }

    # ──────────────────────────────────────────────────────────────────────────────
    # Dump *one* target (file or dir) to STDOUT.
    # ──────────────────────────────────────────────────────────────────────────────
    _copycr_dump_target() {
        local target="$1"
        local shallow="''${2:-0}"

        if [[ ! -e "$target" ]]; then
            echo "Error: '$target' does not exist." >&2
            return 1
        fi

        if [[ -f "$target" ]]; then
            {
                command ls -l -- "$target"
                echo
                echo "FILE CONTENTS"
                if grep -Iq . "$target"; then
                    echo "===== ./$target ====="
                    cat -- "$target"
                    echo
                else
                    echo "===== ./$target (SKIPPED BINARY) =====" >&2
                fi
            }
            return 0
        fi

        if [[ -d "$target" ]]; then
            _copycr__print_path() {
                local p="$1"
                case "$p" in
                    ./*) printf "%s" "$p" ;;
                    /*) printf "%s" "$p" ;;
                    *) printf "./%s" "$p" ;;
                esac
            }

            if [[ "$shallow" == "1" ]]; then
                command ls -la -- "$target"
                echo
                echo "FILE CONTENTS"
                local f
                while IFS= read -r -d "" f; do
                    if grep -Iq . "$f"; then
                        echo "===== $(_copycr__print_path "$f") ====="
                        cat -- "$f"
                        echo
                    else
                        echo "===== $(_copycr__print_path "$f") (SKIPPED BINARY) =====" >&2
                    fi
                done < <(find "$target" -mindepth 1 -maxdepth 1 -type f -print0)
                return 0
            fi

            command ls -laR -- "$target"
            echo
            echo "FILE CONTENTS"
            local f
            while IFS= read -r -d "" f; do
                if grep -Iq . "$f"; then
                    echo "===== $(_copycr__print_path "$f") ====="
                    cat -- "$f"
                    echo
                else
                    echo "===== $(_copycr__print_path "$f") (SKIPPED BINARY) =====" >&2
                fi
            done < <(find "$target" \( -name .git -o -name result -o -name node_modules \) -prune -o -type f -print0)
            return 0
        fi

        echo "Error: '$target' is not a regular file or directory." >&2
        return 1
    }

    # ──────────────────────────────────────────────────────────────────────────────
    # Parse options
    # ──────────────────────────────────────────────────────────────────────────────
    _copycr_parse_opts() {
        COPYCR_DEPTH=1
        COPYCR_INCLUDE_HIDDEN=0
        COPYCR_INCLUDE_ROOT=0
        COPYCR_REST_ARGS=()

        local -a ARGS=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                -d | --depth)
                    if [[ $# -lt 2 ]]; then echo "Missing value for $1" >&2; return 1; fi
                    COPYCR_DEPTH="$2"; shift 2 ;;
                --include-hidden) COPYCR_INCLUDE_HIDDEN=1; shift ;;
                -R | --include-root) COPYCR_INCLUDE_ROOT=1; shift ;;
                --) shift; while [[ $# -gt 0 ]]; do ARGS+=("$1"); shift; done ;;
                -*) echo "Unknown option: $1" >&2; return 1 ;;
                *) ARGS+=("$1"); shift ;;
            esac
        done
        COPYCR_REST_ARGS=("''${ARGS[@]}")
    }
  '';
in {
  # ──────────────────────────────────────────────────────────────────────────────
  #  Git / Dotfiles
  # ──────────────────────────────────────────────────────────────────────────────
  pull-dotfiles = {
    runtimeInputs = [pkgs.git];
    text = ''
      # Note: This runs in a subprocess, so 'cd' won't affect your interactive shell.
      # It successfully performs the pull logic, however.
      cd ~/nixosconfig || exit 1
      if ! git pull origin; then
          echo "Error: Git pull failed. Please resolve conflicts."
          exit 1
      fi
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Xclip Shim
  # ──────────────────────────────────────────────────────────────────────────────
  xclip = {
    # We call this "xclip" in the output binary name to act as a shim
    name = "xclip";
    runtimeInputs = [pkgs.coreutils]; # for base64
    text = ''
      # If standard input is a pipe, read it; otherwise rely on args
      input=""
      if [[ ! -t 0 ]]; then
          input=$(cat)
      fi

      # 1. SSH / Remote (OSC 52)
      if [[ -n "''${SSH_CONNECTION:-}" ]]; then
          b64data=$(echo -n "$input" | base64 | tr -d '\n')
          printf "\033]52;c;%s\007" "$b64data"

      # 2. Wayland
      elif [[ -n "''${WAYLAND_DISPLAY:-}" ]]; then
          # Use absolute path to avoid shadowing loop if wl-copy is missing
          echo -n "$input" | "${pkgs.wl-clipboard}/bin/wl-copy"

      # 3. Fallback to real X11 xclip
      else
          if [ -x "${pkgs.xclip}/bin/xclip" ]; then
              echo -n "$input" | "${pkgs.xclip}/bin/xclip" "$@"
          else
              echo "Error: xclip binary not found in closure." >&2
              exit 1
          fi
      fi
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Secret Decryption (dc)
  # ──────────────────────────────────────────────────────────────────────────────
  dc = {
    runtimeInputs = [pkgs.sops pkgs.ssh-to-age pkgs.neovim];
    text = ''
      uid="$(id -u)"
      # If caller already exported a SOPS env var, respect it.
      if [[ -n "''${SOPS_AGE_KEY_FILE:-}" || -n "''${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" || -n "''${SOPS_AGE_KEY:-}" ]]; then
          EDITOR=nvim VISUAL=nvim sops "$@"
          exit 0
      fi

      _dc_run_sops() {
          EDITOR=nvim VISUAL=nvim sops "$@"
      }

      # 1) AGE KEY FILES
      for keyfile in "/root/.config/sops/age/keys.txt" "/var/lib/sops-nix/key.txt"; do
          if sudo test -r "$keyfile" 2>/dev/null; then
              if [[ "$uid" -eq 0 ]]; then
                  SOPS_AGE_KEY_FILE="$keyfile" _dc_run_sops "$@"
              else
                  tmp_key="$(mktemp -t dc-sops-rootkey-XXXXXX.age)"
                  # FIX: Use tee to appease shellcheck SC2024 (sudo redirect)
                  sudo cat "$keyfile" | tee "$tmp_key" >/dev/null
                  chmod 600 "$tmp_key"
                  SOPS_AGE_KEY_FILE="$tmp_key" _dc_run_sops "$@"
                  rc=$?
                  rm -f "$tmp_key"
                  exit "$rc"
              fi
              exit 0
          fi
      done

      # 2) HOST SSH KEY
      if sudo test -r /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
          if age_key=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key 2>/dev/null); then
              SOPS_AGE_KEY="$age_key" _dc_run_sops "$@"
              exit 0
          fi
      fi

      # 3) USER SSH KEY
      sshkey="$HOME/.ssh/id_ed25519"
      if [[ -r "$sshkey" ]]; then
          if age_key=$(ssh-to-age -private-key -i "$sshkey" 2>/dev/null); then
              SOPS_AGE_KEY="$age_key" _dc_run_sops "$@"
              exit 0
          fi
      fi

      echo "❌ No valid keys found for decryption."
      exit 1
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Quick Edit
  # ──────────────────────────────────────────────────────────────────────────────
  edit = {
    runtimeInputs = [pkgs.neovim];
    text = ''
      if [[ -z "''${1:-}" ]]; then
          echo "Usage: edit <zsh|caddy|diary|nvim|nix|hy>"
          exit 1
      fi

      case "$1" in
          zsh)   exec nvim ~/nixosconfig/home/zsh/.zshrc2 ;;
          caddy) exec nvim ~/DotFiles/Caddy/Caddyfile ;;
          diary) cd /mnt/data/Life/Zet/Projects/Diary && exec nvim ;;
          nvim)  exec nvim ~/nixosconfig/home/nvim/options.lua ;;
          nix)   cd ~/nixosconfig && exec nvim ;;
          hy)
              conf_dir="$HOME/nixosconfig/modules/home-manager/display/conf"
              exec nvim -c "cd $conf_dir"
              ;;
          *)
              echo "Unknown argument: $1"
              exit 1
              ;;
      esac
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Tee to Clipboard (teec)
  # ──────────────────────────────────────────────────────────────────────────────
  teec = {
    # Relies on the 'xclip' shim being in PATH (which it will be if installed)
    runtimeInputs = [pkgs.coreutils];
    text = ''
      tee /dev/tty | xclip -selection clipboard -target UTF8_STRING
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Copy Context (copyc)
  # ──────────────────────────────────────────────────────────────────────────────
  copyc = {
    runtimeInputs = [pkgs.findutils pkgs.gnugrep pkgs.coreutils];
    text = ''
      if [[ ! -t 0 ]]; then
          xclip -selection clipboard -target UTF8_STRING
          echo "Piped input copied to clipboard." >&2
          exit 0
      fi

      target="''${1:-.}"
      [[ ! -e "$target" ]] && { echo "Error: '$target' does not exist." >&2; exit 1; }

      if [[ -d "$target" ]]; then
          (
              cd "$target" || exit 1
              ls -la .
              echo
              echo "FILE CONTENTS"
              for f in *; do
                  [[ -f "$f" ]] || continue
                  if grep -Iq . "$f"; then
                      echo "===== $f ====="
                      cat "$f"
                      echo
                  else
                      echo "===== $f (SKIPPED BINARY) =====" >&2
                  fi
              done
          ) | xclip -selection clipboard -target UTF8_STRING
          echo "Directory '$target' context copied to clipboard." >&2
          exit 0
      fi

      if [[ -f "$target" ]]; then
          {
              ls -l "$target"
              echo
              echo "FILE CONTENTS"
              cat "$target"
              echo
          } | xclip -selection clipboard -target UTF8_STRING
          echo "File '$target' context copied to clipboard." >&2
          exit 0
      fi

      echo "Error: '$target' is not a regular file or directory." >&2
      exit 1
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  YouTube Summary (ytsum)
  # ──────────────────────────────────────────────────────────────────────────────
  ytsum = {
    runtimeInputs = [pkgs.yt-dlp pkgs.coreutils pkgs.findutils];
    text = ''
      if [[ $# -eq 0 ]]; then
          echo "Usage: ytsum <YouTube URL>" >&2
          exit 1
      fi

      tmpdir=$(mktemp -d -t ytsum-XXXXXX)
      trap 'rm -rf "$tmpdir"' EXIT

      if ! yt-dlp \
          --write-auto-sub \
          --skip-download \
          --sub-format "vtt" \
          --output "$tmpdir/%(title)s.%(ext)s" \
          "$1"; then
          echo "❌ yt-dlp failed to download subtitles." >&2
          exit 1
      fi

      subfile=$(find "$tmpdir" -type f -iname "*.vtt" -print -quit)
      # Assume teec is available in path or pipe to xclip manually if needed
      if [[ -f "$subfile" ]]; then
          cat "$subfile" | tee /dev/tty | xclip -selection clipboard -target UTF8_STRING
      else
          echo "❌ Subtitle file not created." >&2
          exit 1
      fi
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  YouTube Listen (ytlisten)
  # ──────────────────────────────────────────────────────────────────────────────
  ytlisten = {
    runtimeInputs = [pkgs.mpv];
    text = ''
      if [[ $# -eq 0 ]]; then
          echo "Usage: ytlisten <YouTube URL>" >&2
          exit 1
      fi

      echo "▶️  Starting audio stream for '$1'..."
      if mpv \
          --no-video \
          --ytdl-format='bestaudio/best' \
          --msg-level=ytdl_hook=debug \
          "$1"; then
          echo "✅ Stream finished."
      else
          echo "❌ mpv failed to play the stream." >&2
          exit 1
      fi
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Hypr Proto
  # ──────────────────────────────────────────────────────────────────────────────
  hypr-proto = {
    runtimeInputs = [pkgs.git pkgs.coreutils];
    text = ''
      mode="''${1:-}"
      if [[ "$mode" != "create" ]]; then
          echo "Usage: hypr_proto create"
          exit 1
      fi

      if ! repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
          echo "hypr_proto: not inside a git repo" >&2
          exit 1
      fi

      conf_root="$repo_root/modules/home-manager/display/conf"
      mkdir -p "$conf_root"

      files=(
          "$HOME/.config/hypr/hyprland.conf"
          "$HOME/.config/hypr/hypridle.conf"
          "$HOME/.config/hypr/hyprlock.conf"
          "$HOME/.config/hypr/hyprpaper.conf"
          "$HOME/.config/waybar/config"
          "$HOME/.config/waybar/style.css"
      )

      for src in "''${files[@]}"; do
          if [[ ! -e "$src" ]]; then continue; fi
          # FIX: Quote HOME to appease shellcheck SC2295
          rel="''${src#"$HOME"/.config/}"
          target="$conf_root/$rel"
          mkdir -p "$(dirname "$target")"
          echo "[*] Copying $src -> $target"
          cp "$src" "$target"
          rm -f "$src"
          ln -s "$target" "$src"
      done
      echo "hypr_proto: done."
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  Podcast Hooks
  # ──────────────────────────────────────────────────────────────────────────────
  pod = {
    runtimeInputs = [pkgs.curl];
    text = ''
      [ -z "$1" ] && { echo "Usage: pod <url>"; exit 1; }
      curl -X POST -H "Content-Type: application/json" -d "{\"url\": \"$1\"}" http://192.168.1.29:9000/hooks/download-audio
    '';
  };

  pod-play = {
    runtimeInputs = [pkgs.curl];
    text = ''
      [ -z "$1" ] && { echo "Usage: pod_play <url>"; exit 1; }
      curl -X POST -H "Content-Type: application/json" -d "{\"url\": \"$1\"}" http://192.168.1.29:9000/hooks/download-playlist
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  CI Check
  # ──────────────────────────────────────────────────────────────────────────────
  check = {
    runtimeInputs = [pkgs.alejandra pkgs.deadnix pkgs.statix pkgs.git pkgs.nix];
    text = ''
            if [[ ! -f "flake.nix" ]]; then
                echo "❌ No flake.nix found in current directory."
                exit 1
            fi

            failed=0

            RUN_DRIFT=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --drift) RUN_DRIFT=true; shift ;;
                    --help|-h)
                        cat <<'EOF'
      Usage: check [--drift]
        --drift  run hash-based drift detection (slow)
      EOF
                        exit 0
                        ;;
                    *) echo "Unknown option: $1" >&2; exit 1 ;;
                esac
            done

            # Run format check
            echo "🧹 Running Format Check (alejandra)..."
            if ! alejandra --check --quiet . >/dev/null 2>&1; then
                echo "❌ Formatting issues detected. Run 'nix fmt'."
                alejandra --check . 2>&1 | grep -E "(Requires formatting:|Alert!)" || true
                failed=1
            else
                echo "✅ Format check passed"
            fi
            echo ""

            # Run deadnix
            echo "🔍 Running Linting (deadnix)..."
            if ! deadnix --fail .; then
                echo "❌ Deadnix found issues"
                failed=1
            else
                echo "✅ Deadnix passed"
            fi
            echo ""

            # Run statix
            echo "🔍 Running Linting (statix)..."
            if ! statix check .; then
                echo "❌ Statix found issues"
                failed=1
            else
                echo "✅ Statix passed"
            fi
            echo ""

            # Run flake check regardless of previous failures
            echo "❄️  Running Flake Checks..."
            if ! nix flake check --print-build-logs; then
                echo "❌ Flake check failed."
                failed=1
            else
                echo "✅ Flake check passed"
            fi
            echo ""

            if [[ $failed -eq 1 ]]; then
                echo "❌ Some checks failed. Please fix the issues above."
                exit 1
            fi

            # Run drift detection (informational - doesn't fail the check)
            if $RUN_DRIFT; then
                echo "📊 Running Drift Detection..."
                if [[ -x "./scripts/hash-compare.sh" ]] && [[ -d "./hashes" ]]; then
                    # Capture output to parse it
                    drift_output=$(./scripts/hash-compare.sh --summary 2>&1) || true
                    echo "$drift_output"

                    # Extract counts from summary
                    if echo "$drift_output" | grep -q "Drifted: 0"; then
                        echo ""
                        echo "✅ No configuration drift detected."
                    else
                        drifted=$(echo "$drift_output" | grep "Drifted:" | grep -oE '[0-9]+' || echo "?")
                        echo ""
                        echo "📝 $drifted configuration(s) changed from baseline."
                        echo "   Review the drift above to verify changes are intentional."
                        echo "   Run './scripts/hash-compare.sh' for detailed nix-diff output."
                    fi
                else
                    echo "⚠️  Drift detection not available (missing scripts or hashes)."
                fi
                echo ""
            else
                echo "ℹ️  Drift detection skipped (use --drift to enable)."
                echo ""
            fi

            echo "✅ All local checks passed. Ready to commit."
    '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  CopyCR (Directories)
  # ──────────────────────────────────────────────────────────────────────────────
  copycr = {
    runtimeInputs = [pkgs.fzf pkgs.gum pkgs.findutils pkgs.gnugrep pkgs.coreutils];
    text =
      copycrCommon
      + ''
        copycr() {
            if [[ ! -t 0 ]]; then
                xclip -selection clipboard -target UTF8_STRING
                echo "Piped input copied to clipboard." >&2
                return 0
            fi

            _copycr_parse_opts "$@" || return 1
            set -- "''${COPYCR_REST_ARGS[@]}"

            if (($# > 0)); then
                local missing=0 p
                for p in "$@"; do
                    [[ -e "$p" ]] || { echo "Error: '$p' does not exist." >&2; missing=1; }
                done
                ((missing)) && return 1

                {
                    ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true
                    for p in "$@"; do _copycr_dump_target "$p" || return 1; done
                } | xclip -selection clipboard -target UTF8_STRING

                echo "Explicit paths copied to clipboard." >&2
                return 0
            fi

            if [[ -t 1 ]]; then
                local selections sel_rc
                selections=$(_copycr_select_dirs "$COPYCR_DEPTH" "$COPYCR_INCLUDE_HIDDEN")
                sel_rc=$?

                {
                    ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true
                    if ((sel_rc == 0)); then
                        local line
                        while IFS= read -r line; do _copycr_dump_target "$line" || return 1; done <<<"$selections"
                    else
                        ((COPYCR_INCLUDE_ROOT == 1)) || return 1
                    fi
                } | xclip -selection clipboard -target UTF8_STRING

                echo "Selected directories' context copied to clipboard." >&2
                return 0
            fi
            return 1
        }
        copycr "$@"
      '';
  };

  # ──────────────────────────────────────────────────────────────────────────────
  #  CopyCF (Files)
  # ──────────────────────────────────────────────────────────────────────────────
  copycf = {
    runtimeInputs = [pkgs.fzf pkgs.gum pkgs.findutils pkgs.gnugrep pkgs.coreutils];
    text =
      copycrCommon
      + ''
        copycf() {
            if [[ ! -t 0 ]]; then
                xclip -selection clipboard -target UTF8_STRING
                echo "Piped input copied to clipboard." >&2
                return 0
            fi

            _copycr_parse_opts "$@" || return 1
            set -- "''${COPYCR_REST_ARGS[@]}"

            if (($# > 0)); then
                local missing=0 p
                for p in "$@"; do
                    [[ -e "$p" ]] || { echo "Error: '$p' does not exist." >&2; missing=1; }
                done
                ((missing)) && return 1

                {
                    ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true
                    for p in "$@"; do _copycr_dump_target "$p" || return 1; done
                } | xclip -selection clipboard -target UTF8_STRING

                echo "Explicit paths copied to clipboard." >&2
                return 0
            fi

            if [[ -t 1 ]]; then
                local selections sel_rc
                selections=$(_copycr_select_files "$COPYCR_DEPTH" "$COPYCR_INCLUDE_HIDDEN")
                sel_rc=$?

                {
                    ((COPYCR_INCLUDE_ROOT == 1)) && _copycr_dump_target "." 1 || true
                    if ((sel_rc == 0)); then
                        local line
                        while IFS= read -r line; do _copycr_dump_target "$line" || return 1; done <<<"$selections"
                    else
                        ((COPYCR_INCLUDE_ROOT == 1)) || return 1
                    fi
                } | xclip -selection clipboard -target UTF8_STRING

                echo "Selected files' context copied to clipboard." >&2
                return 0
            fi
            return 1
        }
        copycf "$@"
      '';
  };
}
