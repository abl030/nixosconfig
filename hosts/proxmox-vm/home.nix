{pkgs, ...}: let
  # Safety net for ~/fleet-notes, the private repository behind this
  # repository's `docs` and `.claude/memory` symlinks (CLAUDE.md "Public
  # Repository, Private Notes"). Agents write memory files mid-session with no
  # commit step, and unattended agents edit wiki pages, so anything left
  # uncommitted is committed and pushed here. Uses the same Forgejo credential
  # helper as any plain git on doc1; no new credential.
  fleetNotesSync = pkgs.writeShellApplication {
    name = "fleet-notes-sync";
    runtimeInputs = [pkgs.git pkgs.openssh pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.python3 pkgs.bash];
    text = ''
      cd "$HOME/fleet-notes"
      gitdir="$(git rev-parse --absolute-git-dir)"
      if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || [ -f "$gitdir/MERGE_HEAD" ]; then
        echo "a rebase or merge is in progress; leaving it for whoever started it" >&2
        exit 1
      fi

      git add -A
      if ! git diff --cached --quiet; then
        # The pre-commit hook runs scripts/check; a failure leaves the changes
        # staged and fails this unit rather than pushing them.
        git commit -q -m "notes: autosync from $(</proc/sys/kernel/hostname) $(date '+%F %H:%M')"
      fi

      git fetch -q origin
      if ! git rebase -q origin/master; then
        git rebase --abort
        echo "local notes commits conflict with origin; resolve by hand" >&2
        exit 1
      fi
      if [ -n "$(git rev-list origin/master..HEAD)" ]; then
        git push -q origin HEAD:master
      fi

      # Read replicas, for hosts that hold no credential to fetch a private
      # repository themselves. Any remote named replica-* in this clone gets a
      # fast-forward push over SSH. One-way on purpose: a lower-trust host never
      # feeds notes back automatically. An offline, dirty or diverged replica is
      # reported and skipped. The remotes are local git config, not Nix.
      export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=8"
      for remote in $(git remote); do
        case "$remote" in
          replica-*)
            if ! timeout 90 git push -q "$remote" HEAD:master; then
              echo "replica $remote not updated (offline, dirty or diverged)" >&2
            fi
            ;;
        esac
      done
    '';
  };
in {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
    ./agent-disk-cleanup.nix
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

  # brain.ablz.au: Andy's task tracker (+ Messages tab). The code runs straight
  # from the ~/cullen-assistant checkout (brain/) so agents iterate with a commit
  # plus `systemctl --user restart brain`; state lives in ~/.local/state/brain.
  # The daily mail sweep (brain-sweep) was retired 2026-11-21: mail is filed from
  # sessions now. Proxy + Google token: configuration.nix.
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

  systemd.user.services.fleet-notes-sync = {
    Unit = {
      Description = "Commit and push uncommitted fleet-notes changes";
      ConditionPathIsDirectory = "%h/fleet-notes/.git";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${fleetNotesSync}/bin/fleet-notes-sync";
    };
  };
  systemd.user.timers.fleet-notes-sync = {
    Unit.Description = "Half-hourly fleet-notes safety-net sync";
    Timer = {
      OnCalendar = "*:0/30";
      Persistent = true;
      RandomizedDelaySec = "3m";
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

  # Windows shop laptop, shared in from Dad's tailnet; same private daemon as dadnas.
  # Key-only Win32-OpenSSH as local admin `ibl`. See docs/wiki/services/shop-laptop.md.
  programs.ssh.matchBlocks.shoplaptop = {
    hostname = "100.71.143.121";
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

  # Cullen Wines work runs on the Cullen Claude subscription: `claude` started in
  # these repos uses ~/.claude-cullen (log in once with `claude-cullen`, /login);
  # everything else stays on the personal login. brain's claude -p calls run
  # from ~/cullen-assistant, so they follow too.
  # See docs/wiki/claude-code/two-accounts.md.
  homelab.claudeWorkAccount = {
    enable = true;
    name = "cullen";
    directories = [
      "cullen-assistant"
      "cullen-carbon"
      "cullen-cellar-ledger"
      "cullen-ezy"
      "cullen-reports"
      "cellar-manager"
      "ezy-api"
    ];
  };
}
