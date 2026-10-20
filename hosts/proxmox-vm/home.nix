{pkgs, ...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];

  home.packages = [
    pkgs.officecli
    (pkgs.python3.withPackages (pythonPackages: [pythonPackages.openpyxl]))
    # Data tools for the Cullen assistant (~/cullen-assistant): the Ezy DuckDB
    # snapshot, SQLite pulls, PDF attachments, docx/csv wrangling.
    pkgs.duckdb
    pkgs.sqlite
    pkgs.poppler-utils
    pkgs.pandoc
    pkgs.csvkit
    # Headless recalculation/conversion of xlsx/docx (soffice --headless).
    pkgs.libreoffice
  ];

  # brain.ablz.au: Andy's private dashboard and daily inbox reader. The code runs
  # straight from the ~/cullen-assistant checkout (brain/) so agents iterate with a
  # commit plus `systemctl --user restart brain`; state lives in ~/.local/state/brain.
  # The sweep's claude -p is locked to the read-only mailsearch MCP with no
  # built-in tools and only files proposals (Andy approved unattended mail
  # reading on that basis, 2026-10-20). Proxy + Google token: configuration.nix.
  # Docs: cullen-assistant knowledge/systems/brain.md.
  systemd.user.services.brain = {
    Unit.Description = "brain.ablz.au dashboard";
    Service = {
      WorkingDirectory = "%h/cullen-assistant";
      ExecStart = "${pkgs.python3}/bin/python3 -m brain.app --port=8870";
      Restart = "always";
      RestartSec = "5s";
    };
    Install.WantedBy = ["default.target"];
  };
  systemd.user.services.brain-sweep = {
    Unit.Description = "brain inbox sweep (read-only mail to dashboard proposals)";
    Service = {
      Type = "oneshot";
      WorkingDirectory = "%h/cullen-assistant";
      Environment = ["PATH=/etc/profiles/per-user/abl030/bin:/run/current-system/sw/bin"];
      ExecStart = "${pkgs.python3}/bin/python3 -m brain.sweep";
      TimeoutStartSec = "30min";
    };
  };
  systemd.user.timers.brain-sweep = {
    Unit.Description = "Daily brain inbox sweep";
    Timer = {
      OnCalendar = "*-*-* 06:30:00";
      Persistent = true;
      RandomizedDelaySec = "5m";
    };
    Install.WantedBy = ["timers.target"];
  };

  # Dad's incoming NAS share needs doc1's private user-owned Tailscale daemon.
  # Account, host fingerprint and recovery: docs/wiki/services/dadnas.md.
  programs.ssh.matchBlocks.dadnas = {
    hostname = "100.103.36.101";
    user = "ibl";
    port = 22;
    identityFile = "~/.ssh/id_ed25519";
    forwardAgent = false;
    extraOptions = {
      IdentitiesOnly = "yes";
      ProxyCommand = "/run/wrappers/bin/sudo -n -u dadnas-tailnet ${pkgs.tailscale}/bin/tailscale --socket=/run/dadnas-tailnet/tailscaled.sock nc %h %p";
    };
  };

  # doc1 is the sole writer to Forgejo master. Audit-gate pushes (so a policy
  # violation can't reach master and break overnight's rolling-flake-update),
  # plus warn-only staged-file lint at commit time (decoupled from deploys).
  # See modules/home-manager/services/git-hooks.nix.
  homelab.gitHooks.enable = true;
}
