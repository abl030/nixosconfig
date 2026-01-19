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
# 7. Leaves changes unstaged for manual review
#
# Usage: post-provision.sh <vm-name> <vm-ip> <vmid>
#    or: post-provision.sh <vm-name> <vmid>   (uses tofu-output)

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
if git rev-parse --git-dir >/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# Prefer repo-local proxmox-ops.sh when running via nix run (script path in /nix/store).
if [[ -x "$REPO_ROOT/vms/proxmox-ops.sh" ]]; then
    PROXMOX_OPS="$REPO_ROOT/vms/proxmox-ops.sh"
else
    PROXMOX_OPS="$SCRIPT_DIR/proxmox-ops.sh"
fi

require_repo_root() {
    if [[ ! -f "$REPO_ROOT/hosts.nix" ]] || [[ ! -f "$REPO_ROOT/secrets/.sops.yaml" ]]; then
        log_error "Run this from the nixosconfig repo root."
        log_error "Missing files: hosts.nix or secrets/.sops.yaml"
        exit 1
    fi
}

resolve_vm_ip() {
    local vm_name="$1"
    local vm_ip="$2"

    if [[ -n "$vm_ip" && "$vm_ip" != "-" ]]; then
        echo "$vm_ip"
        return 0
    fi

    if ! command -v nix >/dev/null 2>&1; then
        log_error "nix is required to resolve IP via tofu-output."
        return 1
    fi

    local workdir="${TOFU_WORKDIR:-$REPO_ROOT/vms/tofu/.state}"
    local output_name="${vm_name}_ip"
    local ip

    log_info "Resolving IP from OpenTofu output: ${output_name}" >&2
    if ! ip=$(TOFU_WORKDIR="$workdir" nix run .#tofu-output -- -raw "$output_name" 2>/dev/null); then
        log_error "Failed to read tofu output '${output_name}'."
        log_error "Ensure the VM is managed by OpenTofu and state is present."
        return 1
    fi

    if [[ -z "$ip" ]]; then
        log_error "tofu output '${output_name}' is empty."
        return 1
    fi

    echo "$ip"
}

build_ssh_opts() {
    local -n out="$1"
    local opts_str="${POST_PROVISION_SSH_OPTS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes}"

    out=()
    read -r -a out <<< "$opts_str"

    # Add sane timeouts if not already provided.
    if [[ "$opts_str" != *"ConnectTimeout"* ]]; then
        out+=("-o" "ConnectTimeout=10")
    fi
    if [[ "$opts_str" != *"ServerAliveInterval"* ]]; then
        out+=("-o" "ServerAliveInterval=5")
    fi
    if [[ "$opts_str" != *"ServerAliveCountMax"* ]]; then
        out+=("-o" "ServerAliveCountMax=3")
    fi

    if [[ -n "${POST_PROVISION_IDENTITY_FILE:-}" ]]; then
        out+=("-i" "$POST_PROVISION_IDENTITY_FILE" "-o" "IdentitiesOnly=yes")
    fi
}

resolve_host_config_dir() {
    local vm_name="$1"

    if ! command -v nix >/dev/null 2>&1; then
        return 1
    fi

    local config_path
    if ! config_path=$(nix eval --raw --impure --expr "let hosts = import $REPO_ROOT/hosts.nix; in toString hosts.${vm_name}.configurationFile" 2>/dev/null); then
        return 1
    fi

    if [[ -z "$config_path" ]]; then
        return 1
    fi

    dirname "$config_path"
}

ensure_hardware_config() {
    local vm_name="$1"
    local vm_ip="$2"
    local ssh_user="${3:-root}"
    local -a ssh_opts
    build_ssh_opts ssh_opts

    local config_dir
    if ! config_dir=$(resolve_host_config_dir "$vm_name"); then
        log_error "Failed to locate host config dir for ${vm_name}"
        return 1
    fi

    local hw_file="${config_dir}/hardware-configuration.nix"
    if [[ -f "$hw_file" && "${POST_PROVISION_FORCE_HW_CONFIG:-}" != "1" ]]; then
        log_info "hardware-configuration.nix already exists."
        log_info "Set POST_PROVISION_FORCE_HW_CONFIG=1 to regenerate." >&2
        if [[ "${POST_PROVISION_HW_CONFIG_PROMPT:-1}" == "1" ]]; then
            if [[ -t 0 ]]; then
                read -r -p "Overwrite hardware-configuration.nix? [y/N] " reply
                case "$reply" in
                    y|Y|yes|YES)
                        log_warning "Overwriting hardware-configuration.nix as requested." >&2
                        ;;
                    *)
                        log_info "Keeping existing hardware-configuration.nix." >&2
                        return 0
                        ;;
                esac
            else
                log_info "Non-interactive session; keeping existing hardware-configuration.nix." >&2
                return 0
            fi
        else
            log_info "Prompt disabled; keeping existing hardware-configuration.nix." >&2
            return 0
        fi
    fi

    log_info "Generating hardware-configuration.nix from VM..."
    if ! ssh "${ssh_opts[@]}" "${ssh_user}@${vm_ip}" "nixos-generate-config --show-hardware-config" >"$hw_file"; then
        log_error "Failed to generate hardware-configuration.nix from ${vm_ip}"
        log_error "Ensure SSH key auth works or set POST_PROVISION_IDENTITY_FILE."
        return 1
    fi

    log_success "hardware-configuration.nix written to ${hw_file}"

    if git rev-parse --git-dir >/dev/null 2>&1; then
        for file in "$config_dir/configuration.nix" "$config_dir/home.nix" "$hw_file"; do
            if [[ -f "$file" ]]; then
                git add "$file"
            fi
        done
    fi
}

stage_host_config() {
    local vm_name="$1"

    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi

    local config_dir
    if ! config_dir=$(resolve_host_config_dir "$vm_name"); then
        return 1
    fi

    for file in "$config_dir/configuration.nix" "$config_dir/home.nix" "$config_dir/hardware-configuration.nix"; do
        if [[ -f "$file" ]]; then
            git add "$file"
        fi
    done
}

apply_nixos_config() {
    local vm_name="$1"
    local vm_ip="$2"
    local vmid="$3"

    if [[ "${POST_PROVISION_SKIP_REBUILD:-}" == "1" ]]; then
        log_warning "Skipping nixos-rebuild (POST_PROVISION_SKIP_REBUILD=1)" >&2
        echo "$vm_ip"
        return 0
    fi

    local ssh_user="${POST_PROVISION_REBUILD_USER:-root}"
    local -a ssh_opts
    build_ssh_opts ssh_opts
    local ssh_opts_str="${ssh_opts[*]}"

    log_info "Applying NixOS config via nixos-rebuild..." >&2
    log_info "(SSH may drop when networking restarts - this is expected)" >&2

    # Run nixos-rebuild in background so we can monitor the old IP
    NIX_SSHOPTS="$ssh_opts_str" nixos-rebuild switch --flake "$REPO_ROOT#${vm_name}" --target-host "${ssh_user}@${vm_ip}" &
    local rebuild_pid=$!

    # Monitor: wait for either rebuild to finish or old IP to go away
    # Require multiple consecutive failed pings to avoid false positives
    local rebuild_rc=0
    local ip_dropped=0
    local consecutive_fails=0
    local fail_threshold=5  # 5 consecutive failures = ~5-10 seconds of unreachability
    while kill -0 "$rebuild_pid" 2>/dev/null; do
        # Check if old IP is still reachable (1 ping, 1 second timeout)
        if ! ping -c1 -W1 "$vm_ip" >/dev/null 2>&1; then
            ((consecutive_fails++))
            if [[ "$consecutive_fails" -ge "$fail_threshold" ]]; then
                # IP unreachable for several seconds - network likely restarted
                ip_dropped=1
                log_warning "Old IP ($vm_ip) unreachable for ${consecutive_fails}s - network restarted" >&2
                log_info "Killing hanging nixos-rebuild process..." >&2
                kill "$rebuild_pid" 2>/dev/null || true
                wait "$rebuild_pid" 2>/dev/null || true
                break
            fi
        else
            consecutive_fails=0  # Reset on successful ping
        fi
        sleep 1
    done

    # If we didn't detect IP drop, get the actual exit code
    if [[ "$ip_dropped" -eq 0 ]]; then
        wait "$rebuild_pid" || rebuild_rc=$?
        if [[ "$rebuild_rc" -ne 0 ]]; then
            log_warning "nixos-rebuild exited with code $rebuild_rc" >&2
        fi
    fi

    # Give the VM time to finish the switch and acquire new IP
    # Retry getting IP with timeout - VM needs time to finish switch and get DHCP lease
    log_info "Waiting for VM to complete switch and acquire new IP..." >&2
    local new_ip=""
    local ip_timeout="${POST_PROVISION_IP_TIMEOUT:-300}"
    local ip_start
    ip_start=$(date +%s)

    log_info "Retrying IP resolution (get-ip may take ~10s; timeout: ${ip_timeout}s)..." >&2
    while true; do
        new_ip=$("$PROXMOX_OPS" get-ip "$vmid" 2>/dev/null) || true
        if [[ -n "$new_ip" ]]; then
            break
        fi

        local now
        now=$(date +%s)
        if (( now - ip_start >= ip_timeout )); then
            log_error "Timeout waiting for new IP (${ip_timeout}s)" >&2
            return 1
        fi

        sleep 2
    done

    if [[ "$new_ip" != "$vm_ip" ]]; then
        log_info "VM IP changed: $vm_ip -> $new_ip" >&2
    fi

    # Wait for SSH on the (possibly new) IP
    local wait_user="${POST_PROVISION_WAIT_USER:-abl030}"
    if ! wait_for_ssh "$new_ip" "$wait_user" "${POST_PROVISION_WAIT_TIMEOUT:-300}"; then
        log_error "SSH not available on $new_ip after rebuild" >&2
        return 1
    fi

    log_success "NixOS config applied, VM accessible at $new_ip" >&2
    echo "$new_ip"
}

wait_for_ssh() {
    local vm_ip="$1"
    local ssh_user="${2:-abl030}"
    local timeout="${3:-300}"
    local -a ssh_opts
    build_ssh_opts ssh_opts

    log_info "Waiting for SSH on ${ssh_user}@${vm_ip} (timeout ${timeout}s)..." >&2

    local start_time
    start_time=$(date +%s)

    while true; do
        if ssh "${ssh_opts[@]}" "${ssh_user}@${vm_ip}" "true" >/dev/null 2>&1; then
            log_success "SSH ready for ${ssh_user}@${vm_ip}" >&2
            return 0
        fi

        local now
        now=$(date +%s)
        if (( now - start_time >= timeout )); then
            log_error "Timeout waiting for SSH on ${ssh_user}@${vm_ip}" >&2
            return 1
        fi

        sleep 2
    done
}

resolve_sops_identity() {
    if [[ -n "${SOPS_AGE_KEY_FILE:-}" || -n "${SOPS_AGE_SSH_PRIVATE_KEY_FILE:-}" || -n "${SOPS_AGE_KEY:-}" ]]; then
        return 0
    fi

    local uid
    uid="$(id -u)"

    if [[ "$uid" -ne 0 ]]; then
        if ! sudo -v; then
            log_error "Failed to obtain sudo credentials for SOPS decryption." >&2
            return 1
        fi
    fi

    # 1) Age key files
    for keyfile in "/root/.config/sops/age/keys.txt" "/var/lib/sops-nix/key.txt"; do
        if sudo test -r "$keyfile" 2>/dev/null; then
            if [[ "$uid" -eq 0 ]]; then
                export SOPS_AGE_KEY_FILE="$keyfile"
            else
                local tmp_key
                tmp_key="$(mktemp -t post-provision-sops-XXXXXX.age)"
                # shellcheck disable=SC2024
                sudo cat "$keyfile" | tee "$tmp_key" >/dev/null
                chmod 600 "$tmp_key"
                export SOPS_AGE_KEY_FILE="$tmp_key"
            fi
            return 0
        fi
    done

    # 2) Host SSH key
    if sudo test -r /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
        if age_key=$(sudo ssh-to-age -private-key -i /etc/ssh/ssh_host_ed25519_key 2>/dev/null); then
            export SOPS_AGE_KEY="$age_key"
            return 0
        fi
    fi

    # 3) User SSH key
    local sshkey="$HOME/.ssh/id_ed25519"
    if [[ -r "$sshkey" ]]; then
        if age_key=$(ssh-to-age -private-key -i "$sshkey" 2>/dev/null); then
            export SOPS_AGE_KEY="$age_key"
            return 0
        fi
    fi

    log_error "No valid SOPS age key found."
    log_error "Set SOPS_AGE_KEY or SOPS_AGE_KEY_FILE and retry."
    return 1
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=()

    command -v ssh >/dev/null 2>&1 || missing+=("ssh")
    command -v nix >/dev/null 2>&1 || missing+=("nix")
    command -v ssh-to-age >/dev/null 2>&1 || missing+=("ssh-to-age")
    command -v sops >/dev/null 2>&1 || missing+=("sops")
    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v nixos-rebuild >/dev/null 2>&1 || missing+=("nixos-rebuild")
    if [[ "${POST_PROVISION_TAILSCALE:-1}" != "0" ]]; then
        command -v curl >/dev/null 2>&1 || missing+=("curl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        log_info "Install missing tools:"
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                nix)
                    log_info "  install Nix before running post-provision"
                    ;;
                ssh-to-age)
                    log_info "  nix profile install nixpkgs#ssh-to-age"
                    ;;
                sops)
                    log_info "  nix profile install nixpkgs#sops"
                    ;;
                nixos-rebuild)
                    log_info "  nix profile install nixpkgs#nixos-rebuild"
                    ;;
                curl)
                    log_info "  nix profile install nixpkgs#curl"
                    ;;
            esac
        done
        return 1
    fi

    log_success "All prerequisites met"
}

tailscale_load_oauth_creds() {
    if [[ -n "${TAILSCALE_OAUTH_CLIENT_ID:-}" && -n "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" && -n "${TAILSCALE_TAILNET:-}" ]]; then
        return 0
    fi

    # Default to standard location if not specified
    local sops_file="${POST_PROVISION_TAILSCALE_SOPS_FILE:-$REPO_ROOT/secrets/tailscale-oauth.yaml}"
    if [[ ! -f "$sops_file" ]]; then
        log_error "Tailscale OAuth credentials not found at: $sops_file" >&2
        return 1
    fi

    if ! command -v sops >/dev/null 2>&1; then
        return 1
    fi

    # Ensure we have a sops identity to decrypt
    if ! resolve_sops_identity; then
        log_error "Failed to resolve SOPS identity for decryption" >&2
        return 1
    fi

    local json
    if ! json=$(sops -d --output-type json "$sops_file"); then
        return 1
    fi

    TAILSCALE_OAUTH_CLIENT_ID=$(echo "$json" | jq -r '.oauth_client_id // empty')
    TAILSCALE_OAUTH_CLIENT_SECRET=$(echo "$json" | jq -r '.oauth_client_secret // empty')
    TAILSCALE_TAILNET=$(echo "$json" | jq -r '.tailnet // empty')
    TAILSCALE_TAGS=${TAILSCALE_TAGS:-$(echo "$json" | jq -r '.tags // empty | join(",")')}
    TAILSCALE_KEY_EXPIRY_SECONDS=${TAILSCALE_KEY_EXPIRY_SECONDS:-$(echo "$json" | jq -r '.expiry_seconds // empty')}

    if [[ -n "$TAILSCALE_OAUTH_CLIENT_ID" && -n "$TAILSCALE_OAUTH_CLIENT_SECRET" && -n "$TAILSCALE_TAILNET" ]]; then
        return 0
    fi

    return 1
}

tailscale_create_auth_key() {
    if [[ -z "${TAILSCALE_OAUTH_CLIENT_ID:-}" || -z "${TAILSCALE_OAUTH_CLIENT_SECRET:-}" || -z "${TAILSCALE_TAILNET:-}" ]]; then
        if ! tailscale_load_oauth_creds; then
            log_error "Missing Tailscale OAuth credentials or tailnet." >&2
            log_error "Set TAILSCALE_OAUTH_CLIENT_ID/SECRET and TAILSCALE_TAILNET, or POST_PROVISION_TAILSCALE_SOPS_FILE." >&2
            return 1
        fi
    fi

    local expiry="${TAILSCALE_KEY_EXPIRY_SECONDS:-600}"
    local tags_json="[]"
    if [[ -n "${TAILSCALE_TAGS:-}" ]]; then
        tags_json=$(printf '%s\n' "$TAILSCALE_TAGS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF' | jq -R . | jq -s .)
    fi

    local token
    token=$(curl -sSf -u "${TAILSCALE_OAUTH_CLIENT_ID}:${TAILSCALE_OAUTH_CLIENT_SECRET}" \
        -d "grant_type=client_credentials" \
        "https://api.tailscale.com/api/v2/oauth/token" | jq -r '.access_token')
    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Failed to obtain Tailscale OAuth token." >&2
        return 1
    fi

    local payload
    payload=$(jq -n \
        --argjson tags "$tags_json" \
        --argjson expiry "$expiry" \
        '{
          capabilities: {
            devices: {
              create: {
                reusable: false,
                ephemeral: true,
                preauthorized: true,
                tags: $tags
              }
            }
          },
          expirySeconds: $expiry
        }')

    local key
    key=$(curl -sSf \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "https://api.tailscale.com/api/v2/tailnet/${TAILSCALE_TAILNET}/keys" | jq -r '.key')

    if [[ -z "$key" || "$key" == "null" ]]; then
        log_error "Failed to create Tailscale auth key." >&2
        return 1
    fi

    echo "$key"
}

tailscale_join_vm() {
    local vm_ip="$1"

    if [[ "${POST_PROVISION_TAILSCALE:-1}" == "0" ]]; then
        log_info "Skipping Tailscale enrollment (POST_PROVISION_TAILSCALE=0)" >&2
        return 0
    fi

    log_info "Step: tailscale enroll" >&2

    local key
    if ! key=$(tailscale_create_auth_key); then
        return 1
    fi

    local -a ssh_opts
    build_ssh_opts ssh_opts
    # tailscale up requires sudo; force a TTY so sudo can prompt interactively.
    ssh_opts+=("-t" "-o" "BatchMode=no")

    log_info "Enrolling VM into tailnet via tailscale up..." >&2
    # shellcheck disable=SC2029
    if ! ssh "${ssh_opts[@]}" "abl030@$vm_ip" "sudo tailscale up --authkey \"$key\""; then
        log_error "tailscale up failed on ${vm_ip}" >&2
        return 1
    fi

    log_success "Tailscale enrollment complete" >&2
}

# Extract SSH host key from VM
extract_ssh_host_key() {
    local vm_ip="$1"

    log_info "Extracting SSH host key from $vm_ip..." >&2

    # SSH options for non-interactive use (as array to avoid quoting issues)
    local -a ssh_opts
    build_ssh_opts ssh_opts
    ssh_opts+=(-o LogLevel=ERROR)

    # Extract the ed25519 public key (use abl030 user, public key is world-readable)
    local ssh_key
    if ! ssh_key=$(ssh "${ssh_opts[@]}" "abl030@$vm_ip" "cat /etc/ssh/ssh_host_ed25519_key.pub" 2>/dev/null); then
        log_error "Failed to extract SSH host key"
        log_error "Make sure the VM is running and accessible via: ssh abl030@$vm_ip"
        return 1
    fi

    # Validate key format
    if ! echo "$ssh_key" | grep -q "^ssh-ed25519 "; then
        log_error "Invalid SSH key format: $ssh_key"
        return 1
    fi

    log_success "SSH host key extracted" >&2
    echo "$ssh_key"
}

# Convert SSH key to age key
ssh_to_age_key() {
    local ssh_key="$1"

    log_info "Converting SSH key to age key..." >&2

    local age_key
    # ssh-to-age outputs to stdout, errors to stderr
    if ! age_key=$(echo "$ssh_key" | ssh-to-age); then
        log_error "Failed to convert SSH key to age key"
        log_error "Input was: $ssh_key"
        return 1
    fi

    if [[ -z "$age_key" ]]; then
        log_error "ssh-to-age returned empty result"
        return 1
    fi

    log_success "Age key generated: $age_key" >&2
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

    local existing_alias=""
    local existing_hash=""
    if grep -q "^  $vm_name = {" "$hosts_file"; then
        existing_alias=$(awk -v name="$vm_name" '
            $0 ~ "^  "name" = \\{" {in_entry=1}
            in_entry {
                if (match($0, /sshAlias = "([^"]+)"/, m)) {
                    print m[1]
                    exit
                }
            }
            in_entry && /^  \};/ {in_entry=0}
        ' "$hosts_file")

        existing_hash=$(awk -v name="$vm_name" '
            $0 ~ "^  "name" = \\{" {in_entry=1}
            in_entry {
                if (match($0, /initialHashedPassword = "([^"]+)"/, m)) {
                    print m[1]
                    exit
                }
            }
            in_entry && /^  \};/ {in_entry=0}
        ' "$hosts_file")
    fi

    local ssh_alias="${existing_alias:-$vm_name}"
    local hash_line=""
    if [[ -n "$existing_hash" ]]; then
        hash_line="    initialHashedPassword = \"$existing_hash\";\n"
    fi

    # Create the new entry
    local new_entry="
  $vm_name = {
    configurationFile = ./hosts/$vm_name/configuration.nix;
    homeFile = ./hosts/$vm_name/home.nix;
    user = \"abl030\";
    homeDirectory = \"/home/abl030\";
    hostname = \"$vm_name\";
    sshAlias = \"$ssh_alias\";
    sshKeyName = \"ssh_key_abl030\";
${hash_line}    publicKey = \"ssh-ed25519 $key_part\";
    authorizedKeys = masterKeys;
  };
"

    # Check if entry already exists
    if grep -q "^  $vm_name = {" "$hosts_file"; then
        log_warning "Entry for '$vm_name' already exists in hosts.nix"
        log_info "Updating publicKey in existing entry..."

        local temp_file
        temp_file=$(mktemp)

        awk -v name="$vm_name" -v key="ssh-ed25519 $key_part" '
            $0 ~ "^  "name" = \\{" {in_entry=1}
            in_entry && $0 ~ /publicKey = "/ {
                sub(/publicKey = "ssh-ed25519 [^"]+";/, "publicKey = \"" key "\";")
                updated=1
            }
            in_entry && /^  \};/ {
                if (!updated) {
                    print "    publicKey = \"" key "\";"
                }
                in_entry=0
            }
            { print }
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

    local sops_file="$REPO_ROOT/secrets/.sops.yaml"

    if [[ ! -f "$sops_file" ]]; then
        log_error ".sops.yaml not found at $sops_file"
        return 1
    fi

    # Check if age key already exists
    if grep -q "$age_key" "$sops_file"; then
        log_warning "Age key for '$vm_name' already exists in .sops.yaml"
        return 0
    fi

    # Add the age key to the age: list under key_groups:
    # Format: "          - &vm-name age1... # vm-name"
    local temp_file
    temp_file=$(mktemp)

    # Find the age: list and add the new key at the end
    awk -v key="$age_key" -v name="$vm_name" '
        /^          - age1/ || /^          - &/ {
            # Inside the age key list - track last line
            last_age_line = NR
            age_lines[NR] = $0
        }
        {
            lines[NR] = $0
        }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (i == last_age_line) {
                    # Add new key after the last age key
                    print "          - &" name " " key " # " name
                }
            }
        }
    ' "$sops_file" > "$temp_file"

    mv "$temp_file" "$sops_file"

    log_success ".sops.yaml updated"
}

# Re-encrypt all secrets
reencrypt_secrets() {
    log_info "Re-encrypting all secrets with new key..."

    local secrets_dir="$REPO_ROOT/secrets"
    local sops_config="$secrets_dir/.sops.yaml"

    if [[ ! -d "$secrets_dir" ]]; then
        log_warning "No secrets directory found at $secrets_dir"
        return 0
    fi

    local failed=0

    if ! resolve_sops_identity; then
        return 1
    fi

    # Update all secret files using explicit config path
    while read -r secret_file; do
        log_info "Updating keys for $(basename "$secret_file")..."
        if ! sops --config "$sops_config" updatekeys --yes "$secret_file"; then
            log_error "Failed to re-encrypt: $secret_file"
            failed=1
        fi
    done < <(find "$secrets_dir" -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.env" -o -name "ssh_key_*" \))

    if [[ "$failed" -ne 0 ]]; then
        log_error "Secrets re-encryption failed."
        return 1
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

# Main post-provisioning workflow
post_provision() {
    local vm_name="$1"
    local vm_ip="$2"
    local vmid="$3"

    log_info "Starting post-provisioning for: $vm_name"
    log_info "  IP: $vm_ip"
    log_info "  VMID: $vmid"
    echo ""

    if ! ensure_hardware_config "$vm_name" "$vm_ip" "root"; then
        return 1
    fi
    stage_host_config "$vm_name"

    # Apply NixOS config to the blank VM
    # Note: VM IP may change during rebuild due to DHCP
    local new_ip
    if ! new_ip=$(apply_nixos_config "$vm_name" "$vm_ip" "$vmid"); then
        return 1
    fi

    # Update vm_ip if it changed
    if [[ -n "$new_ip" && "$new_ip" != "$vm_ip" ]]; then
        log_info "Using new IP: $new_ip"
        vm_ip="$new_ip"
    fi

    if ! tailscale_join_vm "$vm_ip"; then
        return 1
    fi

    # Extract SSH host key
    local ssh_key
    log_info "Step: extract SSH host key" >&2
    if ! ssh_key=$(extract_ssh_host_key "$vm_ip"); then
        return 1
    fi

    # Convert to age key
    local age_key
    log_info "Step: convert SSH key to age key" >&2
    if ! age_key=$(ssh_to_age_key "$ssh_key"); then
        return 1
    fi

    # Update hosts.nix
    log_info "Step: update hosts.nix" >&2
    if ! update_hosts_nix "$vm_name" "$ssh_key" "$vmid"; then
        return 1
    fi

    # Update .sops.yaml
    log_info "Step: update .sops.yaml" >&2
    if ! update_sops_yaml "$vm_name" "$age_key"; then
        return 1
    fi

    # Re-encrypt secrets
    log_info "Step: re-encrypt secrets" >&2
    if ! reencrypt_secrets; then
        return 1
    fi

    # Update documentation
    log_info "Step: update documentation" >&2
    update_documentation "$vm_name" "$vmid"

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
    log_info ""
    log_info "Current VM IP: $vm_ip"
}

# Main entry point
main() {
    if [[ $# -lt 2 || $# -gt 3 ]]; then
        echo "Usage: $0 <vm-name> <vm-ip> <vmid>"
        echo "   or: $0 <vm-name> <vmid>"
        echo ""
        echo "Examples:"
        echo "  $0 test-vm 192.168.1.50 110"
        echo "  $0 test-vm 110"
        echo ""
        echo "This script should be run after NixOS is installed on the VM"
        return 1
    fi

    local vm_name="$1"
    local vm_ip=""
    local vmid=""

    if [[ $# -eq 2 ]]; then
        vmid="$2"
    else
        vm_ip="$2"
        vmid="$3"
    fi

    # Check prerequisites
    if ! check_prerequisites; then
        return 1
    fi

    require_repo_root

    # Change to repo root
    cd "$REPO_ROOT"

    # Resolve VM IP if needed (via tofu-output)
    if ! vm_ip="$(resolve_vm_ip "$vm_name" "$vm_ip")"; then
        return 1
    fi

    # Run post-provisioning
    post_provision "$vm_name" "$vm_ip" "$vmid"
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
