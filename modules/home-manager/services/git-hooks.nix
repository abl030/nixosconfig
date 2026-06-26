# Local git hooks for the fleet config repo (doc1, the sole writer to master).
#
# Two DELIBERATELY-SEPARATED gates, because cosmetic lint must never be able to
# break a deploy (a `nix fmt` nit cascading into a failed fleet update is exactly
# backwards):
#
#  * pre-push  → AUDITS ONLY. Builds the cheap policy-check derivations
#    (hostBindAuditCheck = the 0.0.0.0 check, errorPatternsCheck,
#    sopsRecipientScopeCheck, …) — the same checks the nightly rolling-flake-
#    update runs, but at push time so a violation can't reach master and freeze
#    overnight's input updates (the 2026-06-25 mailsearch 0.0.0.0 incident).
#    Host-config builds are NOT run here (that's FULL_CHECK=1 / the nightly's
#    job); the audit derivations build in ~7s. Checks are enumerated dynamically
#    so a newly-added audit is picked up automatically — no drift.
#    BLOCKS the push on failure (bypass: git push --no-verify).
#
#  * pre-commit → LINT (nix fmt / deadnix / statix), WARN-ONLY, on the STAGED
#    .nix files only. Surfaces drift in what you're touching without drowning you
#    in pre-existing repo-wide noise, NEVER blocks a commit, and is completely
#    decoupled from the deploy path. Flip `lintBlocks = true` if you ever want
#    hard "no new drift" enforcement (still local, still --no-verify-able).
#
# Enabled on doc1 only — every push path (direct, relay-push, agent) originates
# there as abl030, so one set of hooks covers the fleet. The rolling-update bot
# runs as a different user (no hooksPath) and validates anyway.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.gitHooks;

  # x86_64-linux is the whole fleet's system; doc1 is x86_64-linux.
  system = "x86_64-linux";

  repoGuard = ''
    root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
    # Only act on the fleet config repo, identified by its own audit check.
    if [ ! -f "$root/flake.nix" ] || ! grep -q hostBindAuditCheck "$root/flake.nix"; then
      exit 0
    fi
    cd "$root" || exit 1
  '';

  prePush = pkgs.writeShellApplication {
    name = "nixcfg-pre-push";
    runtimeInputs = [pkgs.nix pkgs.git pkgs.gnugrep];
    text = ''
      ${repoGuard}
      echo "🔒 pre-push: fleet audits (no host-config eval; bypass: git push --no-verify)…" >&2
      # FULL_CHECK unset → checks.${system} is exactly the cheap audit set.
      # Enumerate it so a new audit check is gated automatically.
      targets=$(nix eval --impure --raw ".#checks.${system}" \
        --apply 'cs: builtins.concatStringsSep " " (map (n: ".#checks.${system}." + n) (builtins.attrNames cs))')
      if [ -z "$targets" ]; then
        echo "❌ pre-push: could not enumerate audit checks — aborting" >&2
        exit 1
      fi
      # shellcheck disable=SC2086
      if ! nix build --impure --no-link --print-build-logs $targets; then
        echo "❌ pre-push: fleet AUDITS failed — push aborted (this would otherwise" >&2
        echo "   have broken overnight's rolling-flake-update). Fix, or --no-verify." >&2
        exit 1
      fi
      echo "✅ pre-push: audits passed" >&2
    '';
  };

  preCommit = pkgs.writeShellApplication {
    name = "nixcfg-pre-commit";
    runtimeInputs = [pkgs.git pkgs.alejandra pkgs.deadnix pkgs.statix];
    text = ''
      ${repoGuard}
      # Staged .nix files only.
      mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM -- '*.nix')
      [ "''${#files[@]}" -eq 0 ] && exit 0
      issues=0
      if ! alejandra --check --quiet "''${files[@]}" >/dev/null 2>&1; then
        echo "⚠️  pre-commit: nix fmt would reformat staged files (run: nix fmt)" >&2
        issues=1
      fi
      if ! deadnix --fail "''${files[@]}" >/dev/null 2>&1; then
        echo "⚠️  pre-commit: deadnix findings in staged files (run: deadnix ''${files[*]})" >&2
        issues=1
      fi
      for f in "''${files[@]}"; do
        if ! statix check "$f" >/dev/null 2>&1; then
          echo "⚠️  pre-commit: statix findings in $f (run: statix check $f)" >&2
          issues=1
        fi
      done
      ${
        if cfg.lintBlocks
        then ''
          if [ "$issues" -ne 0 ]; then
            echo "❌ pre-commit: staged-file lint failed (bypass: git commit --no-verify)" >&2
            exit 1
          fi
        ''
        else ''
          # WARN-ONLY: lint never blocks a commit and is fully decoupled from the
          # deploy path. A cosmetic nit cannot cascade into a system failure.
          [ "$issues" -eq 0 ] || echo "   (warn-only — commit proceeds; fix at your leisure)" >&2
        ''
      }
      exit 0
    '';
  };

  hooksDir = pkgs.linkFarm "nixcfg-git-hooks" [
    {
      name = "pre-push";
      path = lib.getExe prePush;
    }
    {
      name = "pre-commit";
      path = lib.getExe preCommit;
    }
  ];
in {
  options.homelab.gitHooks = {
    enable = lib.mkEnableOption "local git hooks for the fleet config repo: audit-gated pushes + warn-only staged-file lint (enable on the sole-writer host, doc1)";
    lintBlocks = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "If true, the pre-commit lint hook BLOCKS the commit on a staged-file fmt/deadnix/statix finding (still local; --no-verify bypasses). Default false = warn-only, so lint can never hold up a commit or a deploy.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Scope core.hooksPath to the nixosconfig repo (and its worktrees, whose
    # gitdir lives under it) via includeIf, so no other repo on the host loses
    # its own hooks.
    programs.git.includes = [
      {
        condition = "gitdir:${config.home.homeDirectory}/nixosconfig/";
        contents.core.hooksPath = "${hooksDir}";
      }
    ];
  };
}
