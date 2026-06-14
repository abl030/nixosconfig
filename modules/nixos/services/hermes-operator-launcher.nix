# homelab.services.hermesOperatorLauncher — the doc1 (bastion) launch point for
# the Hermes "full operator" TUI. Deploys the scoped operator keys from sops and
# installs the `hermes-operator` command. doc1 ONLY (it is the only host that can
# reach hermes, and the only place the operator keys are decryptable).
#
# See docs/wiki/services/hermes-agent.md (capability-tiers). The companion
# pieces: the doc2 forced-command grant (hermes-operator-deploy.nix) and the
# agent-bridge installed on the hermes host (hosts/hermes/configuration.nix).
#
# ── LEAST-PRIVILEGE (CLAUDE.md) ─────────────────────────────────────────────
# The two keys are scoped + low-power: hermes-deploy can ONLY trigger
# fleet-update on doc2 (forced-command); hermes-forgejo pushes to Forgejo. Both
# are owned by the launching user, mode 0400, and decryptable only on doc1
# (per-host sops scope, #234). They are forwarded into the agent's container ONLY
# during a human-launched session and never stored there.
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
  launcher = pkgs.writeShellScriptBin "hermes-operator" (builtins.readFile ../../../hosts/hermes/operator/hermes-operator.sh);
in {
  options.homelab.services.hermesOperatorLauncher.enable = lib.mkEnableOption ''
    the doc1 launch point (`hermes-operator`) for the Hermes full-operator TUI:
    deploys the scoped operator keys (hermes-deploy, hermes-forgejo) via sops and
    installs the launcher. Bastion/doc1 only'';

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
    environment.systemPackages = [launcher];
  };
}
