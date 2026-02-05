{
  lib,
  config,
  ...
}: let
  cfg = config.homelab.mdnsReflector;
in {
  options.homelab.mdnsReflector = {
    enable = lib.mkEnableOption "mDNS reflector between LAN and Tailscale";

    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "LAN interfaces to reflect mDNS on (tailscale0 is added automatically).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.interfaces != [];
        message = "homelab.mdnsReflector.interfaces must specify at least one LAN interface.";
      }
    ];

    services.avahi = {
      enable = true;
      reflector = true;
      allowPointToPoint = true;
      allowInterfaces = cfg.interfaces ++ ["tailscale0"];
      ipv4 = true;
      ipv6 = false;
      openFirewall = true;
      publish = {
        enable = true;
        addresses = true;
      };
    };
  };
}
