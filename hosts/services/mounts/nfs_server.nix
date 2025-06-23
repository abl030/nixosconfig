# Exactly the same as nfs.nix, but we remove the noauto. Docker relies on this mount at boot.
{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ nfs-utils ];
  boot.initrd = {
    supportedFilesystems = [ "nfs" ];
    kernelModules = [ "nfs" ];
  };

  fileSystems."/mnt/data" = {
    device = "tower:/mnt/user/data/";
    fsType = "nfs";
    options = [
      # We need this bit so that the mount works on tailscale. 
      # Otherwise it will load at boot and tailscale isn't up yet.
      # Automount when accessed
      "x-systemd.automount"
      # Do not mount at boot, only when needed
      # "noauto"
      # Ensures the mount depends on Tailscale being up
      "_netdev"
      # Requires Tailscale service to be active before mounting
      "x-systemd.requires=tailscaled.service"
      # Unmount after 300 seconds of inactivity
      "x-systemd.idle-timeout=300"
      # Do not update file access times (improves performance)
      "noatime"
      # Use NFS version 4.2
      "nfsvers=4.2"
    ];
  };
  fileSystems."/mnt/appdata" = {
    device = "tower:/mnt/user/appdata/";
    fsType = "nfs";
    options = [
      # We need this bit so that the mount works on tailscale. 
      # Otherwise it will load at boot and tailscale isn't up yet.
      # Automount when accessed
      "x-systemd.automount"
      # Do not mount at boot, only when needed
      "noauto"
      # Ensures the mount depends on Tailscale being up
      "_netdev"
      # Requires Tailscale service to be active before mounting
      "x-systemd.requires=tailscaled.service"
      # Unmount after 300 seconds of inactivity
      "x-systemd.idle-timeout=300"
      # Do not update file access times (improves performance)
      "noatime"
      # Use NFS version 4.2
      "nfsvers=4.2"
    ];


  };
}
