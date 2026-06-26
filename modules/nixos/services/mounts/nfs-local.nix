# Resilient STATIC NFS mounts for the local network (the tower data/appdata exports).
# Uses network-online.target instead of Tailscale.
#
# This is the SERVER mount pattern (doc2, servarr): a static mount that is NEVER an
# x-systemd.automount. Automount lazily unmounts/remounts the fs underneath whatever
# holds it open — and that strands cached handles (e.g. a virtiofsd re-share) as
# ESTALE ("Stale file handle"). A server must stay mounted. The roaming/laptop
# pattern (x-systemd.automount + idle-timeout, which WANTS to drop the mount when the
# network goes away) lives in the sibling nfs.nix and is used by framework/epi.
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.nfsLocal;
  # hard      → I/O blocks-and-resumes across a tower blip instead of erroring.
  # softreval → serve cached attrs during a brief revalidation outage (no hard fail).
  # static    → no x-systemd.automount: the mount comes up once at boot (after
  #             network-online) and stays, so nothing it backs (virtiofsd) goes stale.
  baseOpts = [
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
    "_netdev"
    "hard"
    "softreval"
    "timeo=50"
    "retrans=5"
    "noatime"
    "nfsvers=4.2"
  ];
in {
  options.homelab.mounts.nfsLocal = {
    enable = mkEnableOption "NFS mounts via local network to Unraid";
    readOnly = mkEnableOption "mount the data export read-only (safety for testing)";

    mountPoint = mkOption {
      type = types.str;
      default = "/mnt/data";
      description = ''
        Local mountpoint for the tower data export (192.168.1.2:/mnt/user/data).
        Defaults to the fleet-standard /mnt/data. servarr overrides this to
        /media/data — the path the legacy Downloader2 box used, which the *arr
        config, the qbt virtiofs share, and the hardlink layout all bake in.
      '';
    };

    appdata = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Also mount the tower appdata export at /mnt/appdata. Disable on hosts
        whose only NFS consumer is the media library (e.g. servarr).
      '';
    };

    networkdWaitOnline = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable systemd-networkd-wait-online so network-online.target (which the
        mount waits on) is actually reached. Correct for networkd-primary hosts
        (doc2). Set false where NetworkManager owns connectivity and provides
        network-online via NetworkManager-wait-online (e.g. servarr, whose
        networkd manages only the IP-less qbt DMZ cage that never reaches
        "online" — forcing networkd-wait-online there just times out → degraded).
      '';
    };
  };

  config = mkIf cfg.enable {
    systemd.services.systemd-networkd-wait-online.enable = mkIf cfg.networkdWaitOnline true;

    environment.systemPackages = lib.mkOrder 1600 (with pkgs; [nfs-utils]);

    boot.initrd = {
      supportedFilesystems = lib.mkOrder 1600 ["nfs"];
      kernelModules = lib.mkOrder 1600 ["nfs"];
    };

    fileSystems.${cfg.mountPoint} = {
      device = "192.168.1.2:/mnt/user/data/";
      fsType = "nfs";
      options = baseOpts ++ lib.optional cfg.readOnly "ro";
    };

    fileSystems."/mnt/appdata" = mkIf cfg.appdata {
      device = "192.168.1.2:/mnt/user/appdata/";
      fsType = "nfs";
      options = baseOpts;
    };
  };
}
