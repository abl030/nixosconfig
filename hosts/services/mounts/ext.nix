{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [ nfs-utils ];
  boot.initrd = {
    supportedFilesystems = [ "nfs" ];
    kernelModules = [ "nfs" ];
  };

  fileSystems."/mnt/mum" = {
    device = "100.100.237.21:/volumeUSB1/usbshare";
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
      "x-systemd.after=tailscaled.service"
      # Unmount after 300 seconds of inactivity
      "x-systemd.idle-timeout=300"
      # Do not update file access times (improves performance)
      "noatime"

      "retry=10"
      # Use NFS version 4.2
      # "nfsvers=4.2"
    ];
  };
}
