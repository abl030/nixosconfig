# Cloud-init Configuration for VM Provisioning
# =============================================
#
# Generates cloud-init configuration for new VMs.
# Provides SSH key management and initial VM bootstrapping.
{lib, ...}:
with lib; rec {
  # Load fleet SSH keys from hosts.nix
  # These are the master keys that can access all VMs
  getFleetSSHKeys = hostsConfig: let
    # Extract masterKeys from a host that has authorizedKeys
    # (all hosts should have the same masterKeys)
    firstHost = head (attrValues hostsConfig);
    masterKeys = firstHost.authorizedKeys or [];
  in
    masterKeys;

  # Format SSH keys for Proxmox cloud-init
  # Proxmox expects newline-separated keys or URL-encoded format
  formatSSHKeysForProxmox = keys:
    concatStringsSep "\\n" keys;

  # Generate cloud-init user-data configuration
  # Returns: YAML string
  generateUserData = {
    hostname ? "nixos",
    sshKeys ? [],
    timezone ? "UTC",
    packages ? [],
  }: ''
    #cloud-config
    hostname: ${hostname}
    fqdn: ${hostname}.local
    manage_etc_hosts: true

    # Timezone
    timezone: ${timezone}

    # Users
    users:
      - name: root
        ssh_authorized_keys:
    ${concatMapStrings (key: "      - ${key}\n") sshKeys}

    # Disable password authentication
    ssh_pwauth: false
    disable_root: false

    # Packages to install
    ${optionalString (packages != []) ''
      packages:
      ${concatMapStrings (pkg: "  - ${pkg}\n") packages}
    ''}

    # Run commands on first boot
    runcmd:
      - echo "Cloud-init bootstrap complete"
      - systemctl restart sshd

    # Configure SSH
    ssh:
      emit_keys_to_console: false
  '';

  # Generate cloud-init network configuration
  # Returns: YAML string (version 2 format)
  generateNetworkConfig = {
    interface ? "ens18",
    dhcp ? true,
    address ? null,
    gateway ? null,
    nameservers ? ["1.1.1.1" "8.8.8.8"],
  }: ''
    version: 2
    ethernets:
      ${interface}:
        ${
      if dhcp
      then "dhcp4: true"
      else ''
            addresses:
              - ${address}
            gateway4: ${gateway}
            nameservers:
              addresses:
        ${concatMapStrings (ns: "        - ${ns}\n") nameservers}
      ''
    }
  '';

  # Generate complete cloud-init configuration for a VM
  # Returns: attrset with user-data and network-config
  generateCloudInitConfig = {
    vmName,
    hostsConfig,
    hostname ? vmName,
    timezone ? "Australia/Melbourne",
    dhcp ? true,
    interface ? "ens18",
    packages ? ["qemu-guest-agent"],
  }: let
    fleetKeys = getFleetSSHKeys hostsConfig;
  in {
    user-data = generateUserData {
      inherit hostname timezone packages;
      sshKeys = fleetKeys;
    };

    network-config = generateNetworkConfig {
      inherit interface dhcp;
    };

    # Formatted for direct use with proxmox-ops.sh
    sshKeysFormatted = formatSSHKeysForProxmox fleetKeys;
  };

  # Create a script to configure cloud-init on a VM
  # Returns: bash script
  makeCloudInitConfigScript = pkgs: vmid: config:
    pkgs.writeShellScript "configure-cloudinit-${toString vmid}" ''
      set -euo pipefail

      VMID="${toString vmid}"
      SSH_KEYS="${config.sshKeysFormatted}"
      HOSTNAME="${config.hostname or "nixos"}"

      echo "Configuring cloud-init for VMID $VMID..."

      # Create cloud-init drive if it doesn't exist
      ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@192.168.1.12 \
        "qm set $VMID --ide2 nvmeprom:cloudinit" 2>/dev/null || true

      # Configure cloud-init settings
      ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@192.168.1.12 \
        "qm set $VMID --ciuser root --cipassword '!' --searchdomain local --nameserver 192.168.1.1"

      # Set SSH keys (URL-encoded format)
      echo "$SSH_KEYS" | ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@192.168.1.12 \
        "xargs -I {} qm set $VMID --sshkeys {}"

      # Enable DHCP
      ${pkgs.openssh}/bin/ssh -o StrictHostKeyChecking=no root@192.168.1.12 \
        "qm set $VMID --ipconfig0 ip=dhcp"

      echo "Cloud-init configuration complete for VMID $VMID"
    '';

  # Helper: Write cloud-init files to disk for inspection/debugging
  # Returns: derivation with user-data and network-config files
  writeCloudInitFiles = pkgs: vmName: config:
    pkgs.runCommand "cloudinit-${vmName}" {} ''
      mkdir -p $out
      cat > $out/user-data <<'EOF'
      ${config.user-data}
      EOF

      cat > $out/network-config <<'EOF'
      ${config.network-config}
      EOF

      cat > $out/ssh-keys.txt <<'EOF'
      ${config.sshKeysFormatted}
      EOF

      echo "Cloud-init files written to $out"
    '';

  # Validate cloud-init configuration
  # Returns: list of error messages (empty if valid)
  validateCloudInitConfig = config: let
    errors =
      (optional (!(config ? user-data)) "Missing user-data")
      ++ (optional (!(config ? network-config)) "Missing network-config")
      ++ (optional (!(config ? sshKeysFormatted)) "Missing SSH keys");
  in
    errors;
}
