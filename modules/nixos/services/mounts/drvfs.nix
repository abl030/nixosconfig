# Windows drvfs mounts for WSL
# Mounts mapped Windows network drives into WSL
{
  config,
  lib,
  ...
}:
with lib; let
  cfg = config.homelab.mounts.drvfs;
in {
  options.homelab.mounts.drvfs = {
    enable = mkEnableOption "Windows drvfs mounts in WSL";

    drives = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          mountPoint = mkOption {
            type = types.str;
            description = "Where to mount the drive in the filesystem";
          };
          label = mkOption {
            type = types.str;
            description = "Windows drive letter with colon (e.g. \"Z:\")";
          };
        };
      });
      default = {};
      description = "Set of Windows drives to mount via drvfs";
    };
  };

  config = mkIf cfg.enable {
    fileSystems = mapAttrs' (_: drive:
      nameValuePair drive.mountPoint {
        device = drive.label;
        fsType = "drvfs";
        options = [
          "x-systemd.automount"
          "noauto"
          "x-systemd.idle-timeout=300"
          "ro"
          "metadata"
          "uid=1000"
          "gid=100"
        ];
      })
    cfg.drives;
  };
}
