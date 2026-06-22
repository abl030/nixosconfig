# Disk layout for the servarr VM (Unraid KVM guest, virtio disk = /dev/vda).
# Consumed by disko at install time — nixos-anywhere partitions + formats from
# this, and the fileSystems are generated from it (none in hardware-configuration.nix).
{...}: {
  disko.devices.disk.main = {
    type = "disk";
    # SATA disk on the tower KVM (q35) — confirmed /dev/sda at install (cdrom = sr0).
    device = "/dev/sda";
    # Size of the generated image for the diskoImages build (the bootable image we
    # copy onto the tower VM disk). nixos-anywhere installs ignore this and use the
    # real disk; only the image builder needs a fixed size.
    imageSize = "64G";
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
