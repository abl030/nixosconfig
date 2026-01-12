#!/usr/bin/env bash
# VM Provisioning Orchestration
# ==============================
#
# End-to-end VM provisioning: clone, configure, install NixOS, integrate with fleet.
#
# Usage: provision.sh <vm-name>
#
# This script orchestrates the complete VM provisioning workflow:
# 1. Load and validate VM definition from vms/definitions.nix
# 2. Clone from template and configure resources
# 3. Setup cloud-init with fleet SSH keys
# 4. Start VM and wait for network
# 5. Deploy NixOS via nixos-anywhere
# 6. Extract SSH host key and integrate with fleet
# 7. Update secrets and documentation
# 8. Commit all changes to git

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}==>${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*"
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Proxmox operations script
PROXMOX_OPS="$SCRIPT_DIR/proxmox-ops.sh"

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v nix >/dev/null 2>&1 || missing+=("nix")
    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v git >/dev/null 2>&1 || missing+=("git")

    if [[ ! -f "$PROXMOX_OPS" ]]; then
        log_error "proxmox-ops.sh not found at $PROXMOX_OPS"
        return 1
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi

    log_success "All prerequisites met"
}

# Load VM definition from Nix
load_vm_definition() {
    local vm_name="$1"

    log_info "Loading VM definition for '$vm_name'..."

    # Use Nix to extract VM definition
    local nix_expr="
        let
          lib = (import <nixpkgs> {}).lib;
          vmLib = import $SCRIPT_DIR/lib.nix { inherit lib; };
          defs = vmLib.loadDefinitions;
          vm = vmLib.getVM defs \"$vm_name\";
        in
          if vm == null then
            throw \"VM '$vm_name' not found in vms/definitions.nix\"
          else if vm._type == \"imported\" then
            throw \"VM '$vm_name' is marked as imported (readonly). Cannot provision imported VMs.\"
          else
            vm
    "

    if ! VM_DEF=$(nix eval --json --impure --expr "$nix_expr" 2>&1); then
        log_error "Failed to load VM definition:"
        echo "$VM_DEF" | grep -E "(error|throw)" >&2
        return 1
    fi

    log_success "VM definition loaded"
    echo "$VM_DEF"
}

# Validate VM configuration
validate_vm() {
    local vm_json="$1"
    local vm_name="$2"

    log_info "Validating VM configuration..."

    # Extract required fields
    VMID=$(echo "$vm_json" | jq -r '.vmid')
    CORES=$(echo "$vm_json" | jq -r '.cores')
    MEMORY=$(echo "$vm_json" | jq -r '.memory')
    DISK=$(echo "$vm_json" | jq -r '.disk')
    STORAGE=$(echo "$vm_json" | jq -r '.storage // "nvmeprom"')
    NIXOS_CONFIG=$(echo "$vm_json" | jq -r '.nixosConfig // .name')

    # Validate fields
    if [[ -z "$VMID" || "$VMID" == "null" ]]; then
        log_error "VMID not specified in definition"
        return 1
    fi

    # Check if VMID already exists
    if "$PROXMOX_OPS" status "$VMID" &>/dev/null; then
        log_error "VMID $VMID already exists on Proxmox"
        return 1
    fi

    # Check if NixOS configuration exists
    local nixos_config_dir="$REPO_ROOT/hosts/$NIXOS_CONFIG"
    if [[ ! -d "$nixos_config_dir" ]]; then
        log_error "NixOS configuration not found: $nixos_config_dir"
        log_error "Please create the host configuration first:"
        log_error "  mkdir -p $nixos_config_dir"
        log_error "  # Add configuration.nix and home.nix"
        return 1
    fi

    log_success "VM configuration valid"
    log_info "  VMID: $VMID"
    log_info "  Cores: $CORES"
    log_info "  Memory: ${MEMORY}MB"
    log_info "  Disk: $DISK"
    log_info "  Storage: $STORAGE"
    log_info "  NixOS Config: $NIXOS_CONFIG"
}

# Generate cloud-init configuration
generate_cloudinit() {
    local vm_name="$1"

    log_info "Generating cloud-init configuration..."

    local nix_expr="
        let
          pkgs = import <nixpkgs> {};
          lib = pkgs.lib;
          cloudinit = import $SCRIPT_DIR/cloudinit.nix { inherit lib pkgs; };
          hosts = import $REPO_ROOT/hosts.nix;
          config = cloudinit.generateCloudInitConfig {
            vmName = \"$vm_name\";
            hostsConfig = hosts;
            hostname = \"$vm_name\";
          };
        in
          config.sshKeysFormatted
    "

    if ! SSH_KEYS=$(nix eval --raw --impure --expr "$nix_expr" 2>&1); then
        log_error "Failed to generate cloud-init config:"
        echo "$SSH_KEYS" >&2
        return 1
    fi

    log_success "Cloud-init configuration generated"
    echo "$SSH_KEYS"
}

# Clone VM from template
clone_vm() {
    local vmid="$1"
    local vm_name="$2"
    local storage="$3"

    log_info "Cloning template (VMID 9001) to VMID $vmid..."

    if ! "$PROXMOX_OPS" clone 9001 "$vmid" "$vm_name" "$storage"; then
        log_error "Failed to clone template"
        return 1
    fi

    log_success "VM cloned successfully"
}

# Configure VM resources
configure_vm() {
    local vmid="$1"
    local cores="$2"
    local memory="$3"

    log_info "Configuring VM resources ($cores cores, ${memory}MB RAM)..."

    if ! "$PROXMOX_OPS" configure "$vmid" "$cores" "$memory"; then
        log_error "Failed to configure VM resources"
        return 1
    fi

    log_success "VM resources configured"
}

# Create and attach disk
create_vm_disk() {
    local vmid="$1"
    local disk="$2"
    local storage="$3"

    log_info "Creating disk ($disk)..."

    if ! "$PROXMOX_OPS" create-disk "$vmid" "$disk" "$storage"; then
        log_error "Failed to create disk"
        return 1
    fi

    log_success "Disk created and attached"
}

# Setup cloud-init
setup_cloudinit() {
    local vmid="$1"
    local ssh_keys="$2"
    local storage="$3"

    log_info "Setting up cloud-init..."

    # Create cloud-init drive
    if ! "$PROXMOX_OPS" cloudinit-drive "$vmid" "$storage"; then
        log_error "Failed to create cloud-init drive"
        return 1
    fi

    # Configure cloud-init with SSH keys
    if ! "$PROXMOX_OPS" cloudinit-config "$vmid" "$ssh_keys"; then
        log_error "Failed to configure cloud-init"
        return 1
    fi

    log_success "Cloud-init configured"
}

# Start VM and wait for network
start_and_wait() {
    local vmid="$1"

    log_info "Starting VM..."

    if ! "$PROXMOX_OPS" start "$vmid"; then
        log_error "Failed to start VM"
        return 1
    fi

    log_success "VM started"
    log_info "Waiting for VM to obtain IP address..."

    # Wait for IP (retry for up to 5 minutes)
    local max_attempts=60
    local attempt=0
    local vm_ip=""

    while [[ $attempt -lt $max_attempts ]]; do
        vm_ip=$("$PROXMOX_OPS" get-ip "$vmid" 2>/dev/null || echo "")

        if [[ -n "$vm_ip" && "$vm_ip" != "null" ]]; then
            log_success "VM IP address: $vm_ip"
            break
        fi

        attempt=$((attempt + 1))
        echo -n "."
        sleep 5
    done

    echo ""

    if [[ -z "$vm_ip" || "$vm_ip" == "null" ]]; then
        log_error "Timeout waiting for VM IP address"
        log_error "VM may not have QEMU guest agent installed"
        return 1
    fi

    # Wait for SSH to be ready
    log_info "Waiting for SSH to be ready..."
    if ! "$PROXMOX_OPS" wait-ssh "$vm_ip" 300; then
        log_error "SSH not ready after 5 minutes"
        return 1
    fi

    log_success "VM is accessible via SSH at $vm_ip"
    echo "$vm_ip"
}

# Main provisioning workflow
provision_vm() {
    local vm_name="$1"

    log_info "Starting VM provisioning for: $vm_name"
    echo ""

    # Load VM definition
    local vm_json
    if ! vm_json=$(load_vm_definition "$vm_name"); then
        return 1
    fi

    # Validate configuration
    if ! validate_vm "$vm_json" "$vm_name"; then
        return 1
    fi

    echo ""
    log_warning "Ready to provision VM '$vm_name' (VMID: $VMID)"
    log_warning "This will:"
    log_warning "  1. Clone template VM"
    log_warning "  2. Configure resources and networking"
    log_warning "  3. Start VM and wait for network"
    log_warning "  4. Install NixOS (will happen in next step - not automated yet)"
    echo ""

    read -p "Continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Cancelled by user"
        return 0
    fi

    echo ""

    # Generate cloud-init configuration
    local ssh_keys
    if ! ssh_keys=$(generate_cloudinit "$vm_name"); then
        return 1
    fi

    # Clone VM
    if ! clone_vm "$VMID" "$vm_name" "$STORAGE"; then
        return 1
    fi

    # Configure resources
    if ! configure_vm "$VMID" "$CORES" "$MEMORY"; then
        return 1
    fi

    # Create disk
    if ! create_vm_disk "$VMID" "$DISK" "$STORAGE"; then
        return 1
    fi

    # Setup cloud-init
    if ! setup_cloudinit "$VMID" "$ssh_keys" "$STORAGE"; then
        return 1
    fi

    # Start VM and wait for network
    local vm_ip
    if ! vm_ip=$(start_and_wait "$VMID"); then
        return 1
    fi

    echo ""
    log_success "VM provisioning complete!"
    echo ""
    log_info "Next steps:"
    log_info "  1. Install NixOS:"
    log_info "     nixos-anywhere --flake .#$NIXOS_CONFIG root@$vm_ip"
    log_info ""
    log_info "  2. After installation, run post-provisioning to:"
    log_info "     - Extract SSH host key"
    log_info "     - Update hosts.nix and secrets"
    log_info "     - Update documentation"
    log_info ""
    log_info "VM Details:"
    log_info "  VMID: $VMID"
    log_info "  IP: $vm_ip"
    log_info "  SSH: ssh root@$vm_ip"
}

# Main entry point
main() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <vm-name>"
        echo ""
        echo "Example:"
        echo "  $0 test-vm"
        echo ""
        echo "VM must be defined in vms/definitions.nix under 'managed' section"
        return 1
    fi

    local vm_name="$1"

    # Check prerequisites
    if ! check_prerequisites; then
        return 1
    fi

    # Change to repo root
    cd "$REPO_ROOT"

    # Provision VM
    provision_vm "$vm_name"
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
