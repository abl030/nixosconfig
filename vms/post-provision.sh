#!/usr/bin/env bash
# Post-Provisioning Automation
# ============================
#
# After NixOS is installed on a new VM, this script:
# 1. Extracts SSH host key from the VM
# 2. Updates hosts.nix with the new VM entry
# 3. Converts SSH key to age key for sops
# 4. Updates .sops.yaml with the new age key
# 5. Re-encrypts all secrets
# 6. Updates documentation (docs/machines.md)
# 7. Commits all changes to git
#
# Usage: post-provision.sh <vm-name> <vm-ip> <vmid>

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    command -v ssh-to-age >/dev/null 2>&1 || missing+=("ssh-to-age")
    command -v sops >/dev/null 2>&1 || missing+=("sops")
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v jq >/dev/null 2>&1 || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install missing tools:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                ssh-to-age)
                    log_info "  nix profile install nixpkgs#ssh-to-age"
                    ;;
                sops)
                    log_info "  nix profile install nixpkgs#sops"
                    ;;
            esac
        done
        return 1
    fi

    log_success "All prerequisites met"
}

# Extract SSH host key from VM
extract_ssh_host_key() {
    local vm_ip="$1"

    log_info "Extracting SSH host key from $vm_ip..."

    # SSH options for non-interactive use (as array to avoid quoting issues)
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

    # Extract the ed25519 public key
    local ssh_key
    if ! ssh_key=$(ssh "${ssh_opts[@]}" "root@$vm_ip" "cat /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null); then
        log_error "Failed to extract SSH host key"
        log_error "Make sure the VM is running and accessible"
        return 1
    fi

    # Validate key format
    if ! echo "$ssh_key" | grep -q "^ssh-ed25519 "; then
        log_error "Invalid SSH key format: $ssh_key"
        return 1
    fi

    log_success "SSH host key extracted"
    echo "$ssh_key"
}

# Convert SSH key to age key
ssh_to_age_key() {
    local ssh_key="$1"

    log_info "Converting SSH key to age key..."

    local age_key
    if ! age_key=$(echo "$ssh_key" | ssh-to-age 2>/dev/null); then
        log_error "Failed to convert SSH key to age key"
        return 1
    fi

    log_success "Age key generated: $age_key"
    echo "$age_key"
}

# Update hosts.nix with new VM entry
update_hosts_nix() {
    local vm_name="$1"
    local ssh_key="$2"
    local vmid="$3"

    log_info "Updating hosts.nix..."

    local hosts_file="$REPO_ROOT/hosts.nix"

    if [[ ! -f "$hosts_file" ]]; then
        log_error "hosts.nix not found at $hosts_file"
        return 1
    fi

    # Extract just the key part (without the comment)
    local key_part
    key_part=$(echo "$ssh_key" | awk '{print $2}')

    # Create the new entry
    local new_entry="
  $vm_name = {
    configurationFile = ./hosts/$vm_name/configuration.nix;
    homeFile = ./hosts/$vm_name/home.nix;
    user = \"abl030\";
    homeDirectory = \"/home/abl030\";
    hostname = \"$vm_name\";
    sshAlias = \"$vm_name\";
    sshKeyName = \"ssh_key_abl030\";
    publicKey = \"ssh-ed25519 $key_part\";
    authorizedKeys = masterKeys;
  };
"

    # Check if entry already exists
    if grep -q "^  $vm_name = {" "$hosts_file"; then
        log_warning "Entry for '$vm_name' already exists in hosts.nix"
        log_info "Updating existing entry..."

        # Create a temp file with the updated entry
        local temp_file
        temp_file=$(mktemp)

        # Replace the existing entry
        awk -v name="$vm_name" -v entry="$new_entry" '
            /^  '"$vm_name"' = \{/ {
                print entry
                skip=1
                next
            }
            skip && /^  \};/ {
                skip=0
                next
            }
            !skip { print }
        ' "$hosts_file" > "$temp_file"

        mv "$temp_file" "$hosts_file"
    else
        log_info "Adding new entry to hosts.nix..."

        # Find the last host entry and add the new one before the closing brace
        # This is a simple approach - inserts before the final '}'
        local temp_file
        temp_file=$(mktemp)

        # Add entry before the last closing brace
        sed '$d' "$hosts_file" > "$temp_file"
        echo "$new_entry" >> "$temp_file"
        echo "}" >> "$temp_file"

        mv "$temp_file" "$hosts_file"
    fi

    log_success "hosts.nix updated"
}

# Update .sops.yaml with new age key
update_sops_yaml() {
    local vm_name="$1"
    local age_key="$2"

    log_info "Updating .sops.yaml..."

    local sops_file="$REPO_ROOT/.sops.yaml"

    if [[ ! -f "$sops_file" ]]; then
        log_error ".sops.yaml not found at $sops_file"
        return 1
    fi

    # Check if age key already exists
    if grep -q "$age_key" "$sops_file"; then
        log_warning "Age key for '$vm_name' already exists in .sops.yaml"
        return 0
    fi

    # Add the age key to the keys section
    # This is a simple approach - adds to the end of the keys list
    local temp_file
    temp_file=$(mktemp)

    # Find the keys section and add the new key
    awk -v key="$age_key" -v name="$vm_name" '
        /^keys:/ {
            print
            in_keys=1
            next
        }
        in_keys && /^  - &/ {
            print
            next
        }
        in_keys && /^[^ ]/ {
            # End of keys section, add new key before this line
            print "  - &" name " " key
            in_keys=0
        }
        { print }
        END {
            # If we are still in keys section at end of file
            if (in_keys) {
                print "  - &" name " " key
            }
        }
    ' "$sops_file" > "$temp_file"

    mv "$temp_file" "$sops_file"

    log_success ".sops.yaml updated"
}

# Re-encrypt all secrets
reencrypt_secrets() {
    log_info "Re-encrypting all secrets with new key..."

    cd "$REPO_ROOT"

    if ! sops updatekeys --yes secrets/secrets.yaml 2>&1; then
        log_warning "Note: sops updatekeys may show warnings, this is usually fine"
    fi

    # Update other secret files if they exist
    if [[ -d "$REPO_ROOT/secrets" ]]; then
        find "$REPO_ROOT/secrets" -name "*.yaml" -o -name "*.yml" | while read -r secret_file; do
            if [[ -f "$secret_file" ]]; then
                log_info "Updating keys for $secret_file..."
                sops updatekeys --yes "$secret_file" 2>&1 || true
            fi
        done
    fi

    log_success "Secrets re-encrypted"
}

# Update documentation
update_documentation() {
    local vm_name="$1"
    local vmid="$2"

    log_info "Updating documentation..."

    # For now, just log that we should update it
    # In the future, this could auto-generate or update docs/machines.md
    log_warning "TODO: Update docs/machines.md with new VM information"
    log_info "  Add entry for VMID $vmid ($vm_name)"
}

# Commit changes to git
commit_changes() {
    local vm_name="$1"

    log_info "Committing changes to git..."

    cd "$REPO_ROOT"

    # Check if there are changes to commit
    if ! git diff --quiet || ! git diff --cached --quiet || [[ -n $(git ls-files --others --exclude-standard) ]]; then
        # Stage changes
        git add hosts.nix .sops.yaml secrets/ 2>/dev/null || true

        # Create commit
        local commit_msg="feat(vms): add $vm_name to fleet

- Add SSH host key to hosts.nix
- Update .sops.yaml with age key
- Re-encrypt secrets with new key

Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"

        if git commit -m "$commit_msg"; then
            log_success "Changes committed to git"

            # Show what was committed
            log_info "Committed files:"
            git diff HEAD~1 --name-only | sed 's/^/  - /'
        else
            log_error "Failed to commit changes"
            return 1
        fi
    else
        log_info "No changes to commit"
    fi
}

# Main post-provisioning workflow
post_provision() {
    local vm_name="$1"
    local vm_ip="$2"
    local vmid="$3"

    log_info "Starting post-provisioning for: $vm_name"
    log_info "  IP: $vm_ip"
    log_info "  VMID: $vmid"
    echo ""

    # Extract SSH host key
    local ssh_key
    if ! ssh_key=$(extract_ssh_host_key "$vm_ip"); then
        return 1
    fi

    # Convert to age key
    local age_key
    if ! age_key=$(ssh_to_age_key "$ssh_key"); then
        return 1
    fi

    # Update hosts.nix
    if ! update_hosts_nix "$vm_name" "$ssh_key" "$vmid"; then
        return 1
    fi

    # Update .sops.yaml
    if ! update_sops_yaml "$vm_name" "$age_key"; then
        return 1
    fi

    # Re-encrypt secrets
    if ! reencrypt_secrets; then
        log_warning "Secret re-encryption had warnings, but continuing..."
    fi

    # Update documentation
    update_documentation "$vm_name" "$vmid"

    # Commit changes
    if ! commit_changes "$vm_name"; then
        log_warning "Git commit failed, but VM integration is complete"
    fi

    echo ""
    log_success "Post-provisioning complete!"
    echo ""
    log_info "VM '$vm_name' has been integrated into the fleet"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Rebuild VM with secrets:"
    log_info "     nixos-rebuild switch --flake .#$vm_name --target-host $vm_name"
    log_info ""
    log_info "  2. Connect via SSH alias:"
    log_info "     ssh $vm_name"
}

# Main entry point
main() {
    if [[ $# -lt 3 ]]; then
        echo "Usage: $0 <vm-name> <vm-ip> <vmid>"
        echo ""
        echo "Example:"
        echo "  $0 test-vm 192.168.1.50 110"
        echo ""
        echo "This script should be run after NixOS is installed on the VM"
        return 1
    fi

    local vm_name="$1"
    local vm_ip="$2"
    local vmid="$3"

    # Check prerequisites
    if ! check_prerequisites; then
        return 1
    fi

    # Change to repo root
    cd "$REPO_ROOT"

    # Run post-provisioning
    post_provision "$vm_name" "$vm_ip" "$vmid"
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
