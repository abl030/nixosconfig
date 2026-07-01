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
#     pinned with `command="<activate-wrapper>",restrict,from=<tailnet+LAN>`. The
#     key can do EXACTLY one thing — run the wrapper as root — and nothing else
#     (no shell, no pty, no forwarding). Only doc1 holds the private half (sops,
#     doc1-scoped), so only doc1 can fire it.
#   * `PermitRootLogin` is forced to "forced-commands-only": root may log in ONLY
#     via a forced-command key. Interactive and password root login stay OFF
#     (this is strictly narrower than the "prohibit-password" that ssh.secure=false
#     would otherwise give, and it un-blocks the "no" that ssh.secure=true sets on
#     servarr — for this one key only).
#   * doc1 connects `root@host "<store-path>"`; the forced command ignores the
#     requested command and runs the wrapper, exposing the path as
#     $SSH_ORIGINAL_COMMAND. The wrapper validates it, realises it from the cache,
#     registers it as the system generation, and switches.
#
# WHY NOT polkit + abl030 (the first cut): a polkit rule granting the login user
# `systemctl start` on an activation unit lets ANY session of that user activate
# whatever path it can stage — on a locked host (igpu) that is a new passwordless
# root path. This design keeps the whole activation OUT of the login user's reach:
# it runs as root off a key only doc1 holds, so target sudo posture is irrelevant
# ("we don't care about sudo status on the VMs") and no interactive session gains
# anything. Mirrors the fleet-deploy / marker-convert forced-command pattern.
#
# TRUST BOUNDARY: a LEAKED deploy key can still only activate closures doc1 has
# SIGNED INTO THE CACHE — the wrapper realises via the nix daemon, which accepts a
# substituted path only if signed by a trusted key (doc1's cache key, ablz.au-1:…,
# already trusted at priority 10 on every internal host). An unsigned/unbuildable
# path fails closed. That is the SAME trust root as fleet-deploy (doc1 is the
# bastion); this adds no surface beyond trusting doc1's binary cache, which the
# host already does.
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

  # The ONLY thing the doc1 deploy key can run as root. Receives the target store
  # path via $SSH_ORIGINAL_COMMAND (set by sshd to whatever doc1 asked to run,
  # which the forced command otherwise ignores).
  activateScript = pkgs.writeShellScript "push-activate" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [pkgs.nix pkgs.coreutils]}:$PATH

    # Strip stray whitespace/newline; a store path never contains spaces.
    toplevel="$(printf '%s' "''${SSH_ORIGINAL_COMMAND:-}" | tr -d '[:space:]')"

    case "$toplevel" in
      /nix/store/*) ;;
      *) echo "push-activate: refusing non-store path: '$toplevel'" >&2; exit 1 ;;
    esac

    # Realise from the binary cache if not already present. For a not-yet-local
    # path this forces substitution, which the nix daemon accepts ONLY if the
    # narinfo is signed by a trusted key (doc1's cache key). Unsigned or
    # unbuildable ⇒ this fails and nothing is activated — so a leaked deploy key
    # can only ever activate closures doc1 signed into the cache.
    if [ ! -e "$toplevel" ]; then
      echo "push-activate: realising $toplevel from cache…"
      nix-store --realise "$toplevel" >/dev/null
    fi

    if [ ! -x "$toplevel/bin/switch-to-configuration" ]; then
      echo "push-activate: no switch-to-configuration at $toplevel" >&2
      exit 1
    fi

    # Register as the current system generation (so it becomes the boot default)
    # then activate — exactly what `nixos-rebuild switch` does under the hood.
    echo "push-activate: registering + switching to $toplevel"
    nix-env -p /nix/var/nix/profiles/system --set "$toplevel"
    exec "$toplevel/bin/switch-to-configuration" switch
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

    # The doc1 deploy key, locked to run ONLY the activation wrapper as root.
    # Reuses the fleet-deploy trigger key (already lives ONLY on doc1, sops-scoped);
    # it is authorized on a DIFFERENT login user here (root vs abl030 for
    # fleet-deploy), so sshd selects this entry by login user. `restrict` strips
    # pty/forwarding/agent/X11; `from=` pins the source to tailnet + home LAN.
    users.users.root.openssh.authorizedKeys.keys = [
      ''command="${activateScript}",restrict,from="${fleetCfg.triggerFrom}" ${fleetCfg.triggerPublicKey}''
    ];
  };
}
