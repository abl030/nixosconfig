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
    if [[ ! -f "$REPO_ROOT/vms/definitions.nix" ]] || [[ ! -f "$REPO_ROOT/hosts.nix" ]]; then
        log_error "Run this from the nixosconfig repo root."
        log_error "Missing files: vms/definitions.nix or hosts.nix"
        exit 1
    fi
}

escape_nix_string() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/ }
    printf "%s" "$value"
}

is_valid_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
}

is_valid_alias() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]]
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
    if storage=$(nix eval --raw --impure --expr "(import $REPO_ROOT/vms/definitions.nix).proxmox.defaultStorage" 2>/dev/null); then
        [[ -n "$storage" ]] && DEFAULT_STORAGE="$storage"
    fi

    DEFAULT_VMID=""
    if "$PROXMOX_OPS" next-vmid 100 199 >/dev/null 2>&1; then
        DEFAULT_VMID="$("$PROXMOX_OPS" next-vmid 100 199)"
    else
        if vmids=$(nix eval --raw --impure --expr '
            let defs = import '"$REPO_ROOT"'/vms/definitions.nix;
                all = (builtins.attrValues defs.managed) ++ (builtins.attrValues defs.imported);
                ids = map (vm: toString vm.vmid) all;
            in builtins.concatStringsSep " " ids
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

    local existing
    if existing=$(nix eval --raw --impure --expr '
        let defs = import '"$REPO_ROOT"'/vms/definitions.nix;
        in builtins.concatStringsSep " " ((builtins.attrNames defs.managed) ++ (builtins.attrNames defs.imported))
    ' 2>/dev/null); then
        if echo " $existing " | grep -q " $name "; then
            log_error "VM '$name' already exists in vms/definitions.nix"
            log_error "Use: pve provision $name"
            exit 1
        fi
    fi

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
        log_error "Use: pve provision $name"
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
        let defs = import '"$REPO_ROOT"'/vms/definitions.nix;
            all = (builtins.attrValues defs.managed) ++ (builtins.attrValues defs.imported);
            ids = map (vm: toString vm.vmid) all;
        in builtins.concatStringsSep " " ids
    ' 2>/dev/null); then
        if echo " $existing " | grep -q " $vmid "; then
            log_error "VMID $vmid already exists in vms/definitions.nix"
            exit 1
        fi
    fi

    if "$PROXMOX_OPS" status "$vmid" >/dev/null 2>&1; then
        log_error "VMID $vmid already exists on Proxmox"
        exit 1
    fi
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

    if ! [[ "$disk" =~ ^[0-9]+[GM]$ ]]; then
        log_error "Disk size must look like 32G or 4096M."
        exit 1
    fi
}

create_host_files() {
    local name="$1"
    local target_dir="$REPO_ROOT/hosts/$name"

    mkdir -p "$target_dir"

    cat > "$target_dir/configuration.nix" <<'EOF'
{
  pkgs,
  inputs,
  ...
}: {
  imports = [
    inputs.disko.nixosModules.disko
    ./disko.nix
    ./hardware-configuration.nix
  ];

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
  };

  homelab = {
    ssh = {
      enable = true;
      secure = false;
    };
    tailscale.enable = true;
    nixCaches = {
      enable = true;
      profile = "internal";
    };
    update = {
      enable = true;
      collectGarbage = true;
      trim = true;
      rebootOnKernelUpdate = true;
    };
  };

  # Enable QEMU guest agent for Proxmox integration
  services.qemuGuest.enable = true;

  environment.systemPackages = with pkgs; [
    htop
    vim
    git
    curl
    jq
  ];

  system.stateVersion = "25.05";
}
EOF

    cat > "$target_dir/home.nix" <<'EOF'
{...}: {
  imports = [
    ../../home/home.nix
    ../../home/utils/common.nix
  ];
}
EOF

    cat > "$target_dir/disko.nix" <<'EOF'
{
  disko.devices = {
    disk = {
      main = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
EOF

    cat > "$target_dir/hardware-configuration.nix" <<'EOF'
# Minimal hardware configuration for Proxmox VM
# This will be generated properly by nixos-anywhere during installation
{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  boot = {
    initrd = {
      availableKernelModules = ["ata_piix" "uhci_hcd" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod"];
      kernelModules = [];
    };
    kernelModules = [];
    extraModulePackages = [];
  };

  # Filesystem definitions handled by disko.nix
  # Do not define fileSystems here when using disko

  swapDevices = [];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
EOF
}

append_definition() {
    local name="$1"
    local alias="$2"
    local vmid="$3"
    local cores="$4"
    local memory="$5"
    local disk="$6"
    local storage="$7"
    local purpose="$8"
    local services_input="$9"

    local purpose_escaped
    purpose_escaped="$(escape_nix_string "$purpose")"

    local services_block=""
    if [[ -n "$services_input" ]]; then
        local services_lines=""
        IFS=',' read -r -a service_items <<< "$services_input"
        for service in "${service_items[@]}"; do
            service="$(echo "$service" | sed -e 's/^ *//' -e 's/ *$//')"
            [[ -z "$service" ]] && continue
            service="$(escape_nix_string "$service")"
            services_lines+="        \"${service}\"\n"
        done

        if [[ -n "$services_lines" ]]; then
            services_block=$'      services = [\n'"$services_lines"$'      ];\n'
        fi
    fi

    local new_entry=$'    '"$name"$' = {\n'
    new_entry+=$'      vmid = '"$vmid"$';\n'
    new_entry+=$'      hostname = "'"$name"$'";\n'
    new_entry+=$'      sshAlias = "'"$alias"$'";\n'
    new_entry+=$'      cores = '"$cores"$';\n'
    new_entry+=$'      memory = '"$memory"$'; # MB\n'
    new_entry+=$'      disk = "'"$disk"$'";\n'
    new_entry+=$'      storage = "'"$storage"$'";\n'
    new_entry+=$'      nixosConfig = "'"$name"$'";\n'
    new_entry+=$'      purpose = "'"$purpose_escaped"$'";\n'
    if [[ -n "$services_block" ]]; then
        new_entry+="$services_block"
    fi
    new_entry+=$'    };\n'

    local defs_file="$REPO_ROOT/vms/definitions.nix"
    local temp_file
    temp_file=$(mktemp)

    awk -v entry="$new_entry" '
        $0 ~ /^  managed = \{/ { in_managed = 1 }
        in_managed && $0 ~ /^  \};$/ {
            printf "%s", entry
            in_managed = 0
        }
        { print }
    ' "$defs_file" > "$temp_file"

    mv "$temp_file" "$defs_file"
}

add_hosts_entry() {
    local name="$1"
    local alias="$2"

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
    publicKey = \"ssh-ed25519 PLACEHOLDER\";
    authorizedKeys = masterKeys;
  };
"

    sed '$d' "$hosts_file" > "$temp_file"
    echo "$new_entry" >> "$temp_file"
    echo "}" >> "$temp_file"
    mv "$temp_file" "$hosts_file"
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

    vmid="$(prompt_required "VMID" "$DEFAULT_VMID")"
    ensure_unique_vmid "$vmid"

    local purpose
    purpose="$(prompt_required "Purpose" "General purpose VM")"

    local cores
    cores="$(prompt_required "CPU cores" "$DEFAULT_CORES")"

    local memory
    memory="$(prompt_required "Memory (MB)" "$DEFAULT_MEMORY")"

    local disk
    disk="$(prompt_required "Disk size" "$DEFAULT_DISK")"

    local storage
    storage="$(prompt_required "Storage pool" "$DEFAULT_STORAGE")"

    validate_resource_inputs "$cores" "$memory" "$disk"

    local services
    services="$(prompt_optional "Services (comma-separated, optional)")"

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
    if [[ -n "$services" ]]; then
        echo "  Services: $services"
    fi
    echo ""

    local confirm
    read -r -p "Proceed? [y/N]: " confirm
    case "$confirm" in
        y|Y|yes|YES) ;;
        *) log_warning "Cancelled."; exit 1 ;;
    esac

    log_info "Creating VM definition..."
    append_definition "$name" "$alias" "$vmid" "$cores" "$memory" "$disk" "$storage" "$purpose" "$services"
    log_success "Updated vms/definitions.nix"

    log_info "Creating host configuration..."
    create_host_files "$name"
    log_success "Created hosts/$name"

    log_info "Adding hosts.nix entry..."
    add_hosts_entry "$name" "$alias"
    log_success "Updated hosts.nix"

    log_info "Provisioning on Proxmox..."
    cd "$REPO_ROOT"
    nix run .#provision-vm "$name"
}

main "$@"
