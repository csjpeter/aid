#!/bin/bash
# Shares ~/.claude from a desktop machine to other machines via sshfs.
# The SSH connection automatically picks the local hostname when on the home
# network, and the external hostname+port when away.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; PURPLE='\033[0;35m'; NC='\033[0m'
log_title() { echo -e "\n${PURPLE}[TITLE]${NC} $*\n"; }
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── CLI option defaults ────────────────────────────────────────────────────────

CLI_DESKTOP_USER=""
CLI_LOCAL_HOST=""
CLI_EXTERNAL_HOST=""
CLI_EXTERNAL_PORT=""
CLI_SSH_ALIAS=""

# ── Help ───────────────────────────────────────────────────────────────────────

print_help_main() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Share ~/.claude from the desktop to other machines via sshfs.
The SSH connection auto-selects local or external hostname based on reachability.

Commands:
  setup-server   Verify server-side prerequisites and print client connection info
  setup-client   Install sshfs, SSH alias, and systemd mount service on this machine
  mount          Mount ~/.claude from the desktop (client only)
  umount         Unmount ~/.claude (client only)
  sync-json      Sync ~/.claude.json with the desktop (newer side wins)
  status         Show connection and mount status
  help [cmd]     Show this help, or detailed help for a command (default)

Use '$(basename "$0") <command> --help' for the same per-command help.

EOF
}

print_help_setup_server() {
    cat <<EOF
Usage: $(basename "$0") setup-server [OPTIONS]

Run on the desktop machine. Verifies that sshd is running and ~/.claude
exists, then prints the connection details to use on the client.

Options:
  --local-host=<host>      Hostname on the home network  (default: auto-detected)
  --external-host=<host>   Hostname reachable from outside (default: prompted)
  --external-port=<port>   External SSH port              (default: 22)

Examples:
  $(basename "$0") setup-server
  $(basename "$0") setup-server --external-host=<external-host> --external-port=<external-port>

EOF
}

print_help_setup_client() {
    cat <<EOF
Usage: $(basename "$0") setup-client [OPTIONS]

Run on the client machine (laptop). Does the following:
  1. Installs sshfs
  2. Adds a '${CLI_SSH_ALIAS:-desktop}' alias to ~/.ssh/config that automatically
     connects via the local hostname when at home, and the external
     hostname+port when away — no manual switching needed
  3. Backs up any existing ~/.claude content and prepares the mount point
  4. Installs and enables a systemd user service for automatic mounting at login

Options:
  --desktop-user=<user>    SSH username on the desktop    (default: \$USER)
  --local-host=<host>      Desktop hostname on home network
  --external-host=<host>   Desktop hostname via internet
  --external-port=<port>   External SSH port              (default: 22)
  --ssh-alias=<alias>      SSH config alias for the desktop (default: desktop)

Examples:
  $(basename "$0") setup-client \\
      --local-host=<local-host> \\
      --external-host=<external-host> --external-port=<external-port>

EOF
}

print_help_mount() {
    cat <<EOF
Usage: $(basename "$0") mount

Mount ~/.claude from the desktop on this machine.
Uses the systemd user service if available, otherwise runs sshfs directly.

Examples:
  $(basename "$0") mount

EOF
}

print_help_umount() {
    cat <<EOF
Usage: $(basename "$0") umount

Unmount ~/.claude on this machine.

Examples:
  $(basename "$0") umount

EOF
}

print_help_sync_json() {
    cat <<EOF
Usage: $(basename "$0") sync-json

Sync ~/.claude.json between this machine and the desktop.
Compares modification times and copies the newer version to the other side.
Safe to run at any time — never overwrites a newer file.

Examples:
  $(basename "$0") sync-json

EOF
}

print_help_status() {
    cat <<EOF
Usage: $(basename "$0") status

Show the current state of the ~/.claude mount and SSH connectivity:
  - Whether ~/.claude is currently mounted
  - Which SSH host is reachable (local or external)
  - Systemd service status (if installed)

Examples:
  $(basename "$0") status

EOF
}

# ── Sub-commands ───────────────────────────────────────────────────────────────

cmd_setup_server() {
    log_title "Server setup"

    # Verify sshd
    if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null; then
        log_info "sshd: running"
    else
        log_error "sshd does not appear to be running. Start it with: sudo systemctl start ssh"
        exit 1
    fi

    # Verify ~/.claude exists
    if [ -d "$HOME/.claude" ]; then
        log_info "~/.claude: exists"
    else
        log_warn "~/.claude does not exist yet — it will be created when Claude CLI first runs."
        mkdir -p "$HOME/.claude"
        log_info "~/.claude: created"
    fi

    # Detect local hostname
    local local_host="${CLI_LOCAL_HOST:-$(hostname)}"
    log_info "Local hostname: $local_host"

    # External host
    local external_host="${CLI_EXTERNAL_HOST:-}"
    local external_port="${CLI_EXTERNAL_PORT:-22}"
    if [ -z "$external_host" ]; then
        log_warn "No --external-host specified. Skipping external access info."
    fi

    # Print client setup command
    echo
    log_info "Server is ready. Run the following on each client machine:"
    echo
    if [ -n "$external_host" ]; then
        echo "  $(basename "$0") setup-client \\"
        echo "      --desktop-user=$(whoami) \\"
        echo "      --local-host=${local_host} \\"
        echo "      --external-host=${external_host} \\"
        echo "      --external-port=${external_port}"
    else
        echo "  $(basename "$0") setup-client \\"
        echo "      --desktop-user=$(whoami) \\"
        echo "      --local-host=${local_host} \\"
        echo "      --external-host=<your-external-hostname> \\"
        echo "      --external-port=<port>"
    fi
    echo
}

cmd_setup_client() {
    local desktop_user="${CLI_DESKTOP_USER:-$USER}"
    local local_host="${CLI_LOCAL_HOST:-}"
    local external_host="${CLI_EXTERNAL_HOST:-}"
    local external_port="${CLI_EXTERNAL_PORT:-22}"
    local ssh_alias="${CLI_SSH_ALIAS:-desktop}"
    local mount_point="$HOME/.claude"

    if [ -z "$local_host" ] && [ -z "$external_host" ]; then
        log_error "Specify at least one of --local-host or --external-host."
        exit 1
    fi

    log_title "Client setup"

    # ── sshfs ──────────────────────────────────────────────────────────────────
    log_info "Checking sshfs..."
    if ! command -v sshfs &>/dev/null; then
        log_info "Installing sshfs..."
        sudo apt-get install -y sshfs
    fi
    log_info "sshfs: OK"

    # ── SSH config ─────────────────────────────────────────────────────────────
    log_info "Configuring ~/.ssh/config..."
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$HOME/.ssh/config"
    chmod 600 "$HOME/.ssh/config"

    local marker="# >>> ${ssh_alias} alias begin <<<"
    if grep -q "$marker" "$HOME/.ssh/config" 2>/dev/null; then
        log_info "SSH alias '${ssh_alias}' already present in ~/.ssh/config — skipping."
    else
        {
            echo ""
            echo "# >>> ${ssh_alias} alias begin <<<"
        } >> "$HOME/.ssh/config"

        # If both local and external are given: use Match exec to auto-switch
        if [ -n "$local_host" ] && [ -n "$external_host" ]; then
            cat >> "$HOME/.ssh/config" << EOF
# If desktop is reachable on the local network, connect directly.
Match Host ${ssh_alias} exec "ping -c1 -W1 ${local_host} >/dev/null 2>&1"
    Hostname ${local_host}
    Port 22

EOF
        fi

        # Default (external, or local-only if no external given)
        local default_host="${external_host:-$local_host}"
        cat >> "$HOME/.ssh/config" << EOF
Host ${ssh_alias}
    Hostname ${default_host}
    Port ${external_port}
    User ${desktop_user}
# >>> ${ssh_alias} alias end <<<
EOF
        log_info "SSH alias '${ssh_alias}' added:"
        [ -n "$local_host" ]    && log_info "  home: ${local_host}:22"
        [ -n "$external_host" ] && log_info "  away: ${external_host}:${external_port}"
    fi

    # ── Mount point ────────────────────────────────────────────────────────────
    log_info "Preparing mount point $mount_point..."
    if mountpoint -q "$mount_point" 2>/dev/null; then
        log_info "$mount_point is already mounted."
    elif [ -d "$mount_point" ] && [ -n "$(ls -A "$mount_point" 2>/dev/null)" ]; then
        log_warn "$mount_point is non-empty — backing up to ${mount_point}.bak"
        mv "$mount_point" "${mount_point}.bak"
        mkdir -p "$mount_point"
    else
        mkdir -p "$mount_point"
        log_info "$mount_point ready."
    fi

    # ── Systemd user service ───────────────────────────────────────────────────
    log_info "Installing systemd user service..."
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/claude-mount.service"
    mkdir -p "$service_dir"

    cat > "$service_file" << EOF
[Unit]
Description=Mount ~/.claude from desktop via sshfs
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/mkdir -p %h/.claude
ExecStart=/usr/bin/sshfs ${ssh_alias}:.claude %h/.claude \
    -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,follow_symlinks
ExecStop=/usr/bin/fusermount -u %h/.claude

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable claude-mount.service
    log_info "Service enabled (claude-mount.service)."

    # ── Test and mount ─────────────────────────────────────────────────────────
    log_info "Testing SSH connection to '${ssh_alias}'..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_alias}" true 2>/dev/null; then
        log_info "SSH connection OK."
        if mountpoint -q "$mount_point" 2>/dev/null; then
            log_info "$mount_point already mounted."
        else
            systemctl --user start claude-mount.service
            log_info "$mount_point mounted."
        fi
    else
        log_warn "Could not reach '${ssh_alias}' right now."
        log_info "Mount manually once connected:  $(basename "$0") mount"
    fi

    echo
    log_info "Done. ~/.claude is now served from ${desktop_user}@${ssh_alias}:~/.claude"
    [ -n "$local_host" ] && [ -n "$external_host" ] && \
        log_info "SSH switches automatically between home (${local_host}) and away (${external_host}:${external_port})."
}

cmd_mount() {
    if mountpoint -q "$HOME/.claude" 2>/dev/null; then
        log_info "~/.claude is already mounted."
        return
    fi
    if systemctl --user cat claude-mount.service &>/dev/null 2>&1; then
        systemctl --user start claude-mount.service
        log_info "~/.claude mounted via systemd service."
    else
        log_error "claude-mount.service not found. Run '$(basename "$0") setup-client' first."
        exit 1
    fi
}

cmd_umount() {
    if ! mountpoint -q "$HOME/.claude" 2>/dev/null; then
        log_info "~/.claude is not mounted."
        return
    fi
    if systemctl --user cat claude-mount.service &>/dev/null 2>&1; then
        systemctl --user stop claude-mount.service
    else
        fusermount -u "$HOME/.claude"
    fi
    log_info "~/.claude unmounted."
}

cmd_sync_json() {
    local ssh_alias="${CLI_SSH_ALIAS:-desktop}"
    local local_file="$HOME/.claude.json"

    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_alias" true 2>/dev/null; then
        log_error "Cannot reach '${ssh_alias}'."
        exit 1
    fi

    local remote_exists
    remote_exists=$(ssh "$ssh_alias" '[ -f ~/.claude.json ] && echo yes || echo no')
    local local_exists=false
    [ -f "$local_file" ] && local_exists=true

    if [ "$remote_exists" = "no" ] && [ "$local_exists" = "false" ]; then
        log_info "~/.claude.json does not exist on either side — nothing to sync."
        return
    fi

    if [ "$remote_exists" = "no" ]; then
        log_info "Remote ~/.claude.json missing — pushing local copy to ${ssh_alias}..."
        scp "$local_file" "${ssh_alias}:~/.claude.json"
        log_info "Done."
        return
    fi

    if [ "$local_exists" = "false" ]; then
        log_info "Local ~/.claude.json missing — pulling from ${ssh_alias}..."
        scp "${ssh_alias}:~/.claude.json" "$local_file"
        log_info "Done."
        return
    fi

    # Both exist — compare modification times, copy the newer one
    local remote_mtime local_mtime
    remote_mtime=$(ssh "$ssh_alias" "stat -c %Y ~/.claude.json")
    local_mtime=$(stat -c %Y "$local_file")

    if [ "$local_mtime" -gt "$remote_mtime" ]; then
        log_info "Local is newer — pushing to ${ssh_alias}..."
        scp "$local_file" "${ssh_alias}:~/.claude.json"
        log_info "Done."
    elif [ "$remote_mtime" -gt "$local_mtime" ]; then
        log_info "Remote is newer — pulling from ${ssh_alias}..."
        scp "${ssh_alias}:~/.claude.json" "$local_file"
        log_info "Done."
    else
        log_info "~/.claude.json is already in sync (same modification time)."
    fi
}

cmd_status() {
    log_title "Claude share status"

    # Mount status
    if mountpoint -q "$HOME/.claude" 2>/dev/null; then
        log_info "~/.claude: mounted"
    elif [ -d "$HOME/.claude" ]; then
        log_warn "~/.claude: directory exists but not mounted"
    else
        log_warn "~/.claude: does not exist"
    fi

    # Systemd service
    if systemctl --user cat claude-mount.service &>/dev/null 2>&1; then
        local svc_state
        svc_state=$(systemctl --user is-active claude-mount.service 2>/dev/null || echo "inactive")
        log_info "claude-mount.service: $svc_state"
    else
        log_info "claude-mount.service: not installed"
    fi

    # SSH alias reachability
    local ssh_alias="${CLI_SSH_ALIAS:-desktop}"
    if grep -q "Host ${ssh_alias}" "$HOME/.ssh/config" 2>/dev/null; then
        log_info "SSH alias '${ssh_alias}': configured"
        # Detect which path is active
        local local_host
        local_host=$(awk "/Match Host ${ssh_alias}/{f=1} f && /Hostname/{print \$2; exit}" "$HOME/.ssh/config" 2>/dev/null || echo "")
        local ext_host
        ext_host=$(awk "/^Host ${ssh_alias}/{f=1} f && /Hostname/{print \$2; exit}" "$HOME/.ssh/config" 2>/dev/null || echo "")
        [ -n "$local_host" ] && log_info "  home host: $local_host"
        [ -n "$ext_host"   ] && log_info "  away host: $ext_host"
        if ssh -o ConnectTimeout=5 -o BatchMode=yes "${ssh_alias}" true 2>/dev/null; then
            log_info "  reachable: yes"
        else
            log_warn "  reachable: no"
        fi
    else
        log_warn "SSH alias '${ssh_alias}': not found in ~/.ssh/config"
    fi
}

# ── Option parsing ─────────────────────────────────────────────────────────────

SHOW_HELP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)             SHOW_HELP=true ;;
        --desktop-user=*)      CLI_DESKTOP_USER="${1#*=}" ;;
        --desktop-user)        CLI_DESKTOP_USER="$2"; shift ;;
        --local-host=*)        CLI_LOCAL_HOST="${1#*=}" ;;
        --local-host)          CLI_LOCAL_HOST="$2"; shift ;;
        --external-host=*)     CLI_EXTERNAL_HOST="${1#*=}" ;;
        --external-host)       CLI_EXTERNAL_HOST="$2"; shift ;;
        --external-port=*)     CLI_EXTERNAL_PORT="${1#*=}" ;;
        --external-port)       CLI_EXTERNAL_PORT="$2"; shift ;;
        --ssh-alias=*)         CLI_SSH_ALIAS="${1#*=}" ;;
        --ssh-alias)           CLI_SSH_ALIAS="$2"; shift ;;
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

if [ "$SHOW_HELP" = "true" ]; then
    case "$COMMAND_EXPLICIT-$COMMAND" in
        true-setup-server) print_help_setup_server ;;
        true-setup-client) print_help_setup_client ;;
        true-mount)        print_help_mount ;;
        true-umount)       print_help_umount ;;
        true-sync-json)    print_help_sync_json ;;
        true-status)       print_help_status ;;
        *)                 print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        case "${POSITIONAL[1]:-}" in
            setup-server) print_help_setup_server ;;
            setup-client) print_help_setup_client ;;
            mount)        print_help_mount ;;
            umount)       print_help_umount ;;
            sync-json)    print_help_sync_json ;;
            status)       print_help_status ;;
            *)            print_help_main ;;
        esac
        exit 0
        ;;
    setup-server) cmd_setup_server ;;
    setup-client) cmd_setup_client ;;
    mount)        cmd_mount ;;
    umount)       cmd_umount ;;
    sync-json)    cmd_sync_json ;;
    status)       cmd_status ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac
