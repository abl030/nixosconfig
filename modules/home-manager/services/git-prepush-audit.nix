# Pre-push audit gate for the fleet config repo.
#
# WHY: the policy audits (hostBindAuditCheck = the 0.0.0.0 bind check,
# errorPatternsCheck, sopsRecipientScopeCheck, …) ARE `nix flake check`
# checks — but until now they only ran in the NIGHTLY rolling-flake-update,
# i.e. AFTER a violating commit was already on Forgejo master. That is how the
# 2026-06-25 mailsearch `0.0.0.0` bind froze every flake-input update overnight:
# the check did its job, just too late to stop the push.
#
# This hook runs the SAME audits at push time. `nix flake check` here is fast:
# host builds are gated behind FULL_CHECK=1 (the nightly sets that), so a bare
# check realises only the ~11 cheap grep/runCommand audit derivations.
#
# WHERE: enabled on doc1 only — the sole writer to master. Every push path
# (direct, the relay-push skill, agent pushes) originates there as `abl030`, so
# one hook covers the fleet. The rolling-update bot runs as a different user
# (its own git config, no hooksPath) and validates before pushing anyway.
#
# Bypass in a genuine emergency with `git push --no-verify`; the nightly remains
# the backstop. See the 2026-06-26 alert-storm session + issue notes.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.gitPrePushAudit;

  prePush = pkgs.writeShellApplication {
    name = "nixcfg-pre-push";
    runtimeInputs = [pkgs.nix pkgs.git pkgs.gnugrep];
    text = ''
      root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
      # Only gate the fleet config repo, identified by its own audit check.
      # Any other repo (or a checkout predating the checks) passes through.
      if [ ! -f "$root/flake.nix" ] || ! grep -q hostBindAuditCheck "$root/flake.nix"; then
        exit 0
      fi
      cd "$root" || exit 1
      echo "🔒 pre-push: running fleet audits (nix flake check) before push…" >&2
      echo "   (emergency bypass: git push --no-verify — the nightly is the backstop)" >&2
      if ! nix flake check --impure --print-build-logs; then
        {
          echo ""
          echo "❌ pre-push: fleet audits FAILED — push aborted."
          echo "   This is exactly what would otherwise have broken overnight's"
          echo "   rolling-flake-update. Fix the failure above, then push again."
        } >&2
        exit 1
      fi
      echo "✅ pre-push: fleet audits passed" >&2
    '';
  };

  hooksDir = pkgs.linkFarm "nixcfg-git-hooks" [
    {
      name = "pre-push";
      path = lib.getExe prePush;
    }
  ];
in {
  options.homelab.gitPrePushAudit.enable =
    lib.mkEnableOption "pre-push git hook that runs the fleet flake-check audits before a push (enable on the sole-writer host, doc1)";

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
