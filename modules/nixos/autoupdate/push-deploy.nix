# push-deploy — target-side activation for hosts that can't rebuild locally.
# =========================================================================
# The doc1 bastion builds every host's closure nightly (populate_cache.sh in
# rolling-flake-update). For RAM-constrained hosts a local `nixos-rebuild` OOMs
# (servarr: 4 GiB) or is impossible (igpu: unprivileged LXC), so instead doc1
# hands the already-built store path to the host and the host just *activates*
# it — no local eval, no local build, no OOM. See forgejo#10.
#
# TRIGGER MODEL — a restricted forced-command key on ROOT (NOT polkit / sudo):
#   * The host authorizes ONE key on `root`: the doc1 fleet-deploy trigger key,
#     pinned with `command="<trigger-wrapper>",restrict,from=<tailnet+LAN>`. The
#     key can do EXACTLY one thing — run the wrapper — and nothing else (no shell,
#     no pty, no forwarding). Only doc1 holds the private half (sops, doc1-scoped),
#     so only doc1 can fire it.
#   * `PermitRootLogin` is forced to "forced-commands-only": root may log in ONLY
#     via a forced-command key. Interactive and password root login stay OFF
#     (strictly narrower than the "prohibit-password" ssh.secure=false gives, and
#     it opens — for this one key only — the "no" ssh.secure=true sets on servarr).
#   * doc1 connects `root@host "<store-path>"`; the forced command ignores the
#     requested command and runs the wrapper, exposing the path as
#     $SSH_ORIGINAL_COMMAND.
#
#   The wrapper does the MINIMUM in-session: validate the path, stage it to a
#   root-only file, and `systemctl start --no-block push-activate.service`, then
#   exit. The heavy work (realise + switch-to-configuration) runs in
#   push-activate.service under PID 1, NOT in the SSH login session. This mirrors
#   fleet-deploy's `systemctl start --no-block nixos-upgrade` exactly, and is what
#   keeps the root login session trivial: a switch run *inside* the session leaves
#   root's `systemd --user` manager holding /run/user/0 and, on an LXC, the runtime
#   dir teardown then loses the race and fails ("Directory not empty" → degraded).
#   Trigger-and-detach sidesteps that. doc1 confirms the outcome by polling the
#   host's generation + push-activate.service result (scripts/push_deploy.sh).
#
# WHY NOT polkit + abl030: a polkit rule granting the login user `systemctl start`
# on the activation unit lets ANY session of that user activate whatever path it
# can stage — on a locked host (igpu) that is a new passwordless root path. This
# design keeps the whole activation OUT of the login user's reach: it runs off a
# key only doc1 holds, and both the trigger and the staged path are root-only, so
# target sudo posture is irrelevant ("we don't care about sudo status on the VMs")
# and no interactive session gains anything.
#
# TRUST BOUNDARY: a LEAKED deploy key can still only activate closures doc1 has
# SIGNED INTO THE CACHE — push-activate.service realises via the nix daemon, which
# accepts a substituted path only if signed by a trusted key (doc1's cache key,
# ablz.au-1:…, already trusted at priority 10 on every internal host). An
# unsigned/unbuildable path fails closed. Same trust root as fleet-deploy (doc1 is
# the bastion); no surface beyond trusting doc1's binary cache, which the host
# already does.
#
# See docs/wiki/infrastructure/push-deploy.md (forgejo#10).
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.homelab.update.pushDeploy;
  fleetCfg = config.homelab.fleetDeploy;
  stagedFile = "/run/push-deploy/staged";

  # In-session forced command: validate + stage + fire push-activate.service
  # --no-block, then exit. Deliberately does NO heavy work in the login session
  # (see the runtime-dir race note above).
  triggerScript = pkgs.writeShellScript "push-trigger" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [config.systemd.package pkgs.coreutils]}:$PATH

    # Strip stray whitespace/newline; a store path never contains spaces.
    toplevel="$(printf '%s' "''${SSH_ORIGINAL_COMMAND:-}" | tr -d '[:space:]')"
    case "$toplevel" in
      /nix/store/*) ;;
      *) echo "push-deploy: refusing non-store path: '$toplevel'" >&2; exit 1 ;;
    esac

    # Refuse closures for another host. If doc1 ever hands the wrong GC root to a
    # target, fail closed before staging instead of activating e.g. caddy on igpu.
    base="$(basename "$toplevel")"
    case "$base" in
      *-nixos-system-${config.networking.hostName}-*) ;;
      *) echo "push-deploy: refusing closure for another host on ${config.networking.hostName}: '$base'" >&2; exit 1 ;;
    esac

    # Stage the path for push-activate.service. /run/push-deploy is 0700 root
    # (tmpfiles below), so only this root wrapper can write it — no login-user
    # tampering. The service re-validates and signature-checks on read.
    umask 077
    printf '%s\n' "$toplevel" > ${stagedFile}

    # Clear any leftover failed state from a prior run so the poll reads cleanly.
    systemctl reset-failed push-activate.service 2>/dev/null || true
    echo "push-deploy: staged $toplevel; starting push-activate.service"
    exec systemctl start --no-block push-activate.service
  '';
in {
  options.homelab.update.pushDeploy = {
    enable = lib.mkEnableOption "Accept pre-built closures from the doc1 bastion via a root forced-command key (for hosts that can't rebuild locally)";
  };

  config = lib.mkIf cfg.enable {
    # Root login ONLY via a forced-command key. Overrides the ssh module's
    # PermitRootLogin ("no" when ssh.secure=true, e.g. servarr; "prohibit-password"
    # when false, e.g. igpu) — mkForce so this one narrow value wins. Interactive
    # and password root login remain disabled either way.
    services.openssh.settings.PermitRootLogin = lib.mkForce "forced-commands-only";

    # The doc1 deploy key, locked to run ONLY the trigger wrapper. Reuses the
    # fleet-deploy trigger key (already lives ONLY on doc1, sops-scoped); it is
    # authorized on a DIFFERENT login user here (root vs abl030 for fleet-deploy),
    # so sshd selects this entry by login user. `restrict` strips
    # pty/forwarding/agent/X11; `from=` pins the source to tailnet + home LAN.
    users.users.root.openssh.authorizedKeys.keys = [
      ''command="${triggerScript}",restrict,from="${fleetCfg.triggerFrom}" ${fleetCfg.triggerPublicKey}''
    ];

    # Root-only staging dir for the closure path handed over by the trigger.
    systemd.tmpfiles.rules = [
      "d /run/push-deploy 0700 root root -"
    ];

    # Root now logs in (forced-command) to fire the trigger — it never did before.
    # On an LXC, that root login's `/run/user/0` loses its teardown race on logout:
    # user-runtime-dir@0.service's ExecStop rmdir fails "Directory not empty"
    # (exit 1) and the host flaps to `degraded`. It is COSMETIC — the tmpfs is
    # unmounted, only the now-empty mount-point dir removal fails, and the next
    # login re-mounts fine — but a degraded host trips health checks. The switch
    # already runs under PID 1 (above), so this is purely the root *login session*,
    # not our activation (igpu reproduced it even with an empty trigger). Treat that
    # one benign exit-1 as success so the host stays clean. Scoped to @0 (root) and
    # only on push-deploy hosts; servarr (a VM) never hits it but the override is
    # inert there. Verified 2026-07-01.
    systemd.services."user-runtime-dir@0" = {
      overrideStrategy = "asDropin";
      serviceConfig.SuccessExitStatus = "1";
    };

    # The actual activation, run under PID 1 (never in the SSH login session).
    # Realises the staged closure from nixcache.ablz.au (signature-checked
    # substitution), registers it as the system generation, and switches.
    systemd.services.push-activate = {
      description = "Activate a doc1-staged NixOS closure (push-deploy, forgejo#10)";
      # Do not tie to network-online here — the trigger only fires after doc1 has
      # already reached us, and the cache is on the LAN.
      serviceConfig = {
        Type = "oneshot";
        # Realise + activation can take a few minutes on a cold cache pull.
        TimeoutStartSec = "30min";
      };
      path = [pkgs.nix pkgs.coreutils];
      script = ''
        set -euo pipefail
        if [ ! -f "${stagedFile}" ]; then
          echo "push-activate: no staged path at ${stagedFile}" >&2
          exit 1
        fi
        toplevel="$(tr -d '[:space:]' < "${stagedFile}")"
        case "$toplevel" in
          /nix/store/*) ;;
          *) echo "push-activate: invalid staged path: '$toplevel'" >&2; exit 1 ;;
        esac
        base="$(basename "$toplevel")"
        case "$base" in
          *-nixos-system-${config.networking.hostName}-*) ;;
          *) echo "push-activate: refusing closure for another host on ${config.networking.hostName}: '$base'" >&2; exit 1 ;;
        esac

        # Realise from the binary cache if not already present. For a not-yet-local
        # path this forces substitution, which the nix daemon accepts ONLY if the
        # narinfo is signed by a trusted key (doc1's cache key). Unsigned or
        # unbuildable ⇒ fails closed.
        if [ ! -e "$toplevel" ]; then
          echo "push-activate: realising $toplevel from cache…"
          nix-store --realise "$toplevel" >/dev/null
        fi

        if [ ! -x "$toplevel/bin/switch-to-configuration" ]; then
          echo "push-activate: no switch-to-configuration at $toplevel" >&2
          exit 1
        fi

        # Register as the current system generation (boot default) then activate —
        # exactly what `nixos-rebuild switch` does under the hood.
        echo "push-activate: registering + switching to $toplevel"
        nix-env -p /nix/var/nix/profiles/system --set "$toplevel"
        exec "$toplevel/bin/switch-to-configuration" switch
      '';
    };
  };
}
