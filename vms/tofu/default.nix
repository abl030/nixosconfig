# Terranix configuration for Proxmox VM management
# Reads from hosts.nix as the single source of truth
{lib, ...}: let
  hosts = import ../../hosts.nix;
  proxmoxConfig = hosts._proxmox or {};

  # Filter to hosts with proxmox attribute that are NOT readonly
  proxmoxHosts =
    lib.filterAttrs
    (_: host: host ? proxmox && !(host.proxmox.readonly or false))
    (lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts);

  # All proxmox hosts (including readonly) for reference
  allProxmoxHosts =
    lib.filterAttrs
    (_: host: host ? proxmox)
    (lib.filterAttrs (name: _: !lib.hasPrefix "_" name) hosts);
in {
  imports = [
    ./provider.nix
    ./vm-resources.nix
  ];

  # Pass data to other modules
  _module.args = {
    inherit hosts proxmoxConfig proxmoxHosts allProxmoxHosts;
  };
}
