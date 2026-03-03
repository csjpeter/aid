#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KVM_DIR="$SCRIPT_DIR/kvm"
CONFIG_DIR="$HOME/.config/aid"

source "$KVM_DIR/kvm-include.sh"

# ── Prompt helpers ─────────────────────────────────────────────────────────────

ask() {
    # ask <message> <default> <varname>
    local msg="$1" default="$2" varname="$3"
    local input
    read -rp "$(echo -e "${GREEN}?${NC} $msg [${default}]: ")" input
    printf -v "$varname" '%s' "${input:-$default}"
}

ask_optional() {
    # ask_optional <message> <varname>  — empty default, no brackets shown
    local msg="$1" varname="$2"
    local input
    read -rp "$(echo -e "${GREEN}?${NC} $msg: ")" input
    printf -v "$varname" '%s' "$input"
}

ask_secret() {
    # ask_secret <message> <varname>
    local msg="$1" varname="$2"
    local input
    read -rsp "$(echo -e "${GREEN}?${NC} $msg: ")" input
    echo
    printf -v "$varname" '%s' "$input"
}

choose() {
    # choose <message> <default> <varname> <option1> [<option2> ...]
    local msg="$1" default="$2" varname="$3"
    shift 3
    local options=("$@")
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
        echo "ai-dev-vm-1"
        return
    fi
    local n=1
    while sudo virsh dominfo "ai-dev-vm-$n" &>/dev/null 2>&1; do
        ((n++))
    done
    echo "ai-dev-vm-$n"
}

list_networks() {
    sudo virsh net-list --all --name 2>/dev/null | grep -v '^$' || echo "default"
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

# ── Main ───────────────────────────────────────────────────────────────────────

log_title "AI Dev VM Creator"

# Step 1: VM name
DEFAULT_NAME=$(suggest_vm_name)
ask "VM name" "$DEFAULT_NAME" VM_NAME
CONFIG_FILE="$CONFIG_DIR/${VM_NAME}.conf"

# Set defaults (overridden by config file if it exists)
VM_BASE_IMAGE="ubuntu24"
VM_VCPUS="4"
VM_RAM="32G"
VM_DISK_SIZE="200G"
VM_ADMIN_USER="$USER"
KVM_HOST="local"
LIBVIRT_NETWORK="default"
GITHUB_PAT=""
CLAUDE_API_KEY=""

if [ -f "$CONFIG_FILE" ]; then
    log_info "Existing config found: $CONFIG_FILE — loading values"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    log_info "Press Enter at each prompt to keep current value."
fi

echo

# Step 2: Base OS image
choose "Base OS image" "$VM_BASE_IMAGE" VM_BASE_IMAGE \
    ubuntu24 ubuntu22 ubuntu20 rocky9 debian12

# Step 3: Resources
ask "vCPUs" "$VM_VCPUS" VM_VCPUS
ask "RAM (e.g. 32G)" "$VM_RAM" VM_RAM
ask "Disk size (e.g. 200G)" "$VM_DISK_SIZE" VM_DISK_SIZE

# Step 4: Admin user
ask "Admin username on VM" "$VM_ADMIN_USER" VM_ADMIN_USER

# Step 5: KVM host
ask "KVM host ('local' or remote hostname)" "$KVM_HOST" KVM_HOST

# Step 6: Libvirt network
echo
log_info "Available libvirt networks:"
list_networks | while read -r n; do [ -n "$n" ] && echo "  - $n"; done
echo "  (enter 'new' to create a new network)"
ask "Libvirt network name" "$LIBVIRT_NETWORK" LIBVIRT_NETWORK

NET_CIDR=""
if [ "$LIBVIRT_NETWORK" == "new" ]; then
    ask "New network name" "kvmnet1" LIBVIRT_NETWORK
    ask "Network CIDR (e.g. 192.168.100.0/24)" "192.168.100.0/24" NET_CIDR
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
if [[ "$VM_NAME" =~ -([0-9]+)$ ]]; then
    VM_NUMBER="${BASH_REMATCH[1]}"
fi
if [ -n "$VM_NUMBER" ] && [ -n "$NET_PREFIX" ]; then
    DEFAULT_IP="${NET_PREFIX}.${VM_NUMBER}"
elif [ -n "$NET_PREFIX" ]; then
    DEFAULT_IP="${NET_PREFIX}.2"
else
    DEFAULT_IP="192.168.122.2"
fi
ask "VM IP address" "${VM_IP:-$DEFAULT_IP}" VM_IP

# Step 8: GitHub PAT
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

# Step 9: Claude API key
echo
echo -e "${YELLOW}  Claude API keys: https://console.anthropic.com/settings/keys${NC}"
if [ -n "$CLAUDE_API_KEY" ]; then
    log_info "Claude API key already set. Leave blank to keep current value."
fi
ask_secret "Claude API key (Enter to keep existing)" CLAUDE_API_KEY_INPUT
[ -n "$CLAUDE_API_KEY_INPUT" ] && CLAUDE_API_KEY="$CLAUDE_API_KEY_INPUT"

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
    read -rp "$(echo -e "${YELLOW}?${NC} Continue anyway? [y/N]: ")" ans
    [[ "${ans:-N}" =~ ^[Yy] ]] || { log_error "Aborted."; exit 1; }
else
    log_info "IP $VM_IP: available"
fi

# ── Phase 3: Create VM ─────────────────────────────────────────────────────────

log_title "Creating VM: $VM_NAME"

CREATE_ARGS=(
    "$VM_BASE_IMAGE" "$VM_NAME" "$VM_IP"
    "--vcpus=${VM_VCPUS}"
    "--ram=${VM_RAM}"
    "--disk-size=${VM_DISK_SIZE}"
    "--admin-user=${VM_ADMIN_USER}"
)

if [ "$KVM_HOST" == "local" ]; then
    "$KVM_DIR/kvm-create-vm.sh" "${CREATE_ARGS[@]}"
else
    "$KVM_DIR/kvm-remote.sh" "$KVM_HOST" create "${CREATE_ARGS[@]}"
fi

# ── Phase 4: Provision ─────────────────────────────────────────────────────────

log_title "Provisioning VM: $VM_NAME"

PROVISION_SCRIPT="$SCRIPT_DIR/provision-ai-dev-vm.sh"

if ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${VM_ADMIN_USER}@${VM_IP}" true &>/dev/null 2>&1; then
    log_warning "Cannot reach ${VM_ADMIN_USER}@${VM_IP} from this host."
    log_info "The VM may be on a NATted network only accessible from the KVM host."
    log_info ""
    log_info "To provision manually from a host that can reach the VM:"
    echo "  scp $PROVISION_SCRIPT ${VM_ADMIN_USER}@${VM_IP}:/tmp/"
    echo "  ssh ${VM_ADMIN_USER}@${VM_IP} \\"
    echo "    \"GITHUB_PAT='\${GITHUB_PAT}' CLAUDE_API_KEY='\${CLAUDE_API_KEY}' bash /tmp/provision-ai-dev-vm.sh\""
    echo
    log_info "Config is saved at: $CONFIG_FILE"
else
    log_info "Copying provisioning script to VM..."
    scp -o StrictHostKeyChecking=no \
        "$PROVISION_SCRIPT" \
        "${VM_ADMIN_USER}@${VM_IP}:/tmp/provision-ai-dev-vm.sh"

    log_info "Running provisioning (may take 10-20 minutes)..."
    ssh -o StrictHostKeyChecking=no \
        "${VM_ADMIN_USER}@${VM_IP}" \
        "GITHUB_PAT='${GITHUB_PAT}' CLAUDE_API_KEY='${CLAUDE_API_KEY}' bash /tmp/provision-ai-dev-vm.sh"

    log_title "VM $VM_NAME is ready!"
    log_info "Connect:        ssh ${VM_ADMIN_USER}@${VM_IP}"
    log_info "GUI via X11:    ssh -X ${VM_ADMIN_USER}@${VM_IP} android-studio"
    log_info "               ssh -X ${VM_ADMIN_USER}@${VM_IP} qtcreator"
fi
