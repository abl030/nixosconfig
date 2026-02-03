{
  lib,
  config,
  pkgs,
  hostConfig,
  ...
}: let
  cfg = config.homelab.mcp;
  secretsDir = "/run/secrets/mcp";
in {
  options.homelab.mcp = {
    enable = lib.mkEnableOption "MCP server secrets provisioning";

    user = lib.mkOption {
      type = lib.types.str;
      default = hostConfig.user;
      description = "User that should be able to read the MCP secrets.";
    };

    pfsense = {
      enable = lib.mkEnableOption "pfSense MCP server secrets";
      sopsFile = lib.mkOption {
        type = lib.types.path;
        default = config.homelab.secrets.sopsFile "pfsense-mcp.env";
        description = "Sops file containing pfSense MCP credentials.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${secretsDir}/pfsense.env";
        description = "Path to decrypted pfSense MCP env file.";
      };
    };

    unifi = {
      enable = lib.mkEnableOption "UniFi MCP server secrets";
      sopsFile = lib.mkOption {
        type = lib.types.path;
        default = config.homelab.secrets.sopsFile "unifi-mcp.env";
        description = "Sops file containing UniFi MCP credentials.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "${secretsDir}/unifi.env";
        description = "Path to decrypted UniFi MCP env file.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Decrypt MCP env files during activation using sops directly
    # This handles dotenv format properly, outputting clean KEY=VALUE pairs
    system.activationScripts.mcp-secrets = let
      sops = "${pkgs.sops}/bin/sops";
      sshToAge = "${pkgs.ssh-to-age}/bin/ssh-to-age";
      inherit (cfg) user;
      pfsenseFile = cfg.pfsense.sopsFile;
      unifiFile = cfg.unifi.sopsFile;
    in
      lib.stringAfter ["setupSecrets"] ''
        echo "Decrypting MCP secrets..."
        mkdir -p ${secretsDir}
        chmod 755 ${secretsDir}

        # Get age key from host SSH key (same method as sops-nix)
        SOPS_AGE_KEY=$(${sshToAge} -private-key -i /etc/ssh/ssh_host_ed25519_key)
        export SOPS_AGE_KEY

        ${lib.optionalString cfg.pfsense.enable ''
          ${sops} -d --output-type dotenv ${pfsenseFile} | grep -v '^#' > ${cfg.pfsense.path}
          chmod 400 ${cfg.pfsense.path}
          chown ${user}:users ${cfg.pfsense.path}
        ''}

        ${lib.optionalString cfg.unifi.enable ''
          ${sops} -d --output-type dotenv ${unifiFile} | grep -v '^#' > ${cfg.unifi.path}
          chmod 400 ${cfg.unifi.path}
          chown ${user}:users ${cfg.unifi.path}
        ''}
      '';

    # Export paths as environment variables for convenience
    environment.sessionVariables = lib.mkMerge [
      (lib.mkIf cfg.pfsense.enable {
        PFSENSE_MCP_ENV_FILE = cfg.pfsense.path;
      })
      (lib.mkIf cfg.unifi.enable {
        UNIFI_MCP_ENV_FILE = cfg.unifi.path;
      })
    ];
  };
}
