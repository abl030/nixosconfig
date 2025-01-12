{ config, lib, pkgs, ... }:

let
  checkScript = pkgs.writeScript "check-tailscale-ssh" ''
    #!${pkgs.runtimeShell}
    
    log() {
      logger -t tailscale-sleep-prevention "$*"
      echo "$(date): $*" >> /var/log/tailscale-sleep.log
    }

    # Get active SSH sessions through tailscale
    has_active_sessions() {
      ${pkgs.tailscale}/bin/tailscale status --json | 
        ${pkgs.jq}/bin/jq -e '.Peer[] | select(.Active and .SSHEnabled)' >/dev/null
    }

    # Check if inhibitor is already running
    INHIBITOR_PID_FILE="/run/tailscale-sleep-inhibitor.pid"

    if has_active_sessions; then
      # Start inhibitor if not already running
      if [ ! -f "$INHIBITOR_PID_FILE" ]; then
        log "Detected active Tailscale SSH session, starting sleep inhibitor"
        ${pkgs.systemd}/bin/systemd-inhibit \
          --what=sleep \
          --why="Active Tailscale SSH session" \
          --mode=block \
          --who="tailscale-ssh" \
          ${pkgs.coreutils}/bin/sleep infinity &
        echo $! > "$INHIBITOR_PID_FILE"
        log "Started sleep inhibitor with PID $(cat $INHIBITOR_PID_FILE)"
      fi
    else
      # Kill inhibitor if running but no sessions
      if [ -f "$INHIBITOR_PID_FILE" ]; then
        PID=$(cat "$INHIBITOR_PID_FILE")
        log "No active Tailscale SSH sessions, killing inhibitor PID $PID"
        kill $PID 2>/dev/null || true
        rm -f "$INHIBITOR_PID_FILE"
      fi
    fi
  '';

in
{
  # Create necessary log files
  systemd.tmpfiles.rules = [
    "f /var/log/tailscale-sleep.log 0644 root root -"
  ];

  # Service to periodically check Tailscale SSH status
  systemd.services.tailscale-sleep-prevention = {
    description = "Prevent sleep during Tailscale SSH sessions";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      ExecStart = pkgs.writeScript "tailscale-sleep-prevention-service" ''
        #!${pkgs.runtimeShell}
        while true; do
          ${checkScript}
          sleep 10
        done
      '';
      Restart = "always";
      RestartSec = "10s";
    };
  };

  # Ensure required packages are available
  environment.systemPackages = with pkgs; [
    tailscale
    jq
  ];
}
