# Mum's Synology NFS mount over Tailscale.
#
# /mnt/mum is the kopia repository destination for the kopia-mum instance
# (offsite backup of /mnt/data). Both consumers — doc1's local browsable
# access (homelab.mounts.mumNfs.enable) and doc2's kopia-mum instance
# (which sets the same option via mkIf needsMumMount) — share this
# single definition. See docs/wiki/infrastructure/nfs-over-tailscale.md
# for the readiness-gate design.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.mumNfs;
in {
  options.homelab.mounts.mumNfs = {
    enable = mkEnableOption "Mum's Synology NFS mount over Tailscale (/mnt/mum)";
  };

  config = mkIf cfg.enable {
    # The fstab options reference tailscale-wait.service by name, which is
    # opaque to Nix's type system. Catch the missing-dep case at eval time
    # instead of as a deploy-time systemd unit-not-found error.
    assertions = [
      {
        assertion = config.homelab.tailscale.enable;
        message = "homelab.mounts.mumNfs requires homelab.tailscale.enable = true (the /mnt/mum fstab options depend on tailscale-wait.service).";
      }
    ];

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    # See docs/wiki/infrastructure/nfs-over-tailscale.md — `tailscale-wait`
    # is the real readiness gate. The 30s mount-timeout makes a genuine
    # outage page us fast instead of stalling 90s. `nofail` removes the
    # mount from `remote-fs.target`'s required set (so boot/activation
    # doesn't *wait* for it) but does NOT prevent activation from failing
    # if the mount itself ends in `failed` state — switch-to-configuration-ng
    # scans unit states regardless of `nofail`. Intentional: a genuine
    # outage of mum's Synology should page us.
    fileSystems."/mnt/mum" = {
      # Tailscale MagicDNS name (matches the `tower` pattern in nfs.nix).
      # If kerrynas is ever re-enrolled in Tailscale, the name still
      # resolves; a hardcoded 100.x IP would silently break the mount.
      device = "kerrynas:/volumeUSB1/usbshare";
      fsType = "nfs";
      options = [
        "x-systemd.automount"
        "noauto"
        "nofail"
        "_netdev"
        "x-systemd.requires=tailscale-wait.service"
        "x-systemd.after=tailscale-wait.service"
        "x-systemd.mount-timeout=30s"
        "x-systemd.idle-timeout=300"
        "noatime"
      ];
    };
  };
}
