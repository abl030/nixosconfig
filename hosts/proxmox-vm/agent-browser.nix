# Agent research browser on doc1: a persistent headed Chrome on Xvfb that the
# ~/agents chrome-devtools MCP attaches to, plus the scoped Bitwarden Secrets
# Manager token `~/agents/bin/agent-login` uses to log it in to genealogy
# sites without credentials ever entering an LLM context.
# Rationale, threat model, rotation and switch-over:
# docs/wiki/services/agent-browser.md.
{
  config,
  lib,
  pkgs,
  ...
}: let
  user = "abl030";
  display = ":99";
  port = "9222";
  # Same profile the ad-hoc ~/agents/bin/agent-chrome launcher has always used,
  # so banked logins carry over.
  profile = "%h/.cache/chrome-devtools-mcp/chrome-profile-stable";

  # Skip (ExecCondition exit 1) instead of failing when a previous ad-hoc
  # Chrome/Xvfb still owns the display or port: deploying this must never
  # disturb a browser agents are using. Exit 0 = go ahead and start.
  displayFree = pkgs.writeShellScript "agent-xvfb-display-free" ''
    lock=/tmp/.X${lib.removePrefix ":" display}-lock
    if [ -e "$lock" ] && kill -0 "$(${pkgs.coreutils}/bin/tr -d ' ' < "$lock")" 2>/dev/null; then
      echo "display ${display} already served by pid $(${pkgs.coreutils}/bin/tr -d ' ' < "$lock"); not starting a second Xvfb"
      exit 1
    fi
    exit 0
  '';
  portFree = pkgs.writeShellScript "agent-chrome-port-free" ''
    if ${pkgs.curl}/bin/curl -sf --max-time 2 http://127.0.0.1:${port}/json/version >/dev/null; then
      echo "something already answers on 127.0.0.1:${port} (ad-hoc agent-chrome?); not starting a second Chrome"
      exit 1
    fi
    exit 0
  '';
in {
  # Machine-account access token for the Bitwarden Secrets Manager project
  # "agent-research" (genealogy-site logins only). doc1-only per the sops
  # recipient model (#234); readable by abl030 alone. Until the operator
  # replaces the committed placeholder, agent-login reports "not-configured"
  # and nothing else changes. Rotate/revoke: docs/wiki/services/agent-browser.md.
  sops.secrets."bitwarden/agent-research-token" = {
    sopsFile = config.homelab.secrets.sopsFile "bitwarden-agent-research.yaml";
    format = "yaml";
    key = "token";
    owner = user;
    mode = "0400";
  };

  # bws = Bitwarden Secrets Manager CLI (unfree; base.nix allows unfree).
  users.users.${user}.packages = [pkgs.bws];

  # Keep Chrome's own password manager out of the loop: agent-login types the
  # credential, and nothing should then sit in the profile's Login Data or be
  # autofilled into a page an agent is reading. Policies are invisible to
  # websites. doc1 runs no other Chrome.
  programs.chromium = {
    enable = true;
    extraOpts = {
      PasswordManagerEnabled = false;
    };
  };

  # Headed (NOT --headless: a HeadlessChrome UA is bot-blocked on sight) Chrome
  # on a private Xvfb display, in abl030's user manager. linger=true in
  # configuration.nix starts the manager at boot, so this survives reboots.
  # Store paths referenced here are GC roots via the system closure, replacing
  # the old ~/.cache/agent-chrome/gcroots hack. User units are installed for
  # every user; ConditionUser pins them to abl030.
  systemd.user.services.agent-xvfb = {
    description = "Xvfb display ${display} for the agent research Chrome";
    wantedBy = ["default.target"];
    unitConfig.ConditionUser = user;
    serviceConfig = {
      ExecCondition = "${displayFree}";
      ExecStart = "${pkgs.xvfb}/bin/Xvfb ${display} -screen 0 1920x1080x24 -nolisten tcp";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  systemd.user.services.agent-chrome = {
    description = "Agent research Chrome (DevTools on 127.0.0.1:${port}, headed on Xvfb ${display})";
    wantedBy = ["default.target"];
    wants = ["agent-xvfb.service"];
    after = ["agent-xvfb.service"];
    unitConfig = {
      ConditionUser = user;
      StartLimitIntervalSec = 300;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Environment = ["DISPLAY=${display}"];
      ExecCondition = "${portFree}";
      # Same flags as ~/agents/bin/agent-chrome: no --enable-automation, so
      # navigator.webdriver stays false and there is no automation infobar.
      # --remote-debugging-port binds 127.0.0.1 only.
      ExecStart = lib.concatStringsSep " " [
        "${pkgs.google-chrome}/bin/google-chrome-stable"
        "--remote-debugging-port=${port}"
        "--user-data-dir=${profile}"
        "--no-first-run"
        "--no-default-browser-check"
      ];
      # always: Chrome exits 0 when an agent closes its last window.
      Restart = "always";
      RestartSec = 10;
      # Chrome's stdout is pure noise; stderr (crashes, GPU errors) stays.
      StandardOutput = "null";
    };
  };
}
