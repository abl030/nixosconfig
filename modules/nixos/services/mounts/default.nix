# modules/nixos/services/mounts/default.nix
{...}: {
  imports = [
    ./nfs.nix
    ./nfs-local.nix
    ./external.nix
    ./fuse.nix
    ./drvfs.nix
  ];
}
