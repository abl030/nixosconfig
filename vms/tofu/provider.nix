# Proxmox provider configuration for OpenTofu
# API token is read from PROXMOX_VE_API_TOKEN environment variable
{proxmoxConfig, ...}: {
  terraform = {
    required_version = ">= 1.6.0";

    required_providers = {
      proxmox = {
        source = "bpg/proxmox";
        version = "~> 0.93.0";
      };
    };
  };

  provider.proxmox = {
    endpoint = "https://${proxmoxConfig.host}:8006/";
    # Authentication via environment variables:
    # PROXMOX_VE_API_TOKEN - format: "user@realm!tokenid=secret"
    # Or: PROXMOX_VE_USERNAME + PROXMOX_VE_PASSWORD
    insecure = true; # Self-signed cert on Proxmox
  };
}
