# tailscale/acl-apply.nix — self-hosted apply of the repo-owned tailnet policy.
#
# Applies ../../../../tailscale/acl.hujson to the tailnet from a single trusted
# host (doc2) using a policy_file-scoped OAuth client held in sops. NOT a GitHub
# Action — the repo runs no CI workflows. See issue #239 / the ACL plan.
#
# The flow (validated 2026-06-08 against the live API):
#   1. exchange the OAuth client creds for a short-lived access token
#   2. POST the policy to /acl/validate — runs the tests{} block; ABORTS on any
#      failure (this is the pre-apply gate that catches grant typos)
#   3. GET the current policy's ETag
#   4. POST the policy with If-Match: <etag> — optimistic-concurrency guard so a
#      concurrent admin-console edit can't be silently clobbered (412 => re-run)
#
# MANUAL trigger only (no wantedBy / no timer): `systemctl start
# tailscale-acl-apply.service`. The U7 cutover runs it from the home LAN with
# break-glass ready. Making it deploy-triggered for ongoing repo->tailnet sync
# is a deliberate later step, once the initial default-deny flip is verified.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.tailscale.aclApply;

  # Checked-in policy, isolated into the store (stabilization rule).
  aclFile = builtins.path {
    path = ../../../../tailscale/acl.hujson;
    name = "tailscale-acl.hujson";
  };

  applyScript = pkgs.writeShellApplication {
    name = "tailscale-acl-apply";
    runtimeInputs = [pkgs.curl pkgs.jq];
    text = ''
      set -euo pipefail
      # Creds come from the sops EnvironmentFile:
      #   TS_OAUTH_CLIENT_ID, TS_OAUTH_CLIENT_SECRET, TS_TAILNET
      : "''${TS_OAUTH_CLIENT_ID:?}" "''${TS_OAUTH_CLIENT_SECRET:?}" "''${TS_TAILNET:?}"
      api="https://api.tailscale.com/api/v2"
      acl=${aclFile}

      echo "tailscale-acl-apply: requesting access token..."
      token=$(curl -fsS "$api/oauth/token" \
        -d "client_id=$TS_OAUTH_CLIENT_ID" \
        -d "client_secret=$TS_OAUTH_CLIENT_SECRET" | jq -r '.access_token // empty')
      [ -n "$token" ] || { echo "tailscale-acl-apply: failed to obtain token" >&2; exit 1; }

      echo "tailscale-acl-apply: validating policy (runs tests{})..."
      v=$(curl -fsS -X POST "$api/tailnet/$TS_TAILNET/acl/validate" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/hujson" \
        --data-binary @"$acl")
      if [ -n "$v" ] && [ "$v" != "{}" ]; then
        echo "tailscale-acl-apply: VALIDATION FAILED — not applying:" >&2
        echo "$v" >&2
        exit 1
      fi
      echo "tailscale-acl-apply: validation passed."

      echo "tailscale-acl-apply: fetching current policy ETag..."
      etag=$(curl -fsS -D - -o /dev/null "$api/tailnet/$TS_TAILNET/acl" \
        -H "Authorization: Bearer $token" -H "Accept: application/hujson" \
        | tr -d '\r' | awk 'tolower($1) == "etag:" {print $2}')
      [ -n "$etag" ] || { echo "tailscale-acl-apply: could not read current ETag" >&2; exit 1; }

      echo "tailscale-acl-apply: applying policy (If-Match: $etag)..."
      # 412 Precondition Failed => the live policy changed out-of-band; re-run.
      http=$(curl -sS -o /tmp/ts-acl-apply-resp -w '%{http_code}' \
        -X POST "$api/tailnet/$TS_TAILNET/acl" \
        -H "Authorization: Bearer $token" -H "Content-Type: application/hujson" \
        -H "If-Match: $etag" --data-binary @"$acl")
      if [ "$http" != "200" ]; then
        echo "tailscale-acl-apply: apply FAILED (HTTP $http):" >&2
        cat /tmp/ts-acl-apply-resp >&2 || true
        [ "$http" = "412" ] && echo "  (ETag mismatch — the live policy changed; re-run to reconcile)" >&2
        exit 1
      fi
      echo "tailscale-acl-apply: policy applied successfully."
    '';
  };
in {
  options.homelab.tailscale.aclApply.enable =
    lib.mkEnableOption "self-hosted Tailscale ACL apply (gitops, manual trigger)";

  config = lib.mkIf cfg.enable {
    # policy_file OAuth client — doc2-scoped (see secrets/.sops.yaml).
    sops.secrets."tailscale-acl-oauth" = {
      sopsFile = config.homelab.secrets.sopsFile "tailscale-acl-oauth.env";
      format = "dotenv";
      mode = "0400";
    };

    systemd.services.tailscale-acl-apply = {
      description = "Apply repo-owned tailscale/acl.hujson to the tailnet (manual)";
      # Intentionally NO wantedBy / timer — operator-triggered (U7 cutover).
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${applyScript}/bin/tailscale-acl-apply";
        EnvironmentFile = config.sops.secrets."tailscale-acl-oauth".path;
        # Hardening (the credential can rewrite the whole tailnet policy).
        DynamicUser = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = ["AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        # NOTE: egress is NOT IP-pinned — api.tailscale.com is CDN-fronted with
        # rotating IPs, so IPAddressAllow can't target it reliably. The sops
        # host-scoping + policy_file-only OAuth scope are the controls.
      };
    };
  };
}
