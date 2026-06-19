# fleet-deploy — trigger a sibling's verified rebuild from the doc1 bastion
# WITHOUT the sibling needing passwordless sudo (forgejo#2).
#
# ONE knob, default-secure (forgejo#2 refactor): `homelab.fleetDeploy.role`.
#   Mental model — "every host is LOCKED; doc1 is the one BASTION." A new host
#   is secure by default; you must *explicitly* write role = "bastion" to unlock.
#
#   * role = "locked" (DEFAULT) — the doc2 model. No passwordless sudo (base.nix
#     sets wheelNeedsPassword = true off this same option); abl030 keeps ONLY the
#     narrow read-only/deploy-hygiene NOPASSWD allowlist below; the host accepts
#     the doc1 bastion's forced-command deploy trigger (polkit-scoped to start
#     ONLY nixos-upgrade.service); the base.nix GTFOBin diag tools are gated off.
#   * role = "bastion" — doc1 ONLY. Passwordless sudo (base.nix); holds the
#     deploy-trigger private key + the `fleet-deploy <host>` wrapper; keeps the
#     passwordless diagnostic tools. Exactly one host may be the bastion — the
#     `fleetBastionRoleCheck` flake check enforces it.
#
# Model (mirrors the marker-convert / gwm-archiver forced-command pattern, #270):
#   * Every host already runs `nixos-upgrade.service` (root oneshot → fetch
#     Forgejo, verify signatures, build at the verified SHA, switch). That's the
#     SAME verified path the nightly timer uses.
#   * A locked host adds a polkit rule letting `triggerUser` start ONLY that one
#     unit without a password, plus a forced-command SSH key on that user locked
#     to exactly `systemctl start --no-block nixos-upgrade.service`, `restrict`ed
#     and source-pinned. A successful connection IS the trigger; a leaked key can
#     do nothing but kick a rebuild of the already-signed config.
#   * The bastion (doc1) holds the private half (sops, doc1-scoped) and a
#     `fleet-deploy <host>` wrapper.
#
# This is what lets every sibling drop passwordless sudo while doc1 can still
# deploy it — the trigger rides polkit + a forced command, not sudo.
{
  config,
  lib,
  pkgs,
  hostConfig,
  allHosts,
  ...
}: let
  cfg = config.homelab.fleetDeploy;
  bin = "/run/current-system/sw/bin";

  # `fleet-deploy <host>` resolves the TARGET's login user + ssh address from
  # hosts.nix — not doc1's own user. Critical for wsl (user = nixos, reached at
  # the Windows port-forward `sshHostName`, not "wsl"). Full NixOS hosts only
  # (caddy is HM-only, has no nixos-upgrade.service to trigger).
  deployTargets = lib.filterAttrs (_: h: h ? configurationFile) allHosts;
  # Single-line, space-separated bash assoc-array bodies (formatter-stable; the
  # multi-line form gets reindented inside the ''…'' script and renders ugly).
  userMap = lib.concatStringsSep " " (lib.mapAttrsToList (name: h: ''[${name}]="${h.user}"'') deployTargets);
  addrMap = lib.concatStringsSep " " (lib.mapAttrsToList (name: h: ''[${name}]="${h.sshHostName or h.hostname}"'') deployTargets);
in {
  options.homelab.fleetDeploy = {
    role = lib.mkOption {
      type = lib.types.enum ["locked" "bastion"];
      default = "locked";
      description = ''
        Fleet security posture for this host (forgejo#2).

        "locked" (DEFAULT) — no passwordless sudo; abl030 keeps only the narrow
        read-only/deploy-hygiene NOPASSWD allowlist; accepts the doc1 bastion's
        forced-command deploy trigger (verified rebuild via polkit, no sudo); the
        base.nix GTFOBin diag tools are gated off. The doc2 model.

        "bastion" — doc1 ONLY. Passwordless sudo; holds the deploy-trigger
        private key + the `fleet-deploy <host>` wrapper; keeps the passwordless
        diagnostic tools. Exactly one host may be the bastion (enforced by the
        fleetBastionRoleCheck flake check).
      '';
    };

    triggerUser = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User the forced-command key + polkit start-grant apply to (locked hosts).";
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
  };

  config = lib.mkMerge [
    # ---------------- LOCKED (default): accept trigger + narrow allowlist ----
    (lib.mkIf (cfg.role == "locked") {
      # Let triggerUser start ONLY nixos-upgrade.service, no password — this is
      # what survives once passwordless sudo is removed.
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

      # With passwordless sudo gone (wheelNeedsPassword = true, set in base.nix
      # off role != "bastion"), ${hostConfig.user} keeps ONLY this narrow
      # allowlist passwordless. Everything else needs the console (break-glass) or
      # a signed deploy via `fleet-deploy`. A popped ${hostConfig.user} here can
      # observe, restart a container, and trigger a SIGNED rebuild — nothing that
      # escalates to root, no cat/rm, no exec, no secret-file read.
      #   * read-only podman: rootful, so even reading needs root. (`inspect` can
      #     reveal a container's env — a minor residual; the win is no root pivot.)
      #     These have no pager/shell escape; `journalctl` is deliberately NOT
      #     here (its pager `!sh` is a root escape) — read logs via Loki instead.
      #   * `systemctl stop nixos-rebuild-switch-to-configuration.service`: lets me
      #     clear a stale deploy-switch so the next fleet-deploy isn't blocked.
      #   * `systemctl restart podman-*`: bounded container recovery (container
      #     units only — can't touch sshd/system units).
      # The recovery net if this allowlist is ever wrong: `fleet-deploy <host>`
      # uses polkit, not sudo, so a corrected config can always be deployed.
      security.sudo.extraRules = lib.mkAfter [
        {
          users = [hostConfig.user];
          commands =
            map (command: {
              inherit command;
              options = ["NOPASSWD"];
            }) [
              "${bin}/podman ps"
              "${bin}/podman ps *"
              "${bin}/podman inspect *"
              "${bin}/podman logs *"
              "${bin}/podman top *"
              "${bin}/podman port *"
              "${bin}/podman stats"
              "${bin}/podman stats *"
              "${bin}/podman images"
              "${bin}/podman images *"
              "${bin}/podman network ls"
              "${bin}/podman network inspect *"
              "${bin}/systemctl stop nixos-rebuild-switch-to-configuration.service"
              "${bin}/systemctl restart podman-*"
            ];
        }
      ];
    })

    # ---------------- BASTION (doc1 only): hold deploy key + wrapper --------
    (lib.mkIf (cfg.role == "bastion") {
      sops.secrets."deploy-trigger/key" = {
        sopsFile = config.homelab.secrets.sopsFile "deploy-trigger-key";
        format = "binary";
        owner = hostConfig.user;
        mode = "0400";
      };

      # `fleet-deploy <host>` → fire the sibling's verified rebuild over the
      # forced-command key. No sudo on the target; the trigger IS the success.
      # <host> is a hosts.nix attr name (doc2, igpu, wsl, hermes, …); user + ssh
      # address are looked up from hosts.nix so this is correct even where the
      # login user isn't abl030 (wsl = nixos) or the address isn't the hostname
      # (wsl reached at the Windows port-forward).
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "fleet-deploy" ''
          set -euo pipefail
          target="''${1:?usage: fleet-deploy <host>}"
          declare -A users=( ${userMap} )
          declare -A addrs=( ${addrMap} )
          user="''${users[$target]:-}"
          addr="''${addrs[$target]:-}"
          if [ -z "$user" ] || [ -z "$addr" ]; then
            echo "fleet-deploy: unknown host '$target' (not a full NixOS host in hosts.nix)" >&2
            echo "known: ''${!users[*]}" >&2
            exit 2
          fi
          echo "triggering verified rebuild on $target ($user@$addr, forced-command, no sudo)…"
          exec ${pkgs.openssh}/bin/ssh \
            -i ${config.sops.secrets."deploy-trigger/key".path} \
            -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            "$user@$addr"
        '')
      ];
    })
  ];
}
