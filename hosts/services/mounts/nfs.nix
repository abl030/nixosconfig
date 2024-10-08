# Ok this is a long one, where to start.
# I had significant trouble getting this to work, if you get errors try a reboot
# This mounts via tailscale. I now have access controls so that no one can see nfs shares unless they are on tailscale.
# Here's the uraid NFS rules: 
# 100.70.190.0/24(rw,sync,no_subtree_check,anonuid=99,anongid=100,all_squash) 192.168.1.0/24(sec=sys,root_squash,noaccess) 
# The id stuff squashes all requests to nobody/users which is default unraid and just leads to less headaches.

{
  fileSystems."/mnt/data" = {
    device = "tower:/mnt/user/data/";
    fsType = "nfs";
    options = [
      # We need this bit so that the mount works on tailscale. 
      # Otherwise it will load at boot and tailscale isn't up yet.
      # Automatically mount when accessed.
      "x-systemd.automount"

      # Do not mount at boot, only when needed.
      "noauto"

      # Unmount after 300 seconds of inactivity.
      "x-systemd.idle-timeout=300"

      # Do not update file access times (improves performance).
      "noatime"

      # Use NFS version 4.2.
      "nfsvers=4.2"
    ];

  };
}
