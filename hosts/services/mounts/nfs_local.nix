# Resilient static NFS mounts for a local server.
# Version with explicit network-online dependency.
{ pkgs, ... }:
{
  # Ensure networking services are configured to wait for an active connection
  # before declaring the network to be "online". This makes network-online.target reliable.
  systemd.services.systemd-networkd-wait-online.enable = true;

  # Required for NFS client functionality.
  environment.systemPackages = with pkgs; [ nfs-utils ];

  # Ensures the kernel has NFS support during the boot process.
  boot.initrd = {
    supportedFilesystems = [ "nfs" ];
    kernelModules = [ "nfs" ];
  };

  fileSystems."/mnt/data" = {
    device = "192.168.1.2:/mnt/user/data/";
    fsType = "nfs";
    options = [
      # Ensures this mount is attempted only after the network is fully operational.
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
      # A fallback dependency, good practice to keep.
      "_netdev"
      # 'hard' option makes the client retry requests indefinitely if the server is down.
      "hard"
      # 'bg' allows the system to boot even if the NFS server is initially unavailable.
      "bg"
      # Do not update file access times (improves performance).
      "noatime"
      # Use NFS version 4.2.
      "nfsvers=4.2"
    ];
  };

  fileSystems."/mnt/appdata" = {
    # It's generally more resilient to use the IP address for local mounts
    # to avoid dependencies on DNS resolution during boot.
    device = "192.168.1.2:/mnt/user/appdata/";
    fsType = "nfs";
    options = [
      # Ensures this mount is attempted only after the network is fully operational.
      "x-systemd.requires=network-online.target"
      "x-systemd.after=network-online.target"
      # A fallback dependency, good practice to keep.
      "_netdev"
      "hard"
      "bg"
      "noatime"
      "nfsvers=4.2"
    ];
  };
}
