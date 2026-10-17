# AI agent content retention: keep the last N days of Claude Code background
# jobs, Codex rollouts, prompt histories and Hermes sessions/logs, archiving
# numeric usage (models, tokens, limit %) to ~/.local/state/ai-usage first.
# Claude's own cleanupPeriodDays (30) still owns ~/.claude/projects; this only
# archives usage from those transcripts before Claude deletes them.
# See docs/wiki/claude-code/usage-limit-ledger.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.aiRetention;
  ai-retention = pkgs.writers.writePython3Bin "ai-retention" {
    flakeIgnore = ["E501"];
  } (builtins.readFile ../../../scripts/ai-retention.py);
in {
  options.homelab.aiRetention = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Prune AI agent transcripts older than `days`, archiving numeric usage first.";
    };
    days = lib.mkOption {
      type = lib.types.ints.between 7 3650;
      default = 30;
      description = "Days of AI agent content to keep.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ai-retention];

    systemd.user.services.ai-retention = {
      Unit.Description = "Prune AI agent transcripts older than ${toString cfg.days} days";
      Service = {
        Type = "oneshot";
        ExecStart = "${ai-retention}/bin/ai-retention --days ${toString cfg.days}";
        # hermes (doc1) lives on the system profile.
        Environment = ["PATH=/run/current-system/sw/bin:/etc/profiles/per-user/${config.home.username}/bin"];
        Nice = 19;
        IOSchedulingClass = "idle";
      };
    };

    systemd.user.timers.ai-retention = {
      Unit.Description = "Daily AI agent transcript retention";
      Timer = {
        OnCalendar = "*-*-* 04:40";
        RandomizedDelaySec = "20m";
        Persistent = true;
      };
      Install.WantedBy = ["timers.target"];
    };
  };
}
