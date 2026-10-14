# Hourly Cullen WAN record upkeep (cullen-assistant scripts/wan-hourly): the SonicWall
# on-box event log (exact link down/up seconds, DHCP/failover context; the store only
# holds ~3 h), the TSR switch counters (FCS errors, collisions), and a mirror of the
# wsl ping logs (homelab.services.cullenWanPing) so they survive the laptop. The API
# logins bump Andy's GUI session from the same source IP. Runs in abl030's user
# manager (linger) because it uses the cullen-assistant checkout, abl030's
# /run/secrets/sonicwall-api.env and the `ssh wsl` alias.
# See docs/wiki/services/cullen-wan-usage.md.
{pkgs, ...}: let
  user = "abl030";
in {
  systemd.user.services.cullen-wan-hourly = {
    description = "Pull Cullen SonicWall event log/port errors and mirror wsl ping logs";
    unitConfig.ConditionUser = user;
    path = [pkgs.python3 pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.rsync pkgs.openssh];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "/home/${user}/cullen-assistant/scripts/wan-hourly";
      TimeoutStartSec = "10min";
    };
  };
  systemd.user.timers.cullen-wan-hourly = {
    wantedBy = ["timers.target"];
    unitConfig.ConditionUser = user;
    timerConfig = {
      OnCalendar = "*:07";
      Persistent = true;
    };
  };
}
