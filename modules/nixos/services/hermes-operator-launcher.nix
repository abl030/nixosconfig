# homelab.services.hermesOperatorLauncher — the doc1 (bastion) launch point for
# the Hermes "full operator" TUI, plus the cratedigger flake-bump trigger.
# Deploys the scoped operator keys from sops, installs the `hermes-operator`
# command, and authorizes the hermes-deploy key to run the (and only the)
# cratedigger-src re-pin. doc1 ONLY.
#
# See docs/wiki/services/hermes-agent.md (capability-tiers). Companion pieces:
# the doc2 forced-command deploy grant (hermes-operator-deploy.nix) and the
# agent-bridge on the hermes host (hosts/hermes/configuration.nix).
#
# ── LEAST-PRIVILEGE (CLAUDE.md) ─────────────────────────────────────────────
# Two grants live here, both narrow:
#   * Operator keys (hermes-deploy, hermes-forgejo): sops-scoped to doc1, owned
#     by the launching user, 0400. Forwarded into the agent's container ONLY
#     during a human-launched session; never stored there.
#   * cratedigger-bump forced-command: the SAME hermes-deploy key, authorized on
#     doc1 to run ONE script that re-pins `cratedigger-src` and pushes the
#     lockfile bump to Forgejo master, SIGNED by the rolling bot key (the caller
#     never holds that key — they only trigger the re-pin). `restrict` strips
#     pty/forwarding; `from=` pins to tailnet/LAN. Blast radius of a leak: spam
#     cratedigger re-pins (which only affect doc2's build). Mirrors the doc2
#     deploy grant + the marker-convert / gwm-archiver trigger pattern.
{
  lib,
  config,
  pkgs,
  allHosts,
  hostname,
  ...
}: let
  cfg = config.homelab.services.hermesOperatorLauncher;
  inherit (allHosts.${hostname}) user;

  # Public half of the hermes-deploy operator key (private: sops, forwarded).
  hermesDeployPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMAJbMYnUy64S/nCbKA+qH6S9x/32471WlcGYqdvPy/p hermes-deploy@operator";

  launcher = pkgs.writeShellScriptBin "hermes-operator" (builtins.readFile ../../../hosts/hermes/operator/hermes-operator.sh);

  bumpTrigger = pkgs.writeShellApplication {
    name = "cratedigger-bump";
    runtimeInputs = [pkgs.git pkgs.nix pkgs.openssh pkgs.coreutils];
    text = builtins.readFile ../../../hosts/hermes/operator/cratedigger-bump.sh;
  };
in {
  options.homelab.services.hermesOperatorLauncher.enable = lib.mkEnableOption ''
    the doc1 launch point (`hermes-operator`) for the Hermes full-operator TUI:
    deploys the scoped operator keys (hermes-deploy, hermes-forgejo) via sops,
    installs the launcher, and authorizes the cratedigger-src bump trigger.
    Bastion/doc1 only'';

  config = lib.mkIf cfg.enable {
    sops.secrets."hermes-deploy-key" = {
      sopsFile = config.homelab.secrets.sopsFile "hermes-deploy-key";
      format = "binary";
      owner = user;
      mode = "0400";
    };
    sops.secrets."hermes-forgejo-key" = {
      sopsFile = config.homelab.secrets.sopsFile "hermes-forgejo-key";
      format = "binary";
      owner = user;
      mode = "0400";
    };

    environment.systemPackages = [launcher bumpTrigger];

    # Clean clone the bump trigger operates in (never the live tree).
    systemd.tmpfiles.rules = [
      "d /var/lib/hermes-operator 0700 ${user} users - -"
    ];

    # Authorize the hermes-deploy key to run ONLY the cratedigger-src bump here.
    users.users.${user}.openssh.authorizedKeys.keys = [
      ''command="${bumpTrigger}/bin/cratedigger-bump",restrict,from="100.64.0.0/10,192.168.1.0/24" ${hermesDeployPubKey}''
    ];
  };
}
