# modules/nixos/services/mounts/default.nix
{...}: {
  imports = [
    ./nfs.nix
    ./nfs-local.nix
    ./magazines-nfs.nix
    ./mum-nfs.nix
    ./fuse.nix
    ./drvfs.nix
    ./ops-sync.nix
    ./nfs-music.nix
  ];
}
