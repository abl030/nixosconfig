{ pkgs, ... }:
{
  # For mount.cifs, required unless domain name resolution is not needed.
  # environment.systemPackages = [ pkgs.cifs-utils ];
  fileSystems."/mnt/data" = {
    device = "//192.168.1.2/data";
    fsType = "cifs";
    options =
      let
        # this line prevents hanging on network split
        automount_opts = "x-systemd.automount,noauto,x-systemd.idle-timeout=60,x-systemd.device-timeout=5s,x-systemd.mount-timeout=5s";

      in
      [ "${automount_opts},credentials=/home/abl030/smb-secrets,uid=1000,gid=users,noperm" ];
  };
}
