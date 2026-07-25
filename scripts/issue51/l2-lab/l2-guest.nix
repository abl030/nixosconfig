# nixosconfig#51 E4: the L2 nested seam, built to mirror doc2 -> slskd exactly.
#   prom ZFS -> virtiofsd(prefer) -> VM951 /mnt/virtiofs   [= doc2 /mnt/virtio]
#     -> virtiofsd(never) -> this microVM                  [= slskd guest]
{repo ? /home/abl030/nixosconfig/.claude/worktrees/issue51-nested-virtiofs-repro}: let
  flake = builtins.getFlake (toString repo);
  inherit (flake) inputs;
  system = "x86_64-linux";
  pkgs = inputs.nixpkgs.legacyPackages.${system};

  # Byte-for-byte the same wrapper doc2 uses (hosts/doc2/slskd-microvm.nix):
  # force --inode-file-handles=never, which is what makes virtiofsd pin one
  # O_PATH descriptor per inode into the outer FUSE mount.
  virtiofsdNestedSafe = pkgs.writeShellScriptBin "virtiofsd" ''
    args=()
    for arg in "$@"; do
      case "$arg" in
        --inode-file-handles=prefer) args+=(--inode-file-handles=never) ;;
        --posix-acl | --xattr) ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${pkgs.lib.getExe pkgs.virtiofsd} "''${args[@]}"
  '';
in
  (inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      inputs.microvm.nixosModules.microvm
      {
        networking.hostName = "l2guest";
        system.stateVersion = "26.05";
        users.users.root.password = "";
        services.getty.autologinUser = "root";
        boot.kernelParams = ["console=ttyS0,115200"];

        # Everything the harness observes goes to the console, which VM951
        # captures, so results survive the filesystem under test failing.
        systemd.services.l2-harness = {
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            Type = "simple";
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecStart = "${pkgs.python3}/bin/python3 ${./l2-harness.py}";
          };
        };

        microvm = {
          hypervisor = "cloud-hypervisor"; # same hypervisor as the slskd guest
          vcpu = 2;
          mem = 2048;
          virtiofsd.package = virtiofsdNestedSafe;
          shares = [
            {
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              tag = "ro-store";
              proto = "virtiofs";
            }
            {
              # The scratch tree lives on VM951's virtiofs mount, so this share
              # is a virtiofsd re-export of a FUSE mount: the production seam.
              source = "/mnt/virtiofs/l2-scratch";
              mountPoint = "/data";
              tag = "l2data";
              proto = "virtiofs";
            }
          ];
        };
      }
    ];
  })
  .config
  .microvm
  .declaredRunner
