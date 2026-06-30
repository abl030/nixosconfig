# Self-hosted Tailscale ACL apply (issue #239, unit U4).
#
# Validates + pushes tailscale/acl.hujson to Tailscale CONTROL via gitops-pusher
# (ETag/checksum-guarded), using a `policy_file`-scoped OAuth client held in sops.
#
# WHY doc1 (the bastion), not doc2:
#   The OAuth credential can rewrite the ENTIRE tailnet trust boundary. doc1 is
#   already maximally privileged (fleet SSH key, passwordless sudo, fleet-deploy,
#   the pfSense/UniFi/HA control creds since #234), so a doc1 compromise is
#   already game-over — adding ACL-write there expands its blast radius by ~nil.
#   doc2 runs a large surface of internet-facing services; putting the crown-jewel
#   credential there would make "doc2 popped" also mean "tailnet policy rewritten."
#   Concentrate fleet-control creds on the one hardened, audited host (#234 pattern).
#
# TRIGGER MODEL:
#   Applied three ways, all idempotent (gitops-pusher no-ops when control's
#   checksum already matches, so the extra fires cost one cheap API probe):
#     1. ON EVERY `nixos-rebuild switch` — a non-blocking activation hook (see
#        system.activationScripts.tailscaleAclApply below) runs
#        `systemctl start --no-block tailscale-acl-apply.service`. So editing
#        tailscale/acl.hujson and deploying doc1 APPLIES it — no manual step.
#     2. A daily drift-correction timer.
#     3. Manual `systemctl start tailscale-acl-apply.service` (rollout/flip).
#   It is NOT wantedBy multi-user.target AND the switch hook is `--no-block`, so a
#   transient/hung Tailscale-API call can NEVER fail or delay doc1's fleet-update
#   (we refuse to couple the bastion's deploy health to api.tailscale.com); the
#   apply just runs async after activation, ordered after tailscaled by its own
#   After=. OnFailure routes through Hermes RCA first, with Gotify fallback
#   (a 401 = expired/revoked credential).
#   NB: `restartTriggers` alone does NOT re-run this inactive oneshot on switch —
#   the activation hook is what makes "apply on deploy" actually happen.
#
# CREDENTIAL LIFECYCLE:
#   Create a `policy_file`-scoped OAuth client in the Tailscale admin console
#   (Settings -> OAuth clients / Trust credentials). Store id+secret in
#   secrets/hosts/proxmox-vm/tailscale-acl-oauth.env (auto-scoped to doc1 + editor
#   + break-glass by the existing ^hosts/proxmox-vm/ rule). Rotation: create a new
#   client, re-sops, redeploy, delete the old client. Revocation on suspected doc1
#   compromise: delete the client in the console (instant), then re-key.
#
# See docs/wiki/infrastructure/tailscale-acl.md (U8) and the plan
# docs/plans/2026-06-07-002-feat-tailscale-acl-least-privilege-plan.md (U4).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.tailscale.aclApply;
  sendNegativeAlert = import ../../lib/negative-alert.nix {inherit config lib pkgs;};

  # Isolated copy of the policy file (stabilization rule: builtins.path, not a raw
  # path, so unrelated repo churn doesn't invalidate the store reference).
  aclFile = builtins.path {
    path = ../../../../tailscale/acl.hujson;
    name = "acl.hujson";
  };

  notifyFailure = pkgs.writeShellScript "tailscale-acl-apply-notify-failure" ''
    set -euo pipefail
    ${sendNegativeAlert}
    message="$(journalctl -u tailscale-acl-apply.service -n 50 --no-pager 2>/dev/null \
                 | sed 's/[[:cntrl:]]/ /g')"
    send_negative_alert "tailscale-acl-apply FAILED on ${config.networking.hostName}" "$message" 8
  '';
in {
  options.homelab.tailscale.aclApply = {
    enable = lib.mkEnableOption "self-hosted Tailscale ACL apply via gitops-pusher (doc1/bastion only)";

    tailnet = lib.mkOption {
      type = lib.types.str;
      default = "-";
      description = ''
        TS_TAILNET for the API. "-" = the OAuth client's default tailnet (works
        for this single-tailnet personal account). Set to the explicit tailnet
        name (e.g. "abl030@gmail.com") only if "-" is rejected.
      '';
    };

    failOnManualEdits = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pass -fail-on-manual-edits to gitops-pusher: if CONTROL's ACL was edited
        in the admin console out-of-band (checksum drift), FAIL rather than
        clobber. The repo is authoritative; manual edits should never happen.
      '';
    };

    onCalendar = lib.mkOption {
      type = lib.types.str;
      default = "*-*-* 05:10:00 Australia/Perth";
      description = "Daily drift-correction apply. Idempotent (no-op when checksum matches).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # The OAuth credential can rewrite the whole tailnet — keep it on the
        # bastion only. This asserts intent; the sops scoping enforces it.
        assertion = config.homelab.fleetDeploy.role == "bastion";
        message = "homelab.tailscale.aclApply must run on the bastion (doc1). The policy_file OAuth credential is a fleet-wide control credential — see the module header.";
      }
    ];

    users.users.tailscale-acl-apply = {
      isSystemUser = true;
      group = "tailscale-acl-apply";
      description = "Tailscale ACL apply (gitops-pusher) oneshot";
    };
    users.groups.tailscale-acl-apply = {};

    # policy_file-scoped OAuth client (TS_OAUTH_ID / TS_OAUTH_SECRET). Auto-scoped
    # to doc1 + editor + break-glass by the existing ^hosts/proxmox-vm/ sops rule.
    sops.secrets."tailscale-acl/oauth" = {
      sopsFile = config.homelab.secrets.sopsFile "tailscale-acl-oauth.env";
      format = "dotenv";
      mode = "0400";
      owner = "tailscale-acl-apply";
    };

    systemd.services.tailscale-acl-apply-notify-failure = {
      description = "Send tailscale-acl-apply failures to RCA, with Gotify fallback";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = notifyFailure;
      };
    };

    systemd.services.tailscale-acl-apply = {
      description = "Validate + push tailscale/acl.hujson to Tailscale CONTROL (gitops-pusher)";
      # NOT wantedBy multi-user.target — see header (never block the bastion deploy).
      after = ["network-online.target" "tailscaled.service"];
      wants = ["network-online.target"];

      # Re-run automatically only when the policy itself changes (the store path in
      # ExecStart changes), independent of the timer. Still never fails the switch
      # because this unit isn't part of any boot target.
      restartTriggers = [aclFile];

      unitConfig.OnFailure = ["tailscale-acl-apply-notify-failure.service"];

      serviceConfig = {
        Type = "oneshot";
        User = "tailscale-acl-apply";
        Group = "tailscale-acl-apply";

        # TS_OAUTH_ID / TS_OAUTH_SECRET (and optionally TS_TAILNET) from sops.
        EnvironmentFile = config.sops.secrets."tailscale-acl/oauth".path;
        Environment = ["TS_TAILNET=${cfg.tailnet}"];

        # gitops-pusher: validate (runs tests{} via the API) is implicit in apply;
        # -github-syntax=false keeps the journal clean (we're not in GH Actions).
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.tailscale-gitops-pusher}/bin/gitops-pusher"
          "-policy-file=${aclFile}"
          "-cache-file=%S/tailscale-acl-apply/version-cache.json"
          "-fail-on-manual-edits=${lib.boolToString cfg.failOnManualEdits}"
          "-github-syntax=false"
          "apply"
        ];

        StateDirectory = "tailscale-acl-apply";
        StateDirectoryMode = "0700";
        TimeoutStartSec = "5min";

        # Hardening (Sandbox patterns). The only writable path is the StateDir.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        SystemCallArchitectures = "native";
        # NOTE: no IPAddressAllow pin. api.tailscale.com sits behind a CDN with
        # rotating IPs, so a static allowlist would be an unpredictable outage
        # source. Egress containment relies instead on: least-scope OAuth
        # (policy_file only), the dedicated user, and the fs hardening above.

        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "tailscale-acl-apply";
      };
    };

    # Apply on every switch — the plan's original "invoke on deploy", made safe.
    # `--no-block` queues the oneshot and returns immediately, so a slow or
    # unreachable api.tailscale.com NEVER delays or fails the switch (the unit's
    # own After=tailscaled + network-online ordering still applies). Idempotent,
    # so unrelated rebuilds just cost one checksum probe; a real acl.hujson change
    # gets pushed to control without a manual `systemctl start`. `|| true` so a
    # systemctl hiccup can't fail activation either.
    system.activationScripts.tailscaleAclApply.text = ''
      ${config.systemd.package}/bin/systemctl start --no-block tailscale-acl-apply.service || true
    '';

    systemd.timers.tailscale-acl-apply = {
      description = "Daily Tailscale ACL drift-correction apply";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = cfg.onCalendar;
        Persistent = true;
        RandomizedDelaySec = "5min";
      };
    };
  };
}
