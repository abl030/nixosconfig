# Disk layout for the servarr VM (Unraid KVM guest, virtio disk = /dev/vda).
# Consumed by disko at install time — nixos-anywhere partitions + formats from
# this, and the fileSystems are generated from it (none in hardware-configuration.nix).
{...}: {
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          type = "EF00";
          size = "512M";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = ["umask=0077"];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
