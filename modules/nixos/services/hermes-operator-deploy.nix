# homelab.hermesOperatorDeploy — authorize the dedicated `hermes-deploy`
# operator key to trigger `fleet-update` on THIS host, and nothing else.
#
# Part of the Hermes "full operator" tier (docs/wiki/services/hermes-agent.md).
# The hermes agent runs in a locked-down container on its own VM and is keyless
# re: the fleet. When you drive it from a TUI session launched on the doc1
# bastion, a SCOPED ssh-agent is forwarded into the container holding this
# `hermes-deploy` key (private half lives ONLY on doc1; never on the hermes box).
# This lets a *human-present* session run the cratedigger ship/verify loop —
# deploy doc2 + verify via Loki — without handing the agent the fleet key.
#
# ── LEAST-PRIVILEGE (CLAUDE.md) ─────────────────────────────────────────────
# A leak of `hermes-deploy` buys an attacker ONLY "trigger a verified-master
# redeploy (or dry-run) of this host", and only from the tailnet/home-LAN:
#   * Forced command — the key can run nothing but the trigger below. No shell,
#     no arg passthrough (only the SSH_ORIGINAL_COMMAND allow-list deploy|dry-run).
#   * `restrict` — strips pty, port/agent/X11 forwarding.
#   * `from=` — tailnet (100.64.0.0/10) + home LAN (192.168.1.0/24) only.
#   * fleet-update only ever builds SIGNED commits already on Forgejo master, so
#     this cannot deploy arbitrary code — shipping new code still needs the
#     separate signing + push keys. Strictly weaker than the fleet key (which is
#     full root SSH to siblings). Mirrors the marker-convert / gwm-archiver
#     forced-command trigger-key pattern (#270).
# Opt-in per host. doc2 only as of the cratedigger operator loop.
{
  lib,
  config,
  pkgs,
  allHosts,
  hostname,
  ...
}: let
  cfg = config.homelab.services.hermesOperatorDeploy;
  inherit (allHosts.${hostname}) user;

  # Public half of the hermes-deploy operator key.
  # Private half: doc1 only (sops), forwarded ephemerally into the TUI session.
  hermesDeployPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMAJbMYnUy64S/nCbKA+qH6S9x/32471WlcGYqdvPy/p hermes-deploy@operator";

  trigger = pkgs.writeShellScript "hermes-deploy-trigger" ''
    set -eu
    export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
    case "''${SSH_ORIGINAL_COMMAND:-deploy}" in
      deploy | "") exec sudo fleet-update ;;
      dry-run) exec sudo fleet-update --dry-run ;;
      *)
        echo "hermes-deploy: refused (allowed commands: deploy, dry-run)" >&2
        exit 2
        ;;
    esac
  '';
in {
  options.homelab.services.hermesOperatorDeploy.enable = lib.mkEnableOption ''
    authorizing the hermes-deploy operator key to trigger `fleet-update` on this
    host (forced-command + restrict + tailnet/LAN-pinned). The holder can ONLY
    redeploy verified master or dry-run — nothing else. Opt-in per host'';

  config = lib.mkIf cfg.enable {
    users.users.${user}.openssh.authorizedKeys.keys = [
      ''command="${trigger}",restrict,from="100.64.0.0/10,192.168.1.0/24" ${hermesDeployPubKey}''
    ];
  };
}
