{
  config,
  lib,
  ...
}: let
  cfg = config.homelab.services.scannerSamba;
in {
  options.homelab.services.scannerSamba = {
    enable = lib.mkEnableOption "LAN-only Samba drop share for the Brother scanner";

    path = lib.mkOption {
      type = lib.types.path;
      default = "/mnt/scans";
      description = "Host path exported as the Scans SMB share.";
    };
  };

  config = lib.mkIf cfg.enable {
    services.samba = {
      enable = true;
      openFirewall = false;
      nmbd.enable = true;
      settings = {
        global = {
          workgroup = "WORKGROUP";
          "server role" = "standalone server";
          "map to guest" = "Bad User";
          interfaces = "lo eth0";
          "bind interfaces only" = "yes";
        };

        Scans = {
          inherit (cfg) path;
          "valid users" = "abl030";
          "read only" = "no";
          browseable = "yes";
          "create mask" = "0775";
          "directory mask" = "2775";
        };
      };
    };

    # The scanner is pinned to the caddy LXC's LAN address. Keep SMB off
    # tailscale0 and expose only the standard Samba ports on eth0.
    networking.firewall.interfaces.eth0 = {
      allowedTCPPorts = [139 445];
      allowedUDPPorts = [137 138];
    };

    systemd.services.samba-smbd.unitConfig.RequiresMountsFor = [cfg.path];
  };
}
