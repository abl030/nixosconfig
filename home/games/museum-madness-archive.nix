# Shared by the launcher and doc1's GC root (hosts/proxmox-vm/configuration.nix).
# The fixed-output path depends only on name + hash, so every nixpkgs revision
# resolves to the same store path.
pkgs:
pkgs.fetchurl {
  url = "https://archive.org/download/msdos_Museum_Madness_1994/Museum_Madness_1994.zip";
  sha256 = "bdad42a10375bd38df5e8c4eb5f0d082e6e5bd86fefb8a9c73d9b07220e23fcb";
}
