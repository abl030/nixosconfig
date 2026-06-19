# fleet-deploy — trigger a sibling's verified rebuild from the doc1 bastion
# WITHOUT the sibling needing passwordless sudo (forgejo#2 Phase 2).
#
# Model (mirrors the marker-convert / gwm-archiver forced-command pattern, #270):
#   * The sibling already runs `nixos-upgrade.service` (root oneshot → fetch
#     Forgejo, verify signatures, build at the verified SHA, switch). That's the
#     SAME verified path the nightly timer uses.
#   * `acceptTrigger` (sibling side) adds a polkit rule letting `triggerUser`
#     start ONLY that one unit without a password, plus a forced-command SSH key
#     on that user locked to exactly `systemctl start --no-block
#     nixos-upgrade.service`, `restrict`ed and source-pinned. A successful
#     connection IS the trigger; a leaked key can do nothing but kick a rebuild
#     of the already-signed config.
#   * `bastion` (doc1 side) holds the private half (sops, doc1-scoped) and a
#     `fleet-deploy <host>` wrapper.
#
# This is what lets a sibling drop passwordless sudo (Phase 3) while doc1 can
# still deploy it — the trigger rides polkit + a forced command, not sudo.
{
  config,
  lib,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.fleetDeploy;
in {
  options.homelab.fleetDeploy = {
    # ---- sibling (target) side ----
    acceptTrigger = lib.mkEnableOption "accept the bastion's forced-command deploy trigger";

    triggerUser = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User the forced-command key + polkit start-grant apply to.";
    };

    triggerPublicKey = lib.mkOption {
      type = lib.types.str;
      default = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEmqPJGKUl7lOKd/zaJNdI9WFa1zsFalTU8jkvL7UYWx fleet-deploy-trigger@doc1";
      description = "Public half of the doc1 bastion's deploy-trigger key.";
    };

    triggerFrom = lib.mkOption {
      type = lib.types.str;
      default = "100.64.0.0/10,192.168.1.0/24";
      description = "Source pin for the forced-command key (tailnet + home LAN).";
    };

    # ---- doc1 bastion side ----
    bastion = lib.mkEnableOption "hold the deploy-trigger private key + fleet-deploy wrapper";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.acceptTrigger {
      # Let triggerUser start ONLY nixos-upgrade.service, no password — this is
      # what survives once passwordless sudo is removed (Phase 3).
      security.polkit.extraConfig = ''
        // fleet-deploy: ${cfg.triggerUser} may start (only) nixos-upgrade.service,
        // the remote deploy trigger from the doc1 bastion (forgejo#2).
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "nixos-upgrade.service" &&
              action.lookup("verb") == "start" &&
              subject.user == "${cfg.triggerUser}") {
            return polkit.Result.YES;
          }
        });
      '';

      # Forced-command key: connecting with the bastion's deploy key does exactly
      # one thing — kick the verified rebuild. restrict strips pty/forwarding/etc.
      users.users.${cfg.triggerUser}.openssh.authorizedKeys.keys = [
        ''command="${config.systemd.package}/bin/systemctl start --no-block nixos-upgrade.service",restrict,from="${cfg.triggerFrom}" ${cfg.triggerPublicKey}''
      ];
    })

    (lib.mkIf cfg.bastion {
      sops.secrets."deploy-trigger/key" = {
        sopsFile = config.homelab.secrets.sopsFile "deploy-trigger-key";
        format = "binary";
        owner = hostConfig.user;
        mode = "0400";
      };

      # `fleet-deploy <host>` → fire the sibling's verified rebuild over the
      # forced-command key. No sudo on the target; the trigger IS the success.
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "fleet-deploy" ''
          set -euo pipefail
          target="''${1:?usage: fleet-deploy <host>}"
          echo "triggering verified rebuild on $target (forced-command, no sudo)…"
          exec ${pkgs.openssh}/bin/ssh \
            -i ${config.sops.secrets."deploy-trigger/key".path} \
            -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            "${hostConfig.user}@$target"
        '')
      ];
    })
  ];
}
