#!/usr/bin/env bash
# Proxmox VM Operations via SSH
# ==============================
#
# Wrapper script for Proxmox qm commands via SSH.
# Designed to be called from Nix derivations or automation scripts.
#
# Safety: Always checks against readonly VMIDs before destructive operations.

set -euo pipefail

# Proxmox connection details (can be overridden by environment)
PROXMOX_HOST="${PROXMOX_HOST:-192.168.1.12}"
PROXMOX_USER="${PROXMOX_USER:-root}"
PROXMOX_NODE="${PROXMOX_NODE:-prom}"

# SSH options for non-interactive use (as array to avoid quoting issues)
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# Execute SSH command on Proxmox host
ssh_exec() {
    # SC2029: Expansion on client side is intentional - we're passing commands to execute remotely
    # shellcheck disable=SC2029
    ssh "${SSH_OPTS[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "$@"
}

# List all VMs (JSON format)
list_vms() {
    ssh_exec "pvesh get /cluster/resources --type vm --output-format=json-pretty"
}

# Get VM status
get_vm_status() {
    local vmid="$1"
    ssh_exec "qm status ${vmid}"
}

# Get VM configuration
get_vm_config() {
    local vmid="$1"
    ssh_exec "qm config ${vmid}"
}

# Check if VMID exists
vmid_exists() {
    local vmid="$1"
    if ssh_exec "qm status ${vmid}" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Check if VMID is in readonly list
is_readonly_vmid() {
    local vmid="$1"
    # Set PROXMOX_READONLY_VMIDS="104 109" to enforce extra safety checks
    local readonly_vmids=()
    if [[ -n "${PROXMOX_READONLY_VMIDS:-}" ]]; then
        read -r -a readonly_vmids <<< "${PROXMOX_READONLY_VMIDS}"
    fi

    for readonly_vmid in "${readonly_vmids[@]}"; do
        if [[ "$vmid" == "$readonly_vmid" ]]; then
            return 0
        fi
    done
    return 1
}

# Safety check before destructive operations
check_operation_allowed() {
    local vmid="$1"
    local operation="$2"

    if is_readonly_vmid "$vmid"; then
        echo "ERROR: VMID ${vmid} is marked as READONLY (imported)." >&2
        echo "Operation '${operation}' is not allowed on imported VMs." >&2
        echo "" >&2
        echo "This VM is documented for inventory purposes only." >&2
        echo "If you need to manage this VM, update its proxmox.readonly flag in hosts.nix." >&2
        return 1
    fi
    return 0
}

# Clone VM from template
clone_vm() {
    local template_vmid="$1"
    local new_vmid="$2"
    local vm_name="$3"
    local storage="${4:-nvmeprom}"

    check_operation_allowed "$new_vmid" "clone" || return 1

    if vmid_exists "$new_vmid"; then
        echo "ERROR: VMID ${new_vmid} already exists!" >&2
        return 1
    fi

    echo "Cloning VMID ${template_vmid} to ${new_vmid} (${vm_name})..." >&2
    ssh_exec "qm clone ${template_vmid} ${new_vmid} --name '${vm_name}' --full --storage ${storage}"
}

# Restore VM from a VMA archive
restore_vm() {
    local archive="$1"
    local vmid="$2"
    local storage="${3:-nvmeprom}"

    check_operation_allowed "$vmid" "restore" || return 1

    if vmid_exists "$vmid"; then
        echo "ERROR: VMID ${vmid} already exists!" >&2
        return 1
    fi

    echo "Restoring VMID ${vmid} from ${archive} to ${storage}..." >&2
    ssh_exec "qmrestore ${archive} ${vmid} --unique true --storage ${storage}"
}

# Configure VM resources
configure_vm() {
    local vmid="$1"
    local cores="$2"
    local memory="$3"  # in MB

    check_operation_allowed "$vmid" "configure" || return 1

    echo "Configuring VMID ${vmid}: ${cores} cores, ${memory}MB RAM..." >&2
    ssh_exec "qm set ${vmid} --cores ${cores} --memory ${memory}"
}

# Enable serial console socket
set_serial_socket() {
    local vmid="$1"

    check_operation_allowed "$vmid" "serial" || return 1

    echo "Enabling serial0 socket for VMID ${vmid}..." >&2
    ssh_exec "qm set ${vmid} --serial0 socket"
}

# Resize VM disk
resize_vm_disk() {
    local vmid="$1"
    local disk="$2"      # e.g., scsi0
    local size="$3"      # e.g., +20G

    check_operation_allowed "$vmid" "resize" || return 1

    echo "Resizing VMID ${vmid} disk ${disk} to ${size}..." >&2
    ssh_exec "qm resize ${vmid} ${disk} ${size}"
}

# Create and attach disk to VM
create_vm_disk() {
    local vmid="$1"
    local size="$2"      # e.g., 32G
    local storage="${3:-nvmeprom}"
    local disk="${4:-scsi0}"

    check_operation_allowed "$vmid" "create_disk" || return 1

    echo "Creating ${size} disk for VMID ${vmid} on ${storage}..." >&2
    ssh_exec "qm set ${vmid} --${disk} ${storage}:${size}"
}

# Create cloud-init drive
create_cloudinit_drive() {
    local vmid="$1"
    local storage="${2:-nvmeprom}"

    check_operation_allowed "$vmid" "cloudinit" || return 1

    echo "Creating cloud-init drive for VMID ${vmid}..." >&2
    ssh_exec "qm set ${vmid} --ide2 ${storage}:cloudinit"
}

# Configure cloud-init settings
configure_cloudinit() {
    local vmid="$1"
    local ssh_keys="$2"
    # hostname parameter not currently used but kept for future compatibility
    # shellcheck disable=SC2034
    local hostname="${3:-nixos}"

    check_operation_allowed "$vmid" "cloudinit_config" || return 1

    echo "Configuring cloud-init for VMID ${vmid}..." >&2

    # Set SSH keys
    ssh_exec "qm set ${vmid} --sshkeys <(echo '${ssh_keys}')" || \
        ssh_exec "qm set ${vmid} --sshkey '${ssh_keys}'"

    # Set hostname
    ssh_exec "qm set ${vmid} --ciuser root --cipassword '!' --searchdomain local --nameserver 192.168.1.1"

    # Enable DHCP
    ssh_exec "qm set ${vmid} --ipconfig0 ip=dhcp"
}

# Start VM
start_vm() {
    local vmid="$1"

    check_operation_allowed "$vmid" "start" || return 1

    echo "Starting VMID ${vmid}..." >&2
    ssh_exec "qm start ${vmid}"
}

# Stop VM
stop_vm() {
    local vmid="$1"

    check_operation_allowed "$vmid" "stop" || return 1

    echo "Stopping VMID ${vmid}..." >&2
    ssh_exec "qm stop ${vmid}"
}

# Shutdown VM (graceful)
shutdown_vm() {
    local vmid="$1"

    check_operation_allowed "$vmid" "shutdown" || return 1

    echo "Shutting down VMID ${vmid}..." >&2
    ssh_exec "qm shutdown ${vmid}"
}

# Destroy VM (careful!)
destroy_vm() {
    local vmid="$1"
    local confirm="${2:-no}"

    check_operation_allowed "$vmid" "destroy" || return 1

    if [[ "$confirm" != "yes" ]]; then
        echo "ERROR: destroy_vm requires explicit confirmation" >&2
        echo "Usage: destroy_vm <vmid> yes" >&2
        return 1
    fi

    echo "DESTROYING VMID ${vmid}... (cannot be undone!)" >&2
    ssh_exec "qm destroy ${vmid} --purge"
}

# Convert VM to template
template_vm() {
    local vmid="$1"

    check_operation_allowed "$vmid" "template" || return 1

    echo "Converting VMID ${vmid} to template..." >&2
    ssh_exec "qm template ${vmid}"
}

# Stream VM serial console (interactive with a real TTY)
console_vm() {
    local vmid="$1"

    check_operation_allowed "$vmid" "console" || return 1

    echo "Streaming serial console for VMID ${vmid}..." >&2
    ssh_exec "socat - UNIX-CONNECT:/var/run/qemu-server/${vmid}.serial0"
}

# Get VM IP address (from QEMU agent, or MAC/ARP fallback)
get_vm_ip() {
    local vmid="$1"

    # Try to get IP from QEMU guest agent first
    local ip
    ip=$(ssh_exec "qm guest cmd ${vmid} network-get-interfaces" 2>/dev/null | \
         grep -oP '"ip-address":\s*"\K[0-9.]+' | head -1 || echo "")

    if [[ -z "$ip" || "$ip" == "127.0.0.1" ]]; then
        # Fallback: lookup via MAC address in ARP table
        # This works even when guest agent isn't running yet
        local mac
        mac=$(ssh_exec "qm config ${vmid}" 2>/dev/null | \
              grep -oP 'net0:.*virtio=\K[^,]+' | tr '[:upper:]' '[:lower:]' || echo "")

        if [[ -n "$mac" ]]; then
            # Flush stale ARP entries for this MAC to force fresh lookup
            ssh_exec "ip neigh | grep -i '${mac}' | awk '{print \$1}' | xargs -r -I{} ip neigh del {} dev vmbr0 2>/dev/null || true" &>/dev/null

            # Ping sweep to populate ARP table (run in background, quick)
            ssh_exec "for i in \$(seq 1 254); do (ping -c 1 -W 1 192.168.1.\$i &>/dev/null) & done; wait" &>/dev/null

            # Brief pause to let ARP table settle
            sleep 2

            # Look up MAC in ARP table - prefer REACHABLE/DELAY over STALE
            ip=$(ssh_exec "ip neigh show | grep -i '${mac}' | grep -v 'FAILED' | head -1" 2>/dev/null | \
                 grep -oP '^[0-9.]+' || echo "")
        fi
    fi

    echo "$ip"
}

# Wait for VM to be reachable via SSH
wait_for_ssh() {
    local ip="$1"
    local timeout="${2:-300}"
    local user="${3:-root}"
    local elapsed=0
    local interval=5

    echo "Waiting for SSH at ${user}@${ip}..." >&2

    while (( elapsed < timeout )); do
        if ssh "${SSH_OPTS[@]}" -o ConnectTimeout=2 "${user}@${ip}" "echo ok" &>/dev/null; then
            echo "SSH ready!" >&2
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -n "." >&2
    done

    echo "" >&2
    echo "Timeout waiting for SSH" >&2
    return 1
}

# Get storage status
get_storage_status() {
    ssh_exec "pvesm status"
}

# Get next available VMID
get_next_vmid() {
    local start="${1:-100}"
    local end="${2:-199}"

    ssh_exec "qm list" | awk -v start="$start" -v end="$end" '
        NR > 1 { used[$1] = 1 }
        END {
            for (i = start; i <= end; i++) {
                if (!(i in used)) {
                    print i
                    exit
                }
            }
        }
    '
}

# Main command dispatcher
main() {
    local command="${1:-}"

    if [[ -z "$command" ]]; then
        echo "Usage: $0 <command> [args...]" >&2
        echo "" >&2
        echo "Commands:" >&2
        echo "  list                              List all VMs" >&2
        echo "  status <vmid>                     Get VM status" >&2
        echo "  config <vmid>                     Get VM configuration" >&2
        echo "  clone <template_vmid> <new_vmid> <name> [storage]" >&2
        echo "  configure <vmid> <cores> <memory>" >&2
        echo "  create-disk <vmid> <size> [storage] [disk]" >&2
        echo "  resize <vmid> <disk> <size>       Resize VM disk" >&2
        echo "  restore-vma <archive> <vmid> [storage]" >&2
        echo "  serial-socket <vmid>              Enable serial0 socket" >&2
        echo "  cloudinit-drive <vmid> [storage]" >&2
        echo "  cloudinit-config <vmid> <ssh_keys> [hostname]" >&2
        echo "  start <vmid>" >&2
        echo "  stop <vmid>" >&2
        echo "  shutdown <vmid>" >&2
        echo "  destroy <vmid> yes" >&2
        echo "  template <vmid>" >&2
        echo "  console <vmid>                    Stream serial console (non-interactive)" >&2
        echo "  get-ip <vmid>" >&2
        echo "  wait-ssh <ip> [timeout] [user]" >&2
        echo "  storage                           Get storage status" >&2
        echo "  next-vmid [start] [end]          Get next available VMID" >&2
        return 1
    fi

    shift

    case "$command" in
        list)           list_vms "$@" ;;
        status)         get_vm_status "$@" ;;
        config)         get_vm_config "$@" ;;
        clone)          clone_vm "$@" ;;
        configure)      configure_vm "$@" ;;
        create-disk)    create_vm_disk "$@" ;;
        resize)         resize_vm_disk "$@" ;;
        restore-vma)    restore_vm "$@" ;;
        serial-socket)  set_serial_socket "$@" ;;
        cloudinit-drive) create_cloudinit_drive "$@" ;;
        cloudinit-config) configure_cloudinit "$@" ;;
        start)          start_vm "$@" ;;
        stop)           stop_vm "$@" ;;
        shutdown)       shutdown_vm "$@" ;;
        destroy)        destroy_vm "$@" ;;
        template)       template_vm "$@" ;;
        console)        console_vm "$@" ;;
        get-ip)         get_vm_ip "$@" ;;
        wait-ssh)       wait_for_ssh "$@" ;;
        storage)        get_storage_status "$@" ;;
        next-vmid)      get_next_vmid "$@" ;;
        *)
            echo "Unknown command: $command" >&2
            return 1
            ;;
    esac
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
