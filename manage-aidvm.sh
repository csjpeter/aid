#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVM_DIR="$SCRIPT_DIR/kvm"
CONFIG_DIR="$HOME/.config/aid"

source "$KVM_DIR/kvm-include.sh"

# ── CLI option defaults ─────────────────────────────────────────────────────────

BATCH=false
CLI_VM_NAME=""
CLI_BASE_IMAGE=""
CLI_VCPUS=""
CLI_RAM=""
CLI_DISK_SIZE=""
CLI_ADMIN_USER=""
CLI_KVM_HOST=""
CLI_NETWORK=""
CLI_NETWORK_CIDR=""
CLI_IP=""
CLI_GITHUB_PAT=""
CLI_CLAUDE_API_KEY=""

# ── Prompt helpers ─────────────────────────────────────────────────────────────

# ask <msg> <default> <varname> [cli_val]
# Skips prompt when BATCH=true or cli_val is non-empty; just logs the value.
ask() {
    local msg="$1" default="$2" varname="$3" cli_val="${4:-}"
    if [ "$BATCH" = "true" ] || [ -n "$cli_val" ]; then
        printf -v "$varname" '%s' "$default"
        log_info "$msg: $default"
        return
    fi
    local input
    read -rp "$(echo -e "${GREEN}?${NC} $msg [${default}]: ")" input
    printf -v "$varname" '%s' "${input:-$default}"
}

ask_optional() {
    # ask_optional <msg> <varname>  — empty default, no brackets shown
    local msg="$1" varname="$2"
    local input
    read -rp "$(echo -e "${GREEN}?${NC} $msg: ")" input
    printf -v "$varname" '%s' "$input"
}

ask_secret() {
    # ask_secret <msg> <varname>
    local msg="$1" varname="$2"
    local input
    read -rsp "$(echo -e "${GREEN}?${NC} $msg: ")" input
    echo
    printf -v "$varname" '%s' "$input"
}

# choose <msg> <default> <varname> <cli_val> <option1> [option2 ...]
# Skips prompt when BATCH=true or cli_val is non-empty; just logs the value.
choose() {
    local msg="$1" default="$2" varname="$3" cli_val="${4:-}"
    shift 4
    local options=("$@")
    if [ "$BATCH" = "true" ] || [ -n "$cli_val" ]; then
        printf -v "$varname" '%s' "$default"
        log_info "$msg: $default"
        return
    fi
    echo -e "${GREEN}?${NC} $msg"
    local i
    for i in "${!options[@]}"; do
        local mark=""
        [ "${options[$i]}" == "$default" ] && mark=" ${GREEN}(default)${NC}"
        echo -e "  $((i+1))) ${options[$i]}${mark}"
    done
    local input
    read -rp "  Enter number or value [${default}]: " input
    if [ -z "$input" ]; then
        printf -v "$varname" '%s' "$default"
    elif [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le "${#options[@]}" ]; then
        printf -v "$varname" '%s' "${options[$((input-1))]}"
    else
        printf -v "$varname" '%s' "$input"
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────────

suggest_vm_name() {
    if ! command -v virsh &>/dev/null && ! sudo virsh --version &>/dev/null 2>&1; then
        echo "aidvm2"
        return
    fi
    local n=2  # .1 is reserved for the network gateway
    while sudo virsh dominfo "aidvm$n" &>/dev/null 2>&1; do
        ((n++))
    done
    echo "aidvm$n"
}

list_networks() {
    sudo virsh net-list --all --name 2>/dev/null | grep -v '^$' || true
}

get_network_prefix() {
    local network="$1"
    local xml gw
    xml=$(sudo virsh net-dumpxml "$network" 2>/dev/null) || { echo ""; return; }
    gw=$(echo "$xml" | grep -oP "ip address=['\"]\\K[^'\"]+") || { echo ""; return; }
    if [[ "$gw" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\. ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo ""
    fi
}

print_help_main() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Manage KVM-based AI developer VMs.

Commands:
  create          Collect config, create, and provision a new VM
  list            List all configured VMs with their IP address and virsh status
  delete          Stop and permanently delete a VM and its disk (config preserved)
  help [command]  Show this help, or detailed help for a command (default)

Use '$(basename "$0") <command> --help' for the same per-command help.

EOF
}

print_help_create() {
    cat <<EOF
Usage: $(basename "$0") create [OPTIONS]

Collect config, create, and provision a new AI dev VM.
If a saved config exists for the VM name it is loaded as defaults.
CLI options override saved config. Config is updated on each run.

Options:
  --vm-name=<name>          VM name (default: aidvmN, N≥2)
  --base-image=<image>      Base OS image: ubuntu24 ubuntu22 ubuntu20 rocky9 debian12
                              (default: ubuntu24)
  --vcpus=<n>               Number of vCPUs (default: 4)
  --ram=<size>              RAM, e.g. 32G (default: 32G)
  --disk-size=<size>        Disk size, e.g. 200G (default: 200G)
  --admin-user=<user>       Admin username on the VM (default: \$USER)
  --kvm-host=<host>         'local' or remote hostname (default: local)
  --network=<name>          Libvirt network name (default: first available)
  --network-cidr=<cidr>     Create network with this CIDR if it doesn't exist yet
  --ip=<ip>                 VM IP address (default: derived from VM name suffix)
  --github-pat=<token>      GitHub fine-grained PAT for gh auth
  --claude-api-key=<key>    Anthropic API key written to ~/.bashrc on the VM
  --batch                   Non-interactive: use defaults/config/CLI values only

VM naming:
  Default name follows the pattern aidvmN (N starting at 2).
  The VM IP last octet is derived from N (aidvm3 → x.x.x.3).
  Suffix 1 is forbidden — reserved for the network gateway.

Config:
  Saved to ~/.config/aid/<vm-name>.conf (chmod 600).

Examples:
  $(basename "$0") create
  $(basename "$0") create --vm-name=aidvm3 --vcpus=8 --ram=64G
  $(basename "$0") create --batch --vm-name=aidvm3 \\
      --network=net100 --ip=192.168.100.3 --github-pat=<token>

EOF
}

print_help_list() {
    cat <<EOF
Usage: $(basename "$0") list

List all VMs configured in ~/.config/aid/ with their IP address
and current virsh status.

Examples:
  $(basename "$0") list

EOF
}

print_help_delete() {
    cat <<EOF
Usage: $(basename "$0") delete [vm-name] [OPTIONS]

Stop and permanently delete a VM and its disk image.
The config file (~/.config/aid/<vm-name>.conf) is preserved.

Options:
  --vm-name=<name>   VM to delete (alternative to positional argument)
  --batch            Skip the confirmation prompt

Examples:
  $(basename "$0") delete aidvm2
  $(basename "$0") delete --vm-name=aidvm2
  $(basename "$0") delete --vm-name=aidvm2 --batch

EOF
}

# ── Sub-commands ───────────────────────────────────────────────────────────────

cmd_list() {
    local conf_dir="$HOME/.config/aid"
    local confs=()
    if [ -d "$conf_dir" ]; then
        mapfile -t confs < <(compgen -G "$conf_dir/*.conf" 2>/dev/null || true)
    fi
    if [ "${#confs[@]}" -eq 0 ]; then
        log_info "No VMs configured in $conf_dir."
        return 0
    fi
    printf "%-22s %-18s %s\n" "VM NAME" "IP ADDRESS" "STATUS"
    printf "%-22s %-18s %s\n" "-------" "----------" "------"
    local conf VM_NAME VM_IP status
    for conf in "${confs[@]}"; do
        VM_NAME="" VM_IP=""
        # shellcheck disable=SC1090
        source "$conf"
        status=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "not found")
        printf "%-22s %-18s %s\n" "$VM_NAME" "$VM_IP" "$status"
    done
}

cmd_delete() {
    local vm_name="${1:-}"
    local batch="${2:-false}"

    if [ -z "$vm_name" ]; then
        if [ "$batch" = "true" ]; then
            log_error "No VM name specified. Use --vm-name=<name> or pass as argument."
            exit 1
        fi
        cmd_list
        echo
        ask_optional "VM name to delete" vm_name
    fi
    if [ -z "$vm_name" ]; then
        log_error "No VM name specified."
        exit 1
    fi

    if ! sudo virsh dominfo "$vm_name" &>/dev/null; then
        log_error "VM '$vm_name' not found in libvirt."
        exit 1
    fi

    if [ "$batch" = "true" ]; then
        log_warning "Deleting VM '$vm_name' and its disk image (--batch)."
    else
        log_warning "This will permanently delete VM '$vm_name' and its disk image."
        local confirm
        read -rp "$(echo -e "${YELLOW}?${NC} Type the VM name to confirm: ")" confirm
        if [ "$confirm" != "$vm_name" ]; then
            log_info "Aborted."
            exit 0
        fi
    fi

    local vm_ip=""
    local conf="$CONFIG_DIR/${vm_name}.conf"
    [ -f "$conf" ] && vm_ip=$(grep '^VM_IP=' "$conf" | cut -d'"' -f2)

    local state
    state=$(sudo virsh domstate "$vm_name" 2>/dev/null || true)
    if [ "$state" = "running" ]; then
        log_info "Stopping $vm_name..."
        sudo virsh destroy "$vm_name"
    fi

    log_info "Removing VM $vm_name and its disk..."
    sudo virsh undefine "$vm_name" --remove-all-storage

    log_info "Removing $vm_name from /etc/hosts..."
    sudo sed -i "/ ${vm_name}$/d" /etc/hosts

    log_info "Removing $vm_name from ~/.ssh/known_hosts..."
    ssh-keygen -R "$vm_name" 2>/dev/null || true
    [ -n "$vm_ip" ] && { ssh-keygen -R "$vm_ip" 2>/dev/null || true; }

    log_info "Done. Config preserved at $conf — run './$(basename "$0") create' to rebuild."
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONF
VM_NAME="$VM_NAME"
VM_BASE_IMAGE="$VM_BASE_IMAGE"
VM_IP="$VM_IP"
VM_VCPUS="$VM_VCPUS"
VM_RAM="$VM_RAM"
VM_DISK_SIZE="$VM_DISK_SIZE"
VM_ADMIN_USER="$VM_ADMIN_USER"
KVM_HOST="$KVM_HOST"
LIBVIRT_NETWORK="$LIBVIRT_NETWORK"
GITHUB_PAT="$GITHUB_PAT"
CLAUDE_API_KEY="$CLAUDE_API_KEY"
CONF
    chmod 600 "$CONFIG_FILE"
    log_info "Config saved: $CONFIG_FILE"
}

# ── Option parsing ─────────────────────────────────────────────────────────────

SHOW_HELP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)            SHOW_HELP=true ;;
        --batch)              BATCH=true ;;
        --vm-name=*)          CLI_VM_NAME="${1#*=}" ;;
        --vm-name)            CLI_VM_NAME="$2"; shift ;;
        --base-image=*)       CLI_BASE_IMAGE="${1#*=}" ;;
        --base-image)         CLI_BASE_IMAGE="$2"; shift ;;
        --vcpus=*)            CLI_VCPUS="${1#*=}" ;;
        --vcpus)              CLI_VCPUS="$2"; shift ;;
        --ram=*)              CLI_RAM="${1#*=}" ;;
        --ram)                CLI_RAM="$2"; shift ;;
        --disk-size=*)        CLI_DISK_SIZE="${1#*=}" ;;
        --disk-size)          CLI_DISK_SIZE="$2"; shift ;;
        --admin-user=*)       CLI_ADMIN_USER="${1#*=}" ;;
        --admin-user)         CLI_ADMIN_USER="$2"; shift ;;
        --kvm-host=*)         CLI_KVM_HOST="${1#*=}" ;;
        --kvm-host)           CLI_KVM_HOST="$2"; shift ;;
        --network=*)          CLI_NETWORK="${1#*=}" ;;
        --network)            CLI_NETWORK="$2"; shift ;;
        --network-cidr=*)     CLI_NETWORK_CIDR="${1#*=}" ;;
        --network-cidr)       CLI_NETWORK_CIDR="$2"; shift ;;
        --ip=*)               CLI_IP="${1#*=}" ;;
        --ip)                 CLI_IP="$2"; shift ;;
        --github-pat=*)       CLI_GITHUB_PAT="${1#*=}" ;;
        --github-pat)         CLI_GITHUB_PAT="$2"; shift ;;
        --claude-api-key=*)   CLI_CLAUDE_API_KEY="${1#*=}" ;;
        --claude-api-key)     CLI_CLAUDE_API_KEY="$2"; shift ;;
        -*)
            log_error "Unknown option: $1"
            print_help_main >&2
            exit 1
            ;;
        *)
            POSITIONAL+=("$1")
            ;;
    esac
    shift
done

# ── Command dispatch ───────────────────────────────────────────────────────────

COMMAND="${POSITIONAL[0]:-help}"
COMMAND_EXPLICIT="${POSITIONAL[0]:+true}"
COMMAND_EXPLICIT="${COMMAND_EXPLICIT:-false}"

# --help / -h: show command-specific help if a command was given, else main help
if [ "$SHOW_HELP" = "true" ]; then
    case "$COMMAND_EXPLICIT-$COMMAND" in
        true-create) print_help_create ;;
        true-list)   print_help_list ;;
        true-delete) print_help_delete ;;
        *)           print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        HELP_CMD="${POSITIONAL[1]:-}"
        case "$HELP_CMD" in
            create) print_help_create ;;
            list)   print_help_list ;;
            delete) print_help_delete ;;
            *)      print_help_main ;;
        esac
        exit 0
        ;;
    list)
        cmd_list
        exit $?
        ;;
    delete)
        DELETE_VM_NAME="${CLI_VM_NAME:-${POSITIONAL[1]:-}}"
        cmd_delete "$DELETE_VM_NAME" "$BATCH"
        exit $?
        ;;
    create)
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac

# ── Main: create ───────────────────────────────────────────────────────────────

log_title "AI Dev VM Creator"

# Step 1: VM name (needed before config load — determines which config to load)
DEFAULT_NAME=$(suggest_vm_name)
if [ -n "$CLI_VM_NAME" ]; then
    VM_NAME="$CLI_VM_NAME"
    log_info "VM name: $VM_NAME"
elif [ "$BATCH" = "true" ]; then
    VM_NAME="$DEFAULT_NAME"
    log_info "VM name: $VM_NAME"
else
    ask "VM name" "$DEFAULT_NAME" VM_NAME
fi

if [[ "$VM_NAME" =~ ([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -eq 1 ]; then
    log_error "VM name '$VM_NAME' derives IP .1 which is reserved for the network gateway. Use suffix 2 or higher."
    exit 1
fi
CONFIG_FILE="$CONFIG_DIR/${VM_NAME}.conf"

# Set defaults (overridden by config file if it exists)
VM_BASE_IMAGE="ubuntu24"
VM_VCPUS="4"
VM_RAM="32G"
VM_DISK_SIZE="200G"
VM_ADMIN_USER="$USER"
KVM_HOST="local"
LIBVIRT_NETWORK=$(list_networks | head -1)
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
VM_IP=""
GITHUB_PAT=""
CLAUDE_API_KEY=""

if [ -f "$CONFIG_FILE" ]; then
    log_info "Existing config found: $CONFIG_FILE — loading values"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    [ "$BATCH" = "false" ] && log_info "Press Enter at each prompt to keep current value."
fi

# Apply CLI overrides (take precedence over saved config)
[ -n "$CLI_BASE_IMAGE" ]     && VM_BASE_IMAGE="$CLI_BASE_IMAGE"
[ -n "$CLI_VCPUS" ]          && VM_VCPUS="$CLI_VCPUS"
[ -n "$CLI_RAM" ]            && VM_RAM="$CLI_RAM"
[ -n "$CLI_DISK_SIZE" ]      && VM_DISK_SIZE="$CLI_DISK_SIZE"
[ -n "$CLI_ADMIN_USER" ]     && VM_ADMIN_USER="$CLI_ADMIN_USER"
[ -n "$CLI_KVM_HOST" ]       && KVM_HOST="$CLI_KVM_HOST"
[ -n "$CLI_NETWORK" ]        && LIBVIRT_NETWORK="$CLI_NETWORK"
[ -n "$CLI_IP" ]             && VM_IP="$CLI_IP"
[ -n "$CLI_GITHUB_PAT" ]     && GITHUB_PAT="$CLI_GITHUB_PAT"
[ -n "$CLI_CLAUDE_API_KEY" ] && CLAUDE_API_KEY="$CLI_CLAUDE_API_KEY"

echo

# Step 2: Base OS image
choose "Base OS image" "$VM_BASE_IMAGE" VM_BASE_IMAGE "$CLI_BASE_IMAGE" \
    ubuntu24 ubuntu22 ubuntu20 rocky9 debian12

# Step 3: Resources
ask "vCPUs" "$VM_VCPUS" VM_VCPUS "$CLI_VCPUS"
ask "RAM (e.g. 32G)" "$VM_RAM" VM_RAM "$CLI_RAM"
[[ "$VM_RAM" =~ ^[0-9]+$ ]] && VM_RAM="${VM_RAM}G"
ask "Disk size (e.g. 200G)" "$VM_DISK_SIZE" VM_DISK_SIZE "$CLI_DISK_SIZE"
[[ "$VM_DISK_SIZE" =~ ^[0-9]+$ ]] && VM_DISK_SIZE="${VM_DISK_SIZE}G"

# Step 4: Admin user
ask "Admin username on VM" "$VM_ADMIN_USER" VM_ADMIN_USER "$CLI_ADMIN_USER"

# Step 5: KVM host
ask "KVM host ('local' or remote hostname)" "$KVM_HOST" KVM_HOST "$CLI_KVM_HOST"

# Step 6: Libvirt network
if [ -n "$CLI_NETWORK" ] || [ "$BATCH" = "true" ]; then
    log_info "Libvirt network: $LIBVIRT_NETWORK"
else
    echo
    log_info "Available libvirt networks:"
    list_networks | while read -r n; do [ -n "$n" ] && echo "  - $n"; done
    echo "  (enter 'new' to create a new network)"
    ask "Libvirt network name" "$LIBVIRT_NETWORK" LIBVIRT_NETWORK
fi

NET_CIDR=""
if [ "$LIBVIRT_NETWORK" == "new" ]; then
    if [ "$BATCH" = "true" ]; then
        log_error "Cannot use 'new' network in batch mode. Specify an actual network name with --network=<name>."
        exit 1
    fi
    ask "New network name" "kvmnet1" LIBVIRT_NETWORK
    ask "Network CIDR (e.g. 192.168.100.0/24)" "192.168.100.0/24" NET_CIDR "$CLI_NETWORK_CIDR"
    log_info "Creating network $LIBVIRT_NETWORK ($NET_CIDR)..."
    if [ "$KVM_HOST" == "local" ]; then
        "$KVM_DIR/kvm-net-define.sh" "$LIBVIRT_NETWORK" "$NET_CIDR"
    else
        "$KVM_DIR/kvm-remote.sh" "$KVM_HOST" net define "$LIBVIRT_NETWORK" "$NET_CIDR"
    fi
elif [ -n "$CLI_NETWORK_CIDR" ] && ! sudo virsh net-info "$LIBVIRT_NETWORK" &>/dev/null 2>&1; then
    # CLI mode: network doesn't exist yet and CIDR provided → create it
    NET_CIDR="$CLI_NETWORK_CIDR"
    log_info "Creating network $LIBVIRT_NETWORK ($NET_CIDR)..."
    if [ "$KVM_HOST" == "local" ]; then
        "$KVM_DIR/kvm-net-define.sh" "$LIBVIRT_NETWORK" "$NET_CIDR"
    else
        "$KVM_DIR/kvm-remote.sh" "$KVM_HOST" net define "$LIBVIRT_NETWORK" "$NET_CIDR"
    fi
fi

# Step 7: IP address — derive last octet from VM name suffix
NET_PREFIX=$(get_network_prefix "$LIBVIRT_NETWORK")
VM_NUMBER=""
if [[ "$VM_NAME" =~ ([0-9]+)$ ]]; then
    VM_NUMBER="${BASH_REMATCH[1]}"
fi
if [ -n "$VM_NUMBER" ] && [ -n "$NET_PREFIX" ]; then
    DEFAULT_IP="${NET_PREFIX}.${VM_NUMBER}"
elif [ -n "$NET_PREFIX" ]; then
    DEFAULT_IP="${NET_PREFIX}.2"
else
    DEFAULT_IP="192.168.122.2"
fi
ask "VM IP address" "${VM_IP:-$DEFAULT_IP}" VM_IP "$CLI_IP"
if [[ "$VM_IP" =~ \.1$ ]]; then
    log_error "IP $VM_IP ends in .1 which is reserved for the network gateway."
    exit 1
fi

# Step 8: GitHub PAT
if [ -n "$CLI_GITHUB_PAT" ] || [ "$BATCH" = "true" ]; then
    log_info "GitHub PAT: ${GITHUB_PAT:+(set)}"
else
    echo
    echo -e "${YELLOW}┌─ Creating a GitHub Personal Access Token (PAT) ───────────────────────────┐${NC}"
    echo -e "${YELLOW}│${NC} 1. Go to:  https://github.com/settings/tokens?type=beta"
    echo -e "${YELLOW}│${NC} 2. Click \"Generate new token\""
    echo -e "${YELLOW}│${NC} 3. Token name: e.g. \"${VM_NAME}\""
    echo -e "${YELLOW}│${NC} 4. Set Expiration as desired"
    echo -e "${YELLOW}│${NC} 5. Repository access → \"Only select repositories\""
    echo -e "${YELLOW}│${NC}    Add only the repos this VM needs access to"
    echo -e "${YELLOW}│${NC} 6. Repository permissions:"
    echo -e "${YELLOW}│${NC}      Contents:      Read and write  (clone, push, pull)"
    echo -e "${YELLOW}│${NC}      Pull requests: Read and write  (if needed)"
    echo -e "${YELLOW}│${NC}      Metadata:      Read-only       (required)"
    echo -e "${YELLOW}│${NC} 7. Account permissions:"
    echo -e "${YELLOW}│${NC}      GitHub Copilot: Read-only      (for Copilot CLI)"
    echo -e "${YELLOW}│${NC} 8. Click \"Generate token\" — copy it now, won't be shown again!"
    echo -e "${YELLOW}└───────────────────────────────────────────────────────────────────────────┘${NC}"
    echo
    if [ -n "$GITHUB_PAT" ]; then
        log_info "GitHub PAT already set. Leave blank to keep current value."
    fi
    ask_secret "GitHub PAT (Enter to keep existing)" GITHUB_PAT_INPUT
    [ -n "$GITHUB_PAT_INPUT" ] && GITHUB_PAT="$GITHUB_PAT_INPUT"
fi

# Step 9: Claude API key
if [ -n "$CLI_CLAUDE_API_KEY" ] || [ "$BATCH" = "true" ]; then
    log_info "Claude API key: ${CLAUDE_API_KEY:+(set)}"
else
    echo
    echo -e "${YELLOW}  Claude API keys: https://console.anthropic.com/settings/keys${NC}"
    if [ -n "$CLAUDE_API_KEY" ]; then
        log_info "Claude API key already set. Leave blank to keep current value."
    fi
    ask_secret "Claude API key (Enter to keep existing)" CLAUDE_API_KEY_INPUT
    [ -n "$CLAUDE_API_KEY_INPUT" ] && CLAUDE_API_KEY="$CLAUDE_API_KEY_INPUT"
fi

# Save config
save_config

# ── Phase 2: Prerequisites ─────────────────────────────────────────────────────

log_title "Checking prerequisites"

IMAGE_PATH="/var/lib/libvirt/images/${VM_BASE_IMAGE}.qcow2"
if [ "$KVM_HOST" == "local" ]; then
    if ! sudo test -f "$IMAGE_PATH"; then
        log_info "Image $VM_BASE_IMAGE not found — importing (this may take a while)..."
        "$KVM_DIR/kvm-import-image.sh" "$VM_BASE_IMAGE"
    else
        log_info "Image $VM_BASE_IMAGE: OK"
    fi
else
    log_info "Ensuring image $VM_BASE_IMAGE is available on $KVM_HOST..."
    "$KVM_DIR/kvm-remote.sh" "$KVM_HOST" import "$VM_BASE_IMAGE"
fi

if ping -c1 -W1 "$VM_IP" &>/dev/null 2>&1; then
    log_warning "IP $VM_IP is already responding to ping."
    if [ "$BATCH" = "true" ]; then
        log_info "Continuing in batch mode..."
    else
        read -rp "$(echo -e "${YELLOW}?${NC} Continue anyway? [y/N]: ")" ans
        [[ "${ans:-N}" =~ ^[Yy] ]] || { log_error "Aborted."; exit 1; }
    fi
else
    log_info "IP $VM_IP: available"
fi

# ── Phase 3: Create VM ─────────────────────────────────────────────────────────

CREATE_ARGS=(
    "$VM_BASE_IMAGE" "$VM_NAME" "$VM_IP"
    "--vcpus=${VM_VCPUS}"
    "--ram=${VM_RAM}"
    "--disk-size=${VM_DISK_SIZE}"
    "--admin-user=${VM_ADMIN_USER}"
)

if sudo virsh dominfo "$VM_NAME" &>/dev/null 2>&1; then
    log_info "VM $VM_NAME already exists — skipping creation."
else
    log_title "Creating VM: $VM_NAME"
    if [ "$KVM_HOST" == "local" ]; then
        "$KVM_DIR/kvm-create-vm.sh" "${CREATE_ARGS[@]}"
    else
        "$KVM_DIR/kvm-remote.sh" "$KVM_HOST" create "${CREATE_ARGS[@]}"
    fi
fi

# ── Phase 3.5: Virtiofs shares (local only) ────────────────────────────────────

SHARES_CHANGED=false

if [ "$KVM_HOST" == "local" ]; then
    log_title "Checking virtiofs shares"
    mkdir -p "$HOME/.claude" "$HOME/.copilot"
    INACTIVE_XML=$(sudo virsh dumpxml --inactive "$VM_NAME" 2>/dev/null)

    if echo "$INACTIVE_XML" | grep -q "target dir='claude'"; then
        log_info "Share 'claude' already configured."
    else
        "$KVM_DIR/kvm-share.sh" attach "$VM_NAME" "$HOME/.claude" "claude"
        SHARES_CHANGED=true
    fi

    if echo "$INACTIVE_XML" | grep -q "target dir='copilot'"; then
        log_info "Share 'copilot' already configured."
    else
        "$KVM_DIR/kvm-share.sh" attach "$VM_NAME" "$HOME/.copilot" "copilot"
        SHARES_CHANGED=true
    fi

    if [ "$SHARES_CHANGED" = "true" ]; then
        log_info "Restarting VM to activate new virtiofs shares..."
        sudo virsh shutdown "$VM_NAME" 2>/dev/null || true
        SHUTDOWN_WAIT=0
        while [ $SHUTDOWN_WAIT -lt 30 ]; do
            [ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" != "running" ] && break
            sleep 1
            SHUTDOWN_WAIT=$((SHUTDOWN_WAIT + 1))
        done
        [ "$(sudo virsh domstate "$VM_NAME" 2>/dev/null)" = "running" ] \
            && sudo virsh destroy "$VM_NAME"
        sudo virsh start "$VM_NAME"

        log_info "Waiting for SSH after restart (up to 120s)..."
        SSH_DEADLINE=$(($(date +%s) + 120))
        while [ "$(date +%s)" -lt "$SSH_DEADLINE" ]; do
            if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
                    "${VM_ADMIN_USER}@${VM_IP}" true &>/dev/null 2>&1; then
                log_info "SSH available on ${VM_NAME}."
                break
            fi
            sleep 3
        done
    fi
fi

# ── Phase 4: Provision ─────────────────────────────────────────────────────────

log_title "Provisioning VM: $VM_NAME"

PROVISION_SCRIPT="$SCRIPT_DIR/provision-aidvm.sh"

if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${VM_ADMIN_USER}@${VM_IP}" true &>/dev/null 2>&1; then
    log_warning "Cannot reach ${VM_ADMIN_USER}@${VM_IP} from this host."
    log_info "The VM may be on a NATted network only accessible from the KVM host."
    log_info ""
    log_info "To provision manually from a host that can reach the VM:"
    echo "  scp $PROVISION_SCRIPT ${VM_ADMIN_USER}@${VM_IP}:/tmp/"
    echo "  ssh ${VM_ADMIN_USER}@${VM_IP} \\"
    echo "    \"GITHUB_PAT='\${GITHUB_PAT}' CLAUDE_API_KEY='\${CLAUDE_API_KEY}' bash /tmp/provision-aidvm.sh\""
    echo
    log_info "Config is saved at: $CONFIG_FILE"
else
    log_info "Copying provisioning script to VM..."
    scp -o StrictHostKeyChecking=no \
        "$PROVISION_SCRIPT" \
        "${VM_ADMIN_USER}@${VM_IP}:/tmp/provision-aidvm.sh"

    log_info "Running provisioning (may take 10-20 minutes)..."
    ssh -o StrictHostKeyChecking=no \
        "${VM_ADMIN_USER}@${VM_IP}" \
        "GITHUB_PAT='${GITHUB_PAT}' CLAUDE_API_KEY='${CLAUDE_API_KEY}' bash /tmp/provision-aidvm.sh"

    if [ -f "$HOME/.claude.json" ]; then
        log_info "Copying ~/.claude.json to VM..."
        scp -o StrictHostKeyChecking=no \
            "$HOME/.claude.json" \
            "${VM_ADMIN_USER}@${VM_IP}:~/.claude.json"
    fi

    log_title "VM $VM_NAME is ready!"
    log_info "Connect:        ssh ${VM_ADMIN_USER}@${VM_IP}"
    log_info "GUI via X11:    ssh -X ${VM_ADMIN_USER}@${VM_IP} android-studio"
    log_info "               ssh -X ${VM_ADMIN_USER}@${VM_IP} qtcreator"
fi
