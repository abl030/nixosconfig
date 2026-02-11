{
  lib,
  config,
  allHosts,
  hostname,
  hostConfig,
  ...
}: let
  cfg = config.homelab.syncthing;

  # All hosts with a syncthingDeviceId (excluding ourselves)
  syncthingPeers =
    lib.filterAttrs (
      name: host:
        name != hostname && (host ? syncthingDeviceId) && host.syncthingDeviceId != ""
    )
    allHosts;

  # Build device attrset for Syncthing settings
  devices =
    lib.mapAttrs (
      name: host: {
        id = host.syncthingDeviceId;
        inherit name;
      }
    )
    syncthingPeers;

  peerNames = lib.attrNames syncthingPeers;
in {
  options.homelab.syncthing = {
    enable = lib.mkEnableOption "Declarative Syncthing for episodic memory sync";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.homeDirectory;
      description = "Base data directory for Syncthing.";
    };
    guiAddress = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:8384";
      description = "Address and port for the Syncthing GUI.";
    };
  };

  config = lib.mkIf (cfg.enable && (hostConfig ? syncthingDeviceId)) {
    services.syncthing = {
      enable = true;
      inherit (hostConfig) user;
      group = "users";
      inherit (cfg) dataDir;
      openDefaultPorts = true;
      overrideDevices = true;
      overrideFolders = true;
      inherit (cfg) guiAddress;
      cert = config.sops.secrets.syncthing-cert.path;
      key = config.sops.secrets.syncthing-key.path;

      settings = {
        inherit devices;
        folders."episodic-memory" = {
          path = "${hostConfig.homeDirectory}/.claude/episodic-memory";
          devices = peerNames;
          id = "episodic-memory";
        };
      };
    };

    # SOPS secrets for Syncthing keys
    sops.secrets.syncthing-cert = {
      sopsFile = config.homelab.secrets.sopsFile "syncthing-cert.pem";
      format = "binary";
      owner = hostConfig.user;
    };
    sops.secrets.syncthing-key = {
      sopsFile = config.homelab.secrets.sopsFile "syncthing-key.pem";
      format = "binary";
      owner = hostConfig.user;
    };

    # GUI accessible via Tailscale only
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [8384];
  };
}
