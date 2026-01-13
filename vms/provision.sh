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

# Logging functions (use || true to prevent errors when stderr is closed)
log_info() {
    echo -e "${BLUE}==>${NC} $*" >&2 || true
}

log_success() {
    echo -e "${GREEN}✓${NC} $*" >&2 || true
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2 || true
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $*" >&2 || true
}

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find repository root (must be in nixosconfig git repo)
if git rev-parse --git-dir >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    # Fallback: assume we're one level down from repo root
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Proxmox operations command
# When running from Nix package, use command from PATH
# When running directly, use script from same directory
if command -v proxmox-ops >/dev/null 2>&1; then
    PROXMOX_OPS="proxmox-ops"
else
    PROXMOX_OPS="$SCRIPT_DIR/proxmox-ops.sh"
fi

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v nix >/dev/null 2>&1 || missing+=("nix")
    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v git >/dev/null 2>&1 || missing+=("git")

    # Check if proxmox-ops is available
    if [[ "$PROXMOX_OPS" == "proxmox-ops" ]]; then
        command -v proxmox-ops >/dev/null 2>&1 || missing+=("proxmox-ops")
    elif [[ ! -f "$PROXMOX_OPS" ]]; then
        log_error "proxmox-ops.sh not found at $PROXMOX_OPS"
        return 1
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        return 1
    fi

    # Check if we're in the nixosconfig repository
    if [[ ! -f "vms/definitions.nix" ]] || [[ ! -f "hosts.nix" ]]; then
        log_error "Must be run from the nixosconfig repository root"
        log_error "Required files not found: vms/definitions.nix, hosts.nix"
        log_error ""
        log_error "Run this command from your nixosconfig directory:"
        log_error "  cd /path/to/nixosconfig && nix run .#provision-vm <vm-name>"
        return 1
    fi

    log_success "All prerequisites met"
}

# Load VM definition from Nix
load_vm_definition() {
    local vm_name="$1"

    log_info "Loading VM definition for '$vm_name'..."

    # Use Nix to extract VM definition
    # Use absolute paths from repository root
    local nix_expr="
        let
          lib = (import <nixpkgs> {}).lib;
          vmLib = import $REPO_ROOT/vms/lib.nix { inherit lib; };
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
          cloudinit = import $REPO_ROOT/vms/cloudinit.nix { inherit lib pkgs; };
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

    log_info "Cloning template (VMID 9002) to VMID $vmid..."

    if ! "$PROXMOX_OPS" clone 9002 "$vmid" "$vm_name" "$storage"; then
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

# Resize VM disk to target size
resize_vm_disk() {
    local vmid="$1"
    local disk="$2"

    log_info "Resizing disk to $disk..."

    if ! "$PROXMOX_OPS" resize "$vmid" scsi0 "$disk"; then
        log_error "Failed to resize disk"
        return 1
    fi

    log_success "Disk resized to $disk"
}

# Setup cloud-init
setup_cloudinit() {
    local vmid="$1"
    local ssh_keys="$2"
    # storage parameter kept for API compatibility but not used
    # (cloud-init drive inherited from template)

    log_info "Configuring cloud-init with SSH keys..."

    # Configure cloud-init with SSH keys
    # (cloud-init drive already exists from template clone)
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

    # Redirect stdout to stderr so it doesn't pollute return value
    if ! "$PROXMOX_OPS" start "$vmid" >&2; then
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
        echo -n "." >&2
        sleep 5
    done

    echo "" >&2

    if [[ -z "$vm_ip" || "$vm_ip" == "null" ]]; then
        log_error "Timeout waiting for VM IP address"
        log_error "VM may not have QEMU guest agent installed"
        return 1
    fi

    # Wait for SSH to be ready
    log_info "Waiting for SSH to be ready..."
    if ! "$PROXMOX_OPS" wait-ssh "$vm_ip" 300 >&2; then
        log_error "SSH not ready after 5 minutes"
        return 1
    fi

    log_success "VM is accessible via SSH at $vm_ip"
    echo "$vm_ip"
}

# Get VM MAC address from Proxmox
get_vm_mac() {
    local vmid="$1"
    "$PROXMOX_OPS" config "$vmid" | grep -oP 'net0:.*virtio=\K[^,]+' | tr '[:upper:]' '[:lower:]'
}

# Find VM IP by MAC address (with retries), optionally waiting for IP to change
find_ip_by_mac() {
    local vmid="$1"
    local max_attempts="${2:-30}"
    local old_ip="${3:-}"  # If provided, wait for IP to be different from this
    local attempt=0

    if [[ -n "$old_ip" ]]; then
        log_info "Finding new VM IP (waiting for change from $old_ip)..."
    else
        log_info "Finding VM IP via MAC address lookup..."
    fi

    while [[ $attempt -lt $max_attempts ]]; do
        local ip
        ip=$("$PROXMOX_OPS" get-ip "$vmid" 2>/dev/null || echo "")

        if [[ -n "$ip" && "$ip" != "null" ]]; then
            # If we're waiting for IP change, check it's different
            if [[ -n "$old_ip" && "$ip" == "$old_ip" ]]; then
                # Same IP, keep waiting
                :
            else
                echo "$ip"
                return 0
            fi
        fi

        attempt=$((attempt + 1))
        echo -n "." >&2
        sleep 5
    done

    echo "" >&2
    return 1
}

# Deploy NixOS via nixos-anywhere (two-phase for IP change handling)
deploy_nixos() {
    local vmid="$1"
    local nixos_config="$2"
    local initial_ip="$3"

    log_info "Deploying NixOS via nixos-anywhere (two-phase approach)..."
    echo ""
    log_info "Phase 1: kexec into NixOS installer"
    log_warning "Note: IP address will change after kexec - this is expected"
    log_warning "We'll find the new IP and continue installation there"
    echo ""

    # Phase 1: kexec ONLY (disko must run on new IP after kexec)
    # nixos-anywhere will hang waiting for reconnection after kexec because IP changes
    log_info "Running: nixos-anywhere --phases kexec --flake .#$nixos_config root@$initial_ip"

    # Run phase 1 in background - it will hang after kexec, we'll kill it
    # Use </dev/null to prevent stdin issues when script is run with pipes
    nix run github:nix-community/nixos-anywhere -- \
        --phases kexec \
        --flake ".#$nixos_config" \
        "root@$initial_ip" </dev/null &
    local nixos_anywhere_pid=$!

    # Wait for kexec to happen by monitoring if old IP becomes unreachable
    log_info "Waiting for kexec (monitoring $initial_ip)..."
    local wait_count=0
    while [[ $wait_count -lt 60 ]]; do
        sleep 5
        wait_count=$((wait_count + 1))

        # Check if old IP is still reachable
        if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=3 -o BatchMode=yes \
            "root@$initial_ip" "true" 2>/dev/null; then
            log_info "Old IP no longer reachable - kexec happened"
            break
        fi
        echo -n "." >&2
    done
    echo "" >&2

    # Kill the nixos-anywhere process (it's stuck waiting for dead connection)
    if kill -0 "$nixos_anywhere_pid" 2>/dev/null; then
        log_info "Killing nixos-anywhere process (it's stuck on dead connection)"
        kill "$nixos_anywhere_pid" 2>/dev/null || true
        wait "$nixos_anywhere_pid" 2>/dev/null || true
    fi

    echo ""
    log_info "Waiting for NixOS installer to boot and obtain new IP..."
    log_info "Sleeping 30s to allow kexec and DHCP..."
    sleep 30

    # Find new IP via MAC address (must be different from initial_ip)
    local new_ip
    if ! new_ip=$(find_ip_by_mac "$vmid" 40 "$initial_ip"); then
        log_error "Could not find new VM IP after kexec (was looking for change from $initial_ip)"
        log_error "Check Proxmox console for VM status"
        return 1
    fi

    echo ""
    log_success "Found VM at new IP: $new_ip"

    # Wait for SSH on new IP
    log_info "Waiting for SSH on new IP..."
    if ! "$PROXMOX_OPS" wait-ssh "$new_ip" 180; then
        log_error "SSH not ready on $new_ip"
        return 1
    fi

    # Verify we're in the NixOS installer (not still Ubuntu)
    log_info "Verifying NixOS installer environment..."
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$new_ip" "command -v nixos-install" &>/dev/null; then
        log_error "Not in NixOS installer - kexec may have failed"
        log_error "Check Proxmox console"
        return 1
    fi
    log_success "Confirmed NixOS installer environment"

    echo ""
    log_info "Phase 2: Partitioning disk and installing NixOS"
    log_info "Running: nixos-anywhere --phases disko,install --flake .#$nixos_config root@$new_ip"

    # Phase 2: disko + install NixOS (use </dev/null to prevent stdin issues)
    if ! nix run github:nix-community/nixos-anywhere -- \
        --phases disko,install \
        --flake ".#$nixos_config" \
        "root@$new_ip" </dev/null; then
        log_error "NixOS installation failed"
        return 1
    fi

    log_success "NixOS installation complete!"

    # Reboot into the installed system
    log_info "Rebooting VM into installed NixOS..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "root@$new_ip" "reboot" 2>/dev/null || true

    # Wait for reboot and find final IP
    log_info "Waiting 30s for VM to reboot..."
    sleep 30

    local final_ip
    if ! final_ip=$(find_ip_by_mac "$vmid" 30); then
        log_warning "Could not find final VM IP - VM may have different IP after reboot"
        log_warning "Check Proxmox for current IP"
        echo "$new_ip"
        return 0
    fi

    # Wait for SSH on final IP (as abl030, not root - root SSH is disabled)
    log_info "Waiting for SSH on final system (user: abl030)..."
    if "$PROXMOX_OPS" wait-ssh "$final_ip" 120 abl030 2>/dev/null; then
        log_success "NixOS is up and running at $final_ip"
        log_success "SSH: ssh abl030@$final_ip"
    else
        log_warning "SSH not ready yet - VM may still be booting"
    fi

    echo "$final_ip"
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
    log_warning "  4. Deploy NixOS via nixos-anywhere (two-phase)"
    log_warning "     - Phase 1: kexec only (IP will change after this)"
    log_warning "     - Phase 2: disko + install on new IP"
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

    # Resize disk (template already has base disk from cloud image)
    if ! resize_vm_disk "$VMID" "$DISK"; then
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
    log_info "VM booted with initial IP: $vm_ip"
    echo ""

    # Deploy NixOS (two-phase)
    local final_ip
    if ! final_ip=$(deploy_nixos "$VMID" "$NIXOS_CONFIG" "$vm_ip"); then
        log_error "NixOS deployment failed"
        log_info "VM is still running. You can:"
        log_info "  - Check console in Proxmox"
        log_info "  - Try manual deployment: nixos-anywhere --flake .#$NIXOS_CONFIG root@<ip>"
        return 1
    fi

    echo ""
    log_success "VM provisioning complete!"
    echo ""
    log_info "Next steps:"
    log_info "  Run post-provisioning to integrate with fleet:"
    log_info "  nix run .#post-provision-vm $vm_name $final_ip $VMID"
    log_info ""
    log_info "  This will:"
    log_info "     - Extract SSH host key"
    log_info "     - Update hosts.nix and secrets"
    log_info "     - Update documentation"
    log_info ""
    log_info "VM Details:"
    log_info "  VMID: $VMID"
    log_info "  Final IP: $final_ip"
    log_info "  SSH: ssh abl030@$final_ip"
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
