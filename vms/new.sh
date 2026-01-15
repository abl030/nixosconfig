#!/usr/bin/env bash
# Interactive VM creation wizard
# Creates managed VM definition + host config, then provisions.

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
# shellcheck disable=SC2016
DEFAULT_INITIAL_HASH='$6$58mDYkJdHY9JTiTU$whCjz4eG3T9jPajUIlhqqBJ9qzqZM7xY91ylSy.WC2MkR.ckExn0aNRMM0XNX1LKxIXL/VJe/3.oizq2S6cvA0' # temp123

log_info() {
    echo -e "${BLUE}==>${NC} $*" >&2 || true
}

log_success() {
    echo -e "${GREEN}OK${NC} $*" >&2 || true
}

log_warning() {
    echo -e "${YELLOW}WARN${NC} $*" >&2 || true
}

log_error() {
    echo -e "${RED}ERR${NC} $*" >&2 || true
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if git rev-parse --git-dir >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

if command -v proxmox-ops >/dev/null 2>&1; then
    PROXMOX_OPS="proxmox-ops"
else
    PROXMOX_OPS="$SCRIPT_DIR/proxmox-ops.sh"
fi

require_repo_root() {
    if [[ ! -f "$REPO_ROOT/hosts.nix" ]]; then
        log_error "Run this from the nixosconfig repo root."
        log_error "Missing file: hosts.nix"
        exit 1
    fi
}

is_valid_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

is_valid_alias() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

escape_nix_string() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/ }
    printf "%s" "$value"
}

prompt_required() {
    local prompt="$1"
    local default="${2:-}"
    local value=""

    while [[ -z "$value" ]]; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " value
            value="${value:-$default}"
        else
            read -r -p "$prompt: " value
        fi
        value="$(echo "$value" | tr -d '\r')"
        if [[ -z "$value" ]]; then
            log_warning "Value required."
        fi
    done

    printf "%s" "$value"
}

prompt_optional() {
    local prompt="$1"
    local default="${2:-}"
    local value=""

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " value
        value="${value:-$default}"
    else
        read -r -p "$prompt: " value
    fi

    value="$(echo "$value" | tr -d '\r')"
    printf "%s" "$value"
}

load_defaults() {
    DEFAULT_STORAGE="nvmeprom"
    if storage=$(nix eval --raw --impure --expr "(import $REPO_ROOT/hosts.nix)._proxmox.defaultStorage" 2>/dev/null); then
        [[ -n "$storage" ]] && DEFAULT_STORAGE="$storage"
    fi

    DEFAULT_VMID=""
    if "$PROXMOX_OPS" list >/dev/null 2>&1; then
        if used_vmids=$("$PROXMOX_OPS" list | jq -r '.[].vmid' 2>/dev/null); then
            used_vmids="$(echo "$used_vmids" | tr '\n' ' ')"
            for i in $(seq 100 199); do
                if ! echo " $used_vmids " | grep -q " $i "; then
                    DEFAULT_VMID="$i"
                    break
                fi
            done
        fi
    fi

    if [[ -z "$DEFAULT_VMID" ]]; then
        if vmids=$(nix eval --raw --impure --expr '
            let
              hosts = import '"$REPO_ROOT"'/hosts.nix;
              ids = map (h: if h ? proxmox && h.proxmox ? vmid then toString h.proxmox.vmid else "")
                (builtins.attrValues hosts);
              filtered = builtins.filter (v: v != "") ids;
            in builtins.concatStringsSep " " filtered
        ' 2>/dev/null); then
            for i in $(seq 100 199); do
                if ! echo " $vmids " | grep -q " $i "; then
                    DEFAULT_VMID="$i"
                    break
                fi
            done
        fi
    fi

    DEFAULT_CORES="4"
    DEFAULT_MEMORY="8192"
    DEFAULT_DISK="64G"
}

ensure_unique_name() {
    local name="$1"

    if existing=$(nix eval --raw --impure --expr '
        let hosts = import '"$REPO_ROOT"'/hosts.nix;
        in builtins.concatStringsSep " " (builtins.attrNames hosts)
    ' 2>/dev/null); then
        if echo " $existing " | grep -q " $name "; then
            log_error "Host '$name' already exists in hosts.nix"
            log_error "Use: pve provision $name"
            exit 1
        fi
    fi

    if [[ -d "$REPO_ROOT/hosts/$name" ]]; then
        log_error "Host config already exists at hosts/$name"
        log_error "Use: pve integrate $name <ip> <vmid>"
        exit 1
    fi
}

ensure_unique_alias() {
    local alias="$1"

    local existing
    if existing=$(nix eval --raw --impure --expr '
        let hosts = import '"$REPO_ROOT"'/hosts.nix;
        in builtins.concatStringsSep " " (map (h: h.sshAlias or "") (builtins.attrValues hosts))
    ' 2>/dev/null); then
        if echo " $existing " | grep -q " $alias "; then
            log_error "SSH alias '$alias' already exists in hosts.nix"
            exit 1
        fi
    fi
}

ensure_unique_vmid() {
    local vmid="$1"

    if [[ -z "$vmid" ]]; then
        log_error "VMID is required."
        exit 1
    fi

    if ! [[ "$vmid" =~ ^[0-9]+$ ]]; then
        log_error "VMID must be numeric."
        exit 1
    fi

    local existing
    if existing=$(nix eval --raw --impure --expr '
        let
          hosts = import '"$REPO_ROOT"'/hosts.nix;
          ids = map (h: if h ? proxmox && h.proxmox ? vmid then toString h.proxmox.vmid else "")
            (builtins.attrValues hosts);
          filtered = builtins.filter (v: v != "") ids;
        in builtins.concatStringsSep " " filtered
    ' 2>/dev/null); then
        if echo " $existing " | grep -q " $vmid "; then
            log_error "VMID $vmid already exists in hosts.nix"
            exit 1
        fi
    fi

    if "$PROXMOX_OPS" list >/dev/null 2>&1; then
        if "$PROXMOX_OPS" list | jq -r '.[].vmid' 2>/dev/null | grep -q "^${vmid}$"; then
            log_error "VMID $vmid already exists on Proxmox"
            exit 1
        fi
    fi
}

normalize_disk_size() {
    local disk="$1"

    if [[ "$disk" =~ ^[0-9]+$ ]]; then
        printf "%sG" "$disk"
        return 0
    fi

    if [[ "$disk" =~ ^[0-9]+[GgMm]$ ]]; then
        printf "%s" "${disk^^}"
        return 0
    fi

    return 1
}

validate_resource_inputs() {
    local cores="$1"
    local memory="$2"
    local disk="$3"

    if ! [[ "$cores" =~ ^[0-9]+$ ]]; then
        log_error "CPU cores must be numeric."
        exit 1
    fi

    if ! [[ "$memory" =~ ^[0-9]+$ ]]; then
        log_error "Memory must be numeric (MB)."
        exit 1
    fi

    if ! normalize_disk_size "$disk" >/dev/null; then
        log_error "Disk size must be a number (GB) or a size like 32G/4096M."
        exit 1
    fi
}

create_host_files() {
    local name="$1"
    local target_dir="$REPO_ROOT/hosts/$name"
    local base_dir="$REPO_ROOT/hosts/vm_base"

    if [[ ! -d "$base_dir" ]]; then
        log_error "Base host template not found at $base_dir"
        exit 1
    fi

    for base_file in configuration.nix home.nix; do
        if [[ ! -f "$base_dir/$base_file" ]]; then
            log_error "Missing $base_dir/$base_file"
            exit 1
        fi
    done

    mkdir -p "$target_dir"
    cp "$base_dir/configuration.nix" "$target_dir/configuration.nix"
    cp "$base_dir/home.nix" "$target_dir/home.nix"
}

add_hosts_entry() {
    local name="$1"
    local alias="$2"
    local vmid="$3"
    local cores="$4"
    local memory="$5"
    local disk="$6"
    local storage="$7"
    local purpose="$8"
    local description
    description="$(escape_nix_string "$purpose")"

    local hosts_file="$REPO_ROOT/hosts.nix"
    local temp_file
    temp_file=$(mktemp)

    local new_entry="
  $name = {
    configurationFile = ./hosts/$name/configuration.nix;
    homeFile = ./hosts/$name/home.nix;
    user = \"abl030\";
    homeDirectory = \"/home/abl030\";
    hostname = \"$name\";
    sshAlias = \"$alias\";
    sshKeyName = \"ssh_key_abl030\";
    initialHashedPassword = \"$DEFAULT_INITIAL_HASH\"; # temp123
    publicKey = \"ssh-ed25519 PLACEHOLDER\";
    authorizedKeys = masterKeys;
    proxmox = {
      vmid = $vmid;
      cores = $cores;
      memory = $memory;
      disk = \"$disk\";
      storage = \"$storage\";
      description = \"$description\";
    };
  };
"

    sed '$d' "$hosts_file" > "$temp_file"
    echo "$new_entry" >> "$temp_file"
    echo "}" >> "$temp_file"
    mv "$temp_file" "$hosts_file"
}

remove_hosts_entry() {
    local name="$1"
    local hosts_file="$REPO_ROOT/hosts.nix"
    local temp_file
    temp_file=$(mktemp)

    awk -v name="$name" '
        $0 ~ "^  "name" = \\{" {skip=1; next}
        skip && /^  \};/ {skip=0; next}
        !skip {print}
    ' "$hosts_file" > "$temp_file"

    mv "$temp_file" "$hosts_file"
}

cleanup_generated() {
    local name="$1"
    local cleanup_dir="$REPO_ROOT/hosts/$name"

    remove_hosts_entry "$name"
    rm -rf "$cleanup_dir"
}

load_pve_token() {
    if [[ -n "${PROXMOX_VE_API_TOKEN:-}" ]]; then
        return 0
    fi

    local token_file="${PVE_TOKEN_FILE:-$HOME/.pve_token}"
    if [[ ! -f "$token_file" && -f /tmp/pve_token ]]; then
        log_warning "Token file not found at $token_file; using /tmp/pve_token for this run."
        token_file="/tmp/pve_token"
    fi

    if [[ ! -f "$token_file" ]]; then
        log_error "PVE token file not found. Set PVE_TOKEN_FILE or create $HOME/.pve_token."
        exit 1
    fi

    local token_line
    token_line="$(head -n1 "$token_file")"
    if [[ -z "$token_line" || "$token_line" != *"="* ]]; then
        log_error "Invalid token format in $token_file. Expected: user@realm!tokenid=secret"
        exit 1
    fi

    export PROXMOX_VE_API_TOKEN="$token_line"
}

main() {
    require_repo_root
    load_defaults

    local name=""
    local alias=""
    local vmid=""

    log_info "Proxmox VM Provisioning Wizard"

    while true; do
        name="$(prompt_required "Hostname")"

        if ! is_valid_name "$name"; then
            log_warning "Name must match: lowercase letters, digits, hyphens."
            continue
        fi
        break
    done

    ensure_unique_name "$name"

    while true; do
        alias="$(prompt_required "SSH alias" "$name")"
        if ! is_valid_alias "$alias"; then
            log_warning "Alias must match: lowercase letters, digits, hyphens."
            continue
        fi
        break
    done

    ensure_unique_alias "$alias"

    log_info "VMID: press Enter to use next available (${DEFAULT_VMID})."
    vmid="$(prompt_required "VMID" "$DEFAULT_VMID")"
    ensure_unique_vmid "$vmid"

    local purpose
    purpose="$(prompt_required "Purpose" "General purpose VM")"

    local cores
    cores="$(prompt_required "CPU cores" "$DEFAULT_CORES")"

    local memory
    memory="$(prompt_required "Memory (MB)" "$DEFAULT_MEMORY")"

    local disk
    disk="$(prompt_required "Disk size (GB or 32G/4096M)" "$DEFAULT_DISK")"
    if normalized_disk=$(normalize_disk_size "$disk"); then
        disk="$normalized_disk"
    fi

    local storage
    storage="$(prompt_required "Storage pool" "$DEFAULT_STORAGE")"

    validate_resource_inputs "$cores" "$memory" "$disk"

    echo ""
    log_info "Preview"
    echo "  Hostname: $name"
    echo "  Alias:    $alias"
    echo "  VMID:     $vmid"
    echo "  Cores:    $cores"
    echo "  Memory:   ${memory} MB"
    echo "  Disk:     $disk"
    echo "  Storage:  $storage"
    echo "  Purpose:  $purpose"
    echo ""

    local confirm
    read -r -p "Proceed? [y/N]: " confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) log_warning "Cancelled."; exit 1 ;;
    esac

    log_info "Creating host configuration..."
    create_host_files "$name"
    log_success "Created hosts/$name"

    log_info "Adding hosts.nix entry..."
    add_hosts_entry "$name" "$alias" "$vmid" "$cores" "$memory" "$disk" "$storage" "$purpose"
    log_success "Updated hosts.nix"

    log_info "Staging generated files..."
    if git rev-parse --git-dir >/dev/null 2>&1; then
        git add "hosts/$name" "hosts.nix"
        log_success "Staged hosts/$name and hosts.nix"
    else
        log_warning "Not a git repo; skipping staging."
    fi

    cd "$REPO_ROOT"
    load_pve_token

    local tofu_workdir="${TOFU_WORKDIR:-$REPO_ROOT/vms/tofu/.state}"
    log_info "Planning OpenTofu changes..."
    if ! TOFU_WORKDIR="$tofu_workdir" nix run .#tofu-plan; then
        log_error "OpenTofu plan failed."
        local confirm
        read -r -p "Clean up generated config? [y/N]: " confirm
        case "$confirm" in
            y|Y|yes|YES)
                cleanup_generated "$name"
                log_warning "Cleaned up hosts/$name and hosts.nix."
                ;;
            *) log_warning "Keeping generated files for inspection." ;;
        esac
        exit 1
    fi

    local apply_confirm
    read -r -p "Apply OpenTofu changes now? [y/N]: " apply_confirm
    case "$apply_confirm" in
        y|Y|yes|YES) ;;
        *) log_warning "Apply skipped."; exit 0 ;;
    esac

    log_info "Applying OpenTofu changes..."
    if ! TOFU_WORKDIR="$tofu_workdir" nix run .#tofu-apply; then
        log_error "OpenTofu apply failed."
        exit 1
    fi

    local vm_ip="unknown"
    if "$PROXMOX_OPS" get-ip "$vmid" >/dev/null 2>&1; then
        vm_ip="$("$PROXMOX_OPS" get-ip "$vmid" 2>/dev/null || echo "unknown")"
    fi

    echo ""
    log_info "Next step: integrate the VM into the fleet"
    if [[ -n "$vm_ip" && "$vm_ip" != "unknown" ]]; then
        echo "  - pve integrate $name $vm_ip $vmid"
        echo "  - or: nix run .#post-provision-vm $name $vm_ip $vmid"
    else
        echo "  - pve integrate $name <ip> $vmid"
        echo "  - or: nix run .#post-provision-vm $name <ip> $vmid"
    fi
}

main "$@"
