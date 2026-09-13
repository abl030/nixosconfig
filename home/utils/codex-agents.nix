{
  config,
  lib,
  pkgs,
  ...
}: let
  codexHome = "${config.home.homeDirectory}/.codex";
  launcher = pkgs.writeShellApplication {
    name = "codex";
    text =
      lib.replaceStrings
      ["@codex@" "@systemctl@" "@codexHome@"]
      ["${pkgs.codex}/bin/codex" "${pkgs.systemd}/bin/systemctl" codexHome]
      (builtins.readFile ../codex-agents.sh);
  };
  ready = pkgs.writeShellScript "codex-app-server-ready" ''
    for attempt in {1..100}; do
      if [[ -S "$XDG_RUNTIME_DIR/codex-app-server/control.sock" ]]; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    echo "Codex app-server did not create its local socket" >&2
    exit 1
  '';
in {
  # Keep the upstream package, helpers and completions; intercept only the
  # local dashboard. See docs/wiki/claude-code/codex-agent-dashboard.md.
  programs.codex.package = pkgs.symlinkJoin {
    name = "codex-with-agents-${pkgs.codex.version}";
    inherit (pkgs.codex) version meta;
    paths = [pkgs.codex];
    postBuild = ''
      rm "$out/bin/codex"
      ln -s ${launcher}/bin/codex "$out/bin/codex"
    '';
  };

  systemd.user.services.codex-app-server = {
    Unit.Description = "Codex local agent dashboard server";
    Service = {
      Type = "exec";
      # User-requested YOLO defaults for new dashboard tasks. Existing threads
      # retain their saved permissions; ordinary CLI sessions are independent.
      ExecStart = "${pkgs.codex}/bin/codex app-server --config approval_policy=never --config sandbox_mode=danger-full-access --listen unix://%t/codex-app-server/control.sock";
      ExecStartPost = "${ready}";
      WorkingDirectory = config.home.homeDirectory;
      Environment = ["CODEX_HOME=${codexHome}"];
      RuntimeDirectory = "codex-app-server";
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      Restart = "on-failure";
      RestartSec = 2;
      TimeoutStartSec = 15;
      # NNP-OK: this is the user's coding agent; authorized tools need the
      # same sudo/setuid access as an interactive Codex session. The private
      # Unix socket is the access boundary; there is no network listener.
      NoNewPrivileges = false;
    };
    # Start on demand through the launcher. Home Manager restarts an active
    # service when its Nix-managed executable or unit changes.
  };
}
