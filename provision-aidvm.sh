#!/bin/bash
# Provisioning script for AI Dev VM.
# Runs on the VM via SSH. Expects GITHUB_PAT and CLAUDE_API_KEY as env vars.
set -euo pipefail

GITHUB_PAT="${GITHUB_PAT:-}"
CLAUDE_API_KEY="${CLAUDE_API_KEY:-}"

log()       { echo -e "\033[0;32m[provision]\033[0m $*"; }
log_title() { echo -e "\n\033[0;35m===== $* =====\033[0m\n"; }
log_warn()  { echo -e "\033[0;33m[warning]\033[0m $*"; }
log_error() { echo -e "\033[0;31m[error]\033[0m $*" >&2; }

# ── Help ───────────────────────────────────────────────────────────────────────

print_help_main() {
    cat <<EOF
Usage: $(basename "$0") [COMMAND]

Provision an AI dev VM with development tools and configuration.
Typically invoked automatically by manage-aidvm.sh via SSH.

Commands:
  run          Run full provisioning
  help [run]   Show this help, or detailed help for a command (default)

Environment variables (passed before 'run'):
  GITHUB_PAT       GitHub fine-grained PAT for gh auth login
  CLAUDE_API_KEY   Anthropic API key — written to ~/.bashrc as ANTHROPIC_API_KEY

Use '$(basename "$0") <command> --help' for the same per-command help.

EOF
}

print_help_run() {
    cat <<EOF
Usage: $(basename "$0") run

Run full provisioning. Installs all dev tools and applies configuration.
Idempotent — safe to run again on an already-provisioned VM.

Environment variables:
  GITHUB_PAT       GitHub PAT (optional — run 'gh auth login' manually if omitted)
  CLAUDE_API_KEY   Anthropic API key (optional — written to ~/.bashrc if provided)

Provisioning steps:
   1. System update          apt-get update + upgrade
   2. Common dev tools       git vim neovim tmux curl wget build-essential
                             cmake python3 python3-pip unzip zip jq
                             xauth x11-apps openssh-server
   3. Node.js LTS            via nodesource setup script
   4. Virtiofs shares        fstab entries + mount attempts:
                               claude     → ~/.claude
                               copilot    → ~/.copilot
                               nvim-config → ~/.config/nvim
   5. Claude CLI             curl -fsSL https://claude.ai/install.sh | bash
   6. GitHub CLI             via official apt repository
   7. GitHub Copilot CLI     curl -fsSL https://gh.io/copilot-install | bash
   8. Android Studio         snap install android-studio --classic
   9. Qt & Qt Creator        apt: qtcreator qt6-base-dev
  10. SSH X11 forwarding     sshd_config: X11Forwarding yes, X11UseLocalhost no
  11. Bashrc settings        PATH (~/bin ~/.local/bin) + host env from /tmp/aid-env.sh
  12. Cleanup                apt autoremove + clean

EOF
}

# ── Provisioning ───────────────────────────────────────────────────────────────

cmd_run() {
    # ── System update ───────────────────────────────────────────────────────────

    log_title "System update"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

    # ── Common dev tools ────────────────────────────────────────────────────────

    log_title "Common dev tools"
    sudo apt-get install -y \
        git \
        vim \
        neovim \
        tmux \
        curl \
        wget \
        build-essential \
        cmake \
        python3 \
        python3-pip \
        unzip \
        zip \
        jq \
        xauth \
        x11-apps \
        openssh-server

    # ── Node.js (LTS) ───────────────────────────────────────────────────────────

    log_title "Node.js (LTS)"
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi
    log "Node.js $(node --version), npm $(npm --version)"

    # ── Virtiofs shared directories ─────────────────────────────────────────────

    log_title "Virtiofs shared directories"
    sudo modprobe virtiofs 2>/dev/null || true

    for spec in "claude:$HOME/.claude" "copilot:$HOME/.copilot" "nvim-config:$HOME/.config/nvim"; do
        tag="${spec%%:*}"
        mp="${spec#*:}"
        mkdir -p "$mp"
        if ! grep -qE "^${tag}[[:space:]]" /etc/fstab; then
            echo "${tag}  ${mp}  virtiofs  defaults  0  0" | sudo tee -a /etc/fstab > /dev/null
            log "Added fstab entry: ${tag} → ${mp}"
        fi
        if mountpoint -q "$mp" 2>/dev/null; then
            log "$mp already mounted"
        elif sudo mount -t virtiofs "$tag" "$mp" 2>/dev/null; then
            log "Mounted ${tag} → ${mp}"
        else
            log_warn "Could not mount ${tag} — share may not be attached to this VM"
        fi
    done

    # ── Claude CLI ──────────────────────────────────────────────────────────────

    log_title "Claude CLI"
    curl -fsSL https://claude.ai/install.sh | bash
    log "Claude CLI $(claude --version 2>/dev/null || echo 'installed')"

    if [ -n "$CLAUDE_API_KEY" ]; then
        # ANTHROPIC_API_KEY is the standard env var Claude CLI reads
        if ! grep -q "ANTHROPIC_API_KEY" "$HOME/.bashrc" 2>/dev/null; then
            echo "export ANTHROPIC_API_KEY='${CLAUDE_API_KEY}'" >> "$HOME/.bashrc"
        else
            sed -i "s|^export ANTHROPIC_API_KEY=.*|export ANTHROPIC_API_KEY='${CLAUDE_API_KEY}'|" "$HOME/.bashrc"
        fi
        log "Claude API key written to ~/.bashrc"
    fi

    # ── GitHub CLI ──────────────────────────────────────────────────────────────

    log_title "GitHub CLI"
    if ! command -v gh &>/dev/null; then
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
        chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
            | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        sudo apt-get update -y
        sudo apt-get install -y gh
    fi
    log "gh $(gh --version | head -1)"

    if [ -n "$GITHUB_PAT" ]; then
        echo "$GITHUB_PAT" | gh auth login --with-token
        log "GitHub CLI authenticated"
    else
        log_warn "No GITHUB_PAT provided — run 'gh auth login' manually"
    fi

    # ── GitHub Copilot CLI ──────────────────────────────────────────────────────

    log_title "GitHub Copilot CLI"
    curl -fsSL https://gh.io/copilot-install | bash
    log "Copilot: gh copilot suggest / gh copilot explain"

    # ── Android Studio ──────────────────────────────────────────────────────────

    log_title "Android Studio"

    if ! command -v snap &>/dev/null; then
        sudo apt-get install -y snapd
        sudo systemctl enable --now snapd.socket
        sleep 5
    fi

    sudo snap install core 2>/dev/null || true
    sudo snap install android-studio --classic
    log "Android Studio installed via snap"

    if ! grep -q "ANDROID_HOME" /etc/profile.d/android.sh 2>/dev/null; then
        sudo tee /etc/profile.d/android.sh > /dev/null << 'EOF'
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/tools"
EOF
    fi
    log "Android environment written to /etc/profile.d/android.sh"
    log "Launch with: android-studio  (accepts X11 display)"

    # ── Qt ──────────────────────────────────────────────────────────────────────

    log_title "Qt & Qt Creator"
    sudo apt-get install -y \
        qtcreator \
        qt6-base-dev \
        cmake
    sudo apt-get install -y qt6-tools-dev 2>/dev/null || true
    log "Qt Creator installed. Launch with: qtcreator"

    # ── SSH X11 forwarding ──────────────────────────────────────────────────────

    log_title "SSH X11 forwarding"
    SSHD_CFG="/etc/ssh/sshd_config"

    if grep -q "^#*X11Forwarding" "$SSHD_CFG"; then
        sudo sed -i 's/^#*X11Forwarding.*/X11Forwarding yes/' "$SSHD_CFG"
    else
        echo "X11Forwarding yes" | sudo tee -a "$SSHD_CFG" > /dev/null
    fi

    if grep -q "^#*X11UseLocalhost" "$SSHD_CFG"; then
        sudo sed -i 's/^#*X11UseLocalhost.*/X11UseLocalhost no/' "$SSHD_CFG"
    else
        echo "X11UseLocalhost no" | sudo tee -a "$SSHD_CFG" > /dev/null
    fi

    sudo systemctl restart ssh
    log "X11 forwarding enabled. Connect with: ssh -X user@ip"

    # ── Bashrc settings ─────────────────────────────────────────────────────────

    log_title "Bashrc settings"

    AID_MARKER="# >>> aid provision begin <<<"
    if grep -q "$AID_MARKER" "$HOME/.bashrc" 2>/dev/null; then
        log "Bashrc settings already present — skipping."
    else
        {
            echo ""
            echo "# >>> aid provision begin <<<"

            echo '# PATH'
            echo '[ -d "$HOME/bin" ]        && [[ ":$PATH:" != *":$HOME/bin:"*        ]] && export PATH="$HOME/bin:$PATH"'
            echo '[ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"'

            if [ -f /tmp/aid-env.sh ]; then
                echo ""
                echo "# Host environment"
                cat /tmp/aid-env.sh
            fi

            echo "# >>> aid provision end <<<"
        } >> "$HOME/.bashrc"
        log "Bashrc settings applied."
    fi

    # ── Cleanup ─────────────────────────────────────────────────────────────────

    log_title "Cleanup"
    sudo apt-get autoremove -y
    sudo apt-get clean

    # ── Summary ─────────────────────────────────────────────────────────────────

    log_title "Provisioning complete!"
    echo
    log "Installed tools:"
    log "  - git, vim, neovim, tmux, curl, build-essential, cmake, python3"
    log "  - Node.js $(node --version)"
    log "  - Claude CLI  →  claude"
    log "  - GitHub CLI  →  gh"
    log "  - GitHub Copilot  →  gh copilot suggest / gh copilot explain"
    log "  - Android Studio  →  android-studio  (X11)"
    log "  - Qt Creator      →  qtcreator       (X11)"
    echo
    log "Reload environment: source ~/.bashrc"
    log "GUI access:         ssh -X <user>@<ip> android-studio"
}

# ── Option parsing ─────────────────────────────────────────────────────────────

SHOW_HELP=false
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) SHOW_HELP=true ;;
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
        true-run) print_help_run ;;
        *)        print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        HELP_CMD="${POSITIONAL[1]:-}"
        case "$HELP_CMD" in
            run) print_help_run ;;
            *)   print_help_main ;;
        esac
        exit 0
        ;;
    run)
        cmd_run
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac
