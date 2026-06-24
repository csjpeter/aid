#!/bin/bash
# Shares ~/.claude from its home machine to other machines via sshfs.
# The SSH connection automatically picks the local hostname when on the home
# network, and the external hostname+port when away.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; PURPLE='\033[0;35m'; NC='\033[0m'
log_title() { echo -e "\n${PURPLE}[TITLE]${NC} $*\n"; }
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ── CLI option defaults ────────────────────────────────────────────────────────

CLI_HOME_USER=""
CLI_LOCAL_HOST=""
CLI_EXTERNAL_HOST=""
CLI_EXTERNAL_PORT=""
CLI_SSH_ALIAS=""

# ── Help ───────────────────────────────────────────────────────────────────────

print_help_main() {
    cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Share ~/.claude and ~/.local/share/claude-userdata from their home machine to
other machines via sshfs.
The SSH connection auto-selects local or external hostname based on reachability.

Commands:
  setup-server      Verify server-side prerequisites and print client connection info
  setup-client      Install sshfs, SSH alias, and systemd mount services on this machine
  uninstall-client  Remove systemd services and SSH alias installed by setup-client
  mount             Mount shared directories from the home machine (client only)
  umount            Unmount shared directories (client only)
  sync-json         Sync ~/.claude.json with the home machine (newer side wins)
  status            Show connection and mount status
  help [cmd]        Show this help, or detailed help for a command (default)

Use '$(basename "$0") <command> --help' for the same per-command help.

EOF
}

print_help_setup_server() {
    cat <<EOF
Usage: $(basename "$0") setup-server [OPTIONS]

Run on the home machine (where ~/.claude lives). Verifies that sshd is running and ~/.claude
and ~/.local/share/claude-userdata exist, then prints the connection
details to use on the client.

Options:
  --local-host=<host>      Hostname on the home network  (default: auto-detected)
  --external-host=<host>   Hostname reachable from outside (default: prompted)
  --external-port=<port>   External SSH port              (default: 22)

Examples:
  $(basename "$0") setup-server
  $(basename "$0") setup-server --external-host=<external-host> --external-port=<port>

EOF
}

print_help_setup_client() {
    cat <<EOF
Usage: $(basename "$0") setup-client [OPTIONS]

Run on the client machine (laptop). Does the following:
  1. Installs sshfs
  2. Adds an alias to ~/.ssh/config (named after --local-host by default) that automatically
     connects via the local hostname when at home, and the external
     hostname+port when away — no manual switching needed
  3. Backs up any existing ~/.claude and ~/.local/share/claude-userdata
     content and prepares the mount points
  4. Installs and enables systemd user services for automatic mounting at login
     (claude-mount.service and claude-userdata-mount.service)

Options:
  --home-user=<user>    SSH username on the home machine (default: \$USER)
  --local-host=<host>      Desktop hostname on home network
  --external-host=<host>   Desktop hostname via internet
  --external-port=<port>   External SSH port              (default: 22)
  --ssh-alias=<alias>      SSH config alias for the home machine (default: short name of --local-host)

Examples:
  $(basename "$0") setup-client \\
      --local-host=<local-host> \\
      --external-host=<external-host> --external-port=<port>

  # t14 → gulliver (use --ssh-alias to avoid conflict with /etc/hosts):
  $(basename "$0") setup-client \\
      --home-user=csjpeter \\
      --local-host=t14.wlan \\
      --external-host=csjp.asuscomm.com \\
      --external-port=65439 \\
      --ssh-alias=t14-claude

EOF
}

print_help_uninstall_client() {
    cat <<EOF
Usage: $(basename "$0") uninstall-client [--ssh-alias=<alias>]

Undo everything that setup-client did on this machine:
  1. Unmounts ~/.claude and ~/.local/share/claude-userdata (if mounted)
  2. Stops and disables the systemd user services
  3. Removes the service files from ~/.config/systemd/user/
  4. Removes the SSH alias block from ~/.ssh/config

The mount point directories themselves are left in place.

Options:
  --ssh-alias=<alias>   SSH alias to remove (default: auto-detected from ~/.ssh/config)

Examples:
  $(basename "$0") uninstall-client
  $(basename "$0") uninstall-client --ssh-alias=t14-claude

EOF
}

print_help_mount() {
    cat <<EOF
Usage: $(basename "$0") mount

Mount ~/.claude and ~/.local/share/claude-userdata from the home machine
onto this machine. Uses systemd user services if available.

Examples:
  $(basename "$0") mount

EOF
}

print_help_umount() {
    cat <<EOF
Usage: $(basename "$0") umount

Unmount ~/.claude and ~/.local/share/claude-userdata on this machine.

Examples:
  $(basename "$0") umount

EOF
}

print_help_sync_json() {
    cat <<EOF
Usage: $(basename "$0") sync-json

Sync ~/.claude.json between this machine and the home machine.
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

    # Verify ~/.local/share/claude-userdata exists
    if [ -d "$HOME/.local/share/claude-userdata" ]; then
        log_info "~/.local/share/claude-userdata: exists"
    else
        mkdir -p "$HOME/.local/share/claude-userdata"
        log_info "~/.local/share/claude-userdata: created"
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
        echo "      --home-user=$(whoami) \\"
        echo "      --local-host=${local_host} \\"
        echo "      --external-host=${external_host} \\"
        echo "      --external-port=${external_port}"
    else
        echo "  $(basename "$0") setup-client \\"
        echo "      --home-user=$(whoami) \\"
        echo "      --local-host=${local_host} \\"
        echo "      --external-host=<your-external-hostname> \\"
        echo "      --external-port=<port>"
    fi
    echo
}

cmd_setup_client() {
    local home_user="${CLI_HOME_USER:-$USER}"
    local local_host="${CLI_LOCAL_HOST:-}"
    local external_host="${CLI_EXTERNAL_HOST:-}"
    local external_port="${CLI_EXTERNAL_PORT:-22}"
    local mount_point="$HOME/.claude"

    local ssh_alias
    if   [ -n "$CLI_SSH_ALIAS" ];  then ssh_alias="$CLI_SSH_ALIAS"
    elif [ -n "$local_host" ];     then ssh_alias="${local_host%%.*}"
    elif [ -n "$external_host" ];  then ssh_alias="${external_host%%.*}"
    else
        log_error "Cannot derive SSH alias — specify --ssh-alias, --local-host, or --external-host."
        exit 1
    fi

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

    local marker_begin="# >>> ${ssh_alias} alias begin <<<"
    local marker_end="# >>> ${ssh_alias} alias end <<<"
    if grep -q "$marker_begin" "$HOME/.ssh/config" 2>/dev/null; then
        log_info "Updating SSH alias '${ssh_alias}' in ~/.ssh/config..."
        sed -i "/$marker_begin/,/$marker_end/d" "$HOME/.ssh/config"
    fi

    {
        echo ""
        echo "$marker_begin"
    } >> "$HOME/.ssh/config"

    # If both local and external are given: use Match exec to auto-switch
    if [ -n "$local_host" ] && [ -n "$external_host" ]; then
        cat >> "$HOME/.ssh/config" << EOF
# If home machine is reachable on the local network, connect directly.
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
    User ${home_user}
$marker_end
EOF
    log_info "SSH alias '${ssh_alias}' added/updated:"
    [ -n "$local_host" ]    && log_info "  home: ${local_host}:22"
    [ -n "$external_host" ] && log_info "  away: ${external_host}:${external_port}"

    # ── Mount points ───────────────────────────────────────────────────────────
    local userdata_point="$HOME/.local/share/claude-userdata"
    for mp in "$mount_point" "$userdata_point"; do
        log_info "Preparing mount point $mp..."
        # Detect stale FUSE mount: present in /proc/mounts but inaccessible
        if grep -qs " ${mp} " /proc/self/mounts && ! stat "$mp" &>/dev/null; then
            log_warn "$mp: stale FUSE mount detected — force unmounting..."
            fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" || true
        fi
        if mountpoint -q "$mp" 2>/dev/null; then
            log_info "$mp is already mounted."
        elif [ -d "$mp" ] && [ -n "$(ls -A "$mp" 2>/dev/null)" ]; then
            log_warn "$mp is non-empty — backing up to ${mp}.bak"
            mv "$mp" "${mp}.bak"
            mkdir -p "$mp"
        else
            mkdir -p "$mp"
            log_info "$mp ready."
        fi
    done

    # ── Systemd user service ───────────────────────────────────────────────────
    log_info "Installing systemd user service..."
    local service_dir="$HOME/.config/systemd/user"
    local service_file="$service_dir/claude-mount.service"
    mkdir -p "$service_dir"

    cat > "$service_file" << EOF
[Unit]
Description=Mount ~/.claude from its home machine via sshfs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p %h/.claude
ExecStart=/usr/bin/sshfs ${ssh_alias}:.claude %h/.claude \
    -f -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
ExecStop=/usr/bin/fusermount -u %h/.claude

[Install]
WantedBy=default.target
EOF

    local userdata_service_file="$service_dir/claude-userdata-mount.service"
    cat > "$userdata_service_file" << EOF
[Unit]
Description=Mount ~/.local/share/claude-userdata from its home machine via sshfs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p %h/.local/share/claude-userdata
ExecStart=/usr/bin/sshfs ${ssh_alias}:.local/share/claude-userdata %h/.local/share/claude-userdata \
    -f -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3
ExecStop=/usr/bin/fusermount -u %h/.local/share/claude-userdata

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable claude-mount.service
    systemctl --user enable claude-userdata-mount.service
    log_info "Services enabled (claude-mount.service, claude-userdata-mount.service)."

    # ── Test and mount ─────────────────────────────────────────────────────────
    log_info "Testing SSH connection to '${ssh_alias}'..."
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${ssh_alias}" true 2>/dev/null; then
        log_info "SSH connection OK."
        for svc_mp in "claude-mount.service:$mount_point" "claude-userdata-mount.service:$userdata_point"; do
            local svc="${svc_mp%%:*}" mp="${svc_mp#*:}"
            systemctl --user restart "$svc" && sleep 1
            if mountpoint -q "$mp" 2>/dev/null; then
                log_info "$mp mounted."
            else
                log_warn "$mp: service started but mount not confirmed — check: systemctl --user status $svc"
            fi
        done
    else
        log_warn "Could not reach '${ssh_alias}' right now."
        log_info "Mount manually once connected:  $(basename "$0") mount"
    fi

    echo
    log_info "Done. Shared directories served from ${home_user}@${ssh_alias}:"
    log_info "  ~/.claude                       → ~/.claude"
    log_info "  ~/.local/share/claude-userdata   → ~/.local/share/claude-userdata"
    [ -n "$local_host" ] && [ -n "$external_host" ] && \
        log_info "SSH switches automatically between home (${local_host}) and away (${external_host}:${external_port})."
}

cmd_uninstall_client() {
    local ssh_alias
    ssh_alias=$(_resolve_alias)

    log_title "Client uninstall"

    # ── Unmount ────────────────────────────────────────────────────────────────
    for svc_mp in "claude-mount.service:$HOME/.claude" "claude-userdata-mount.service:$HOME/.local/share/claude-userdata"; do
        local svc="${svc_mp%%:*}" mp="${svc_mp#*:}"
        
        # Detect stale FUSE mount: present in /proc/mounts but inaccessible
        if grep -qs " ${mp} " /proc/self/mounts && ! stat "$mp" &>/dev/null; then
            log_warn "$mp: stale FUSE mount detected — force unmounting..."
            fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" || true
        elif mountpoint -q "$mp" 2>/dev/null; then
            log_info "Unmounting $mp..."
            systemctl --user stop "$svc" 2>/dev/null || fusermount -uz "$mp" 2>/dev/null || true
        fi
    done

    # ── Systemd services ───────────────────────────────────────────────────────
    local service_dir="$HOME/.config/systemd/user"
    for svc in claude-mount.service claude-userdata-mount.service; do
        if systemctl --user cat "$svc" &>/dev/null 2>&1; then
            systemctl --user disable "$svc" 2>/dev/null || true
            log_info "$svc: disabled"
        fi
        if [ -f "$service_dir/$svc" ]; then
            rm -f "$service_dir/$svc"
            log_info "$svc: removed"
        fi
    done
    systemctl --user daemon-reload

    # ── SSH alias ──────────────────────────────────────────────────────────────
    local marker_begin="# >>> ${ssh_alias} alias begin <<<"
    local marker_end="# >>> ${ssh_alias} alias end <<<"
    if grep -q "$marker_begin" "$HOME/.ssh/config" 2>/dev/null; then
        sed -i "/$marker_begin/,/$marker_end/d" "$HOME/.ssh/config"
        log_info "SSH alias '${ssh_alias}': removed from ~/.ssh/config"
    else
        log_warn "SSH alias '${ssh_alias}': not found in ~/.ssh/config — nothing to remove"
    fi

    log_info "Done. Run setup-client to reinstall."
}

cmd_mount() {
    local any_mounted=false
    for svc_mp in "claude-mount.service:$HOME/.claude" "claude-userdata-mount.service:$HOME/.local/share/claude-userdata"; do
        local svc="${svc_mp%%:*}" mp="${svc_mp#*:}"
        if mountpoint -q "$mp" 2>/dev/null; then
            log_info "$mp is already mounted."
            any_mounted=true
        elif systemctl --user cat "$svc" &>/dev/null 2>&1; then
            systemctl --user start "$svc"
            log_info "$mp mounted via systemd service."
            any_mounted=true
        else
            log_warn "$svc not found — run '$(basename "$0") setup-client' first."
        fi
    done
    [ "$any_mounted" = "false" ] && { log_error "No mount services found."; exit 1; }
}

cmd_umount() {
    for svc_mp in "claude-mount.service:$HOME/.claude" "claude-userdata-mount.service:$HOME/.local/share/claude-userdata"; do
        local svc="${svc_mp%%:*}" mp="${svc_mp#*:}"
        
        # Detect stale FUSE mount: present in /proc/mounts but inaccessible
        if grep -qs " ${mp} " /proc/self/mounts && ! stat "$mp" &>/dev/null; then
            log_warn "$mp: stale FUSE mount detected — force unmounting..."
            fusermount -uz "$mp" 2>/dev/null || sudo umount -l "$mp" || true
            log_info "$mp unmounted (forced)."
            continue
        fi
        
        if ! mountpoint -q "$mp" 2>/dev/null; then
            log_info "$mp is not mounted."
            continue
        fi
        if systemctl --user cat "$svc" &>/dev/null 2>&1; then
            systemctl --user stop "$svc"
        else
            fusermount -uz "$mp"
        fi
        log_info "$mp unmounted."
    done
}

_resolve_alias() {
    if [ -n "$CLI_SSH_ALIAS" ]; then echo "$CLI_SSH_ALIAS"; return; fi
    local found
    found=$(grep -o '# >>> .* alias begin <<<' "$HOME/.ssh/config" 2>/dev/null \
        | head -1 | sed 's/# >>> \(.*\) alias begin <<</\1/')
    if [ -z "$found" ]; then
        log_error "No SSH alias found in ~/.ssh/config — run setup-client or specify --ssh-alias."
        exit 1
    fi
    echo "$found"
}

cmd_sync_json() {
    local ssh_alias
    ssh_alias=$(_resolve_alias)
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
    for dir_svc in "$HOME/.claude:claude-mount.service" "$HOME/.local/share/claude-userdata:claude-userdata-mount.service"; do
        local dir="${dir_svc%%:*}" svc="${dir_svc#*:}"
        local short_dir="${dir#"$HOME"/}"
        if mountpoint -q "$dir" 2>/dev/null; then
            log_info "~/$short_dir: mounted"
        elif [ -d "$dir" ]; then
            log_warn "~/$short_dir: directory exists but not mounted"
        else
            log_warn "~/$short_dir: does not exist"
        fi
        if systemctl --user cat "$svc" &>/dev/null 2>&1; then
            local svc_state
            svc_state=$(systemctl --user is-active "$svc" 2>/dev/null || echo "inactive")
            log_info "$svc: $svc_state"
        else
            log_info "$svc: not installed"
        fi
    done

    # SSH alias reachability
    local ssh_alias
    ssh_alias=$(_resolve_alias)
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
        --home-user=*)      CLI_HOME_USER="${1#*=}" ;;
        --home-user)        CLI_HOME_USER="$2"; shift ;;
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
        true-setup-server)      print_help_setup_server ;;
        true-setup-client)      print_help_setup_client ;;
        true-uninstall-client)  print_help_uninstall_client ;;
        true-mount)             print_help_mount ;;
        true-umount)            print_help_umount ;;
        true-sync-json)         print_help_sync_json ;;
        true-status)            print_help_status ;;
        *)                 print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        case "${POSITIONAL[1]:-}" in
            setup-server)      print_help_setup_server ;;
            setup-client)      print_help_setup_client ;;
            uninstall-client)  print_help_uninstall_client ;;
            mount)             print_help_mount ;;
            umount)            print_help_umount ;;
            sync-json)         print_help_sync_json ;;
            status)            print_help_status ;;
            *)            print_help_main ;;
        esac
        exit 0
        ;;
    setup-server)      cmd_setup_server ;;
    setup-client)      cmd_setup_client ;;
    uninstall-client)  cmd_uninstall_client ;;
    mount)             cmd_mount ;;
    umount)            cmd_umount ;;
    sync-json)         cmd_sync_json ;;
    status)            cmd_status ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac
