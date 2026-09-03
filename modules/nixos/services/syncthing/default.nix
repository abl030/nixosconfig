{
  lib,
  config,
  allHosts,
  hostname,
  hostConfig,
  ...
}: let
  cfg = config.homelab.syncthing;
  hasFleetIdentity = (hostConfig ? syncthingDeviceId) && hostConfig.syncthingDeviceId != "";
  fleetMeshEnabled = hasFleetIdentity && !cfg.isolated;

  # All hosts with a syncthingDeviceId (excluding ourselves)
  syncthingPeers =
    lib.filterAttrs (
      name: host:
        name != hostname && (host ? syncthingDeviceId) && host.syncthingDeviceId != ""
    )
    allHosts;

  fleetDevices = lib.optionalAttrs fleetMeshEnabled (
    lib.mapAttrs (
      name: host: {
        id = host.syncthingDeviceId;
        inherit name;
      }
    )
    syncthingPeers
  );

  devices = fleetDevices // cfg.extraDevices;
  peerNames = lib.attrNames fleetDevices;
  folders =
    lib.optionalAttrs fleetMeshEnabled {
      episodic-memory = {
        path = "${hostConfig.homeDirectory}/.config/superpowers/conversation-archive";
        devices = peerNames;
        id = "episodic-memory";
      };
    }
    // cfg.extraFolders;
in {
  options.homelab.syncthing = {
    enable = lib.mkEnableOption "declarative Syncthing";
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.homeDirectory;
      description = "Base data directory for Syncthing.";
    };
    guiAddress = lib.mkOption {
      type = lib.types.str;
      # BIND-ALL-INTERFACES-OK: the GUI is scoped to the tailnet by the
      # interface-specific firewall rule below (tailscale0 allowedTCPPorts only,
      # NOT the LAN); the bind is 0.0.0.0 because the tailscale IP is per-host
      # dynamic. This is the "broad bind, narrow firewall" pattern, not an
      # unscoped exposure.
      default = "0.0.0.0:8384";
      description = "Address and port for the Syncthing GUI.";
    };
    isolated = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run without inheriting the fleet devices or episodic-memory folder.";
    };
    openDefaultPorts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open Syncthing transfer and discovery ports on every firewall interface.";
    };
    openTailscaleDataPort = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open only TCP 22000 on tailscale0 for direct synchronization.";
    };
    openTailscaleGui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the Syncthing GUI port on tailscale0.";
    };
    requiredMountsFor = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Mount points which must exist before Syncthing starts.";
    };
    extraDevices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = "Additional declarative Syncthing devices.";
    };
    extraFolders = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = {};
      description = "Additional declarative Syncthing folders.";
    };
    options = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Additional Syncthing options in REST API JSON form.";
    };
  };

  config = lib.mkIf (cfg.enable && (hasFleetIdentity || cfg.isolated)) {
    assertions = [
      {
        assertion = !cfg.openTailscaleDataPort || !cfg.openDefaultPorts;
        message = "homelab.syncthing: a Tailscale-only listener must not also open default ports globally";
      }
      {
        assertion = lib.all (folder: folder ? path && folder ? devices) (lib.attrValues cfg.extraFolders);
        message = "homelab.syncthing.extraFolders entries must define path and devices";
      }
      {
        assertion =
          lib.all
          (folder: lib.all (device: builtins.hasAttr device devices) folder.devices)
          (lib.attrValues cfg.extraFolders);
        message = "homelab.syncthing.extraFolders may reference only configured devices";
      }
    ];

    services.syncthing = {
      enable = true;
      inherit (hostConfig) user;
      group = "users";
      inherit (cfg) dataDir openDefaultPorts;
      overrideDevices = true;
      overrideFolders = true;
      inherit (cfg) guiAddress;
      cert = config.sops.secrets.syncthing-cert.path;
      key = config.sops.secrets.syncthing-key.path;

      settings = {
        inherit devices folders;
        inherit (cfg) options;
      };
    };

    # Requisite fails immediately when activation starts both units together
    # after a package upgrade. Requires plus the existing After ordering waits
    # for Syncthing instead, avoiding a switch-to-configuration failure.
    systemd.services.syncthing-init = {
      requisite = lib.mkForce [];
      requires = ["syncthing.service"];
    };

    # Never let a shared-storage folder fall through to the underlying root
    # filesystem when its real mount is unavailable.
    systemd.services.syncthing.unitConfig.RequiresMountsFor = cfg.requiredMountsFor;

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

    # The GUI and optional direct data listener are reachable via Tailscale only.
    networking.firewall.interfaces.tailscale0.allowedTCPPorts =
      lib.optional cfg.openTailscaleGui 8384
      ++ lib.optional cfg.openTailscaleDataPort 22000;
  };
}
