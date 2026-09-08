# Single virtio root disk: ESP + ext4 root, UEFI/systemd-boot.
#
# Deliberately NOT doc2's BIOS/GRUB layout. Two reasons, both provisioning:
#
#  1. `system.build.diskoImages` — the path docs/wiki/infrastructure/vm-provisioning.md
#     describes — no longer evaluates against this nixpkgs pin (nixpkgs' vmTools
#     split its `kernel`/`kernelModules` arguments and disko still passes a
#     module tree as `kernel`). doc2 fails the same way, so this host is
#     installed offline on doc1 instead: loop-mount the image, `nixos-install`.
#     Installing systemd-boot offline is a file copy into the ESP; installing
#     GRUB offline needs a real block device for `grub-install` to embed
#     core.img into, which a loop device inside a build host is awkward about.
#
#  2. OVMF + q35 is exactly what the apollo-* gaming VMs use for this same GTX
#     1080, so the passthrough path is the known-good one.
#
# The image is built small (imageSize below) and grown to the real disk size on
# first boot by `boot.growPartition` — see configuration.nix. Root is the last
# partition, which is what growpart requires.
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/vda";
        # Build-time image size only. Keep it small so the image build and the
        # copy to prom stay quick; the disk is resized on import and the
        # filesystem catches up at boot.
        imageSize = "24G";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
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
    };
  };
}
