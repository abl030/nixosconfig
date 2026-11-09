# Weekly prune of agent scratch on doc1. The root filesystem paged >95% twice
# in three days (Hermes RCA 2026-11-09); nearly all of it was ~/.claude/jobs
# scratch (75G), Codex/Claude transcripts (~41G) and rebuildable caches.
# Retention agreed in the 2026-11-10 triage: job dirs idle 14 days, transcripts
# 90 days, uv/fh caches pruned. A job whose session is still running is skipped
# even when its files are old.
{pkgs, ...}: let
  cleanup = pkgs.writeShellApplication {
    name = "agent-disk-cleanup";
    runtimeInputs = with pkgs; [coreutils findutils gnugrep gnused uv];
    text = ''
      before=$(df --output=avail -BG "$HOME" | tail -n1 | tr -dc 0-9)

      # Job ids referenced by a live process (env CLAUDE_JOB_DIR or cwd).
      live=$( {
        grep -sazh '^CLAUDE_JOB_DIR=' /proc/[0-9]*/environ | tr '\0' '\n' | sed 's#.*/jobs/##; s#/.*##'
        for c in /proc/[0-9]*/cwd; do readlink "$c" 2>/dev/null; done | grep -o '/\.claude/jobs/[^/]*' | sed 's#.*/##'
      } | sort -u || true)

      jobs_removed=0
      for d in "$HOME"/.claude/jobs/*/; do
        [ -d "$d" ] || continue
        id=$(basename "$d")
        if grep -qxF "$id" <<<"$live"; then continue; fi
        # Anything written in the last 14 days keeps the whole job.
        if [ -n "$(find "$d" -newermt '-14 days' -print -quit 2>/dev/null)" ]; then continue; fi
        rm -rf -- "$d"
        jobs_removed=$((jobs_removed + 1))
      done

      for t in "$HOME/.claude/projects" "$HOME/.codex/sessions"; do
        [ -d "$t" ] || continue
        find "$t" -type f -mtime +90 -delete 2>/dev/null || true
        find "$t" -mindepth 1 -type d -empty -delete 2>/dev/null || true
      done

      uv cache prune >/dev/null 2>&1 || true
      rm -rf -- "$HOME/.cache/fh"

      after=$(df --output=avail -BG "$HOME" | tail -n1 | tr -dc 0-9)
      echo "agent-disk-cleanup: removed $jobs_removed idle job dirs; free ''${before}G -> ''${after}G"
    '';
  };
in {
  home.packages = [cleanup];

  systemd.user.services.agent-disk-cleanup = {
    Unit.Description = "Prune idle Claude jobs, old transcripts and rebuildable caches";
    Service = {
      Type = "oneshot";
      ExecStart = "${cleanup}/bin/agent-disk-cleanup";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };
  systemd.user.timers.agent-disk-cleanup = {
    Unit.Description = "Weekly agent scratch prune";
    Timer = {
      OnCalendar = "Sun 04:30";
      Persistent = true;
      RandomizedDelaySec = "15min";
    };
    Install.WantedBy = ["timers.target"];
  };
}
