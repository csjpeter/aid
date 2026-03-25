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
Usage: $(basename "$0") <command> [OPTIONS]

Provision an AI dev VM with development tools and configuration.
Typically invoked automatically by manage-aidvm.sh via SSH.

Full provisioning:
  run              Run all steps in sequence (idempotent)

Individual steps (also idempotent, safe to re-run):
  update           Step  1: apt update + upgrade
  dev-tools        Step  2: common dev packages (git vim neovim tmux curl …)
  nodejs           Step  3: Node.js LTS via nodesource
  virtiofs         Step  4: virtiofs shared directory mounts
  claude           Step  5: Claude CLI + ANTHROPIC_API_KEY
  github-cli       Step  6: GitHub CLI (apt) + gh auth login
  copilot          Step  7: GitHub Copilot CLI
  gemini           Step  8: Google Gemini CLI (npm)
  android-studio   Step  9: Android Studio (snap)
  qt               Step 10: Qt 6 + Qt Creator (apt)
  x11              Step 11: SSH X11 forwarding
  bashrc           Step 12: PATH + host env vars in ~/.bashrc
  cleanup          Step 13: apt autoremove + clean

To run a single step on an existing VM from the host:
  ssh <vm-name> ~/bin/provision-aidvm.sh <step>
  # sync the latest script first if needed:
  manage-aidvm.sh sync <vm-name>
  ssh <vm-name> ~/bin/provision-aidvm.sh gemini

Environment variables (needed by some steps):
  GITHUB_PAT       Fine-grained PAT — used by github-cli step
  CLAUDE_API_KEY   Anthropic API key — used by claude step

Use '$(basename "$0") help <step>' or '<step> --help' for step details.

EOF
}

print_help_run() {
    cat <<EOF
Usage: $(basename "$0") run

Run all provisioning steps in sequence. Idempotent — safe to re-run.
Each step can also be run individually; see '$(basename "$0") help' for the list.

EOF
}

print_help_step() {
    local step="$1"
    case "$step" in
        update)
            cat <<EOF
Usage: $(basename "$0") update

Step 1 — System update.
  apt-get update && apt-get upgrade

EOF
            ;;
        dev-tools)
            cat <<EOF
Usage: $(basename "$0") dev-tools

Step 2 — Common dev tools.
  Installs: git vim neovim tmux curl wget build-essential cmake tree
            python3 python3-pip unzip zip jq xauth x11-apps openssh-server

EOF
            ;;
        nodejs)
            cat <<EOF
Usage: $(basename "$0") nodejs

Step 3 — Node.js LTS.
  Adds the NodeSource apt repository and installs nodejs + npm.
  Skipped if node is already present.

EOF
            ;;
        virtiofs)
            cat <<EOF
Usage: $(basename "$0") virtiofs

Step 4 — Virtiofs shared directory mounts.
  Tags and mount points:
    claude      → ~/.claude
    gemini      → ~/.gemini
    copilot     → ~/.copilot
    nvim-config → ~/.config/nvim

  Adds fstab entries and mounts immediately. Requires the host to have
  attached the shares via manage-aidvm.sh (kvm-share.sh attach).

EOF
            ;;
        claude)
            cat <<EOF
Usage: $(basename "$0") claude

Step 5 — Claude CLI.
  Installs via: curl -fsSL https://claude.ai/install.sh | bash
  If CLAUDE_API_KEY is set, writes ANTHROPIC_API_KEY to ~/.bashrc.

EOF
            ;;
        github-cli)
            cat <<EOF
Usage: $(basename "$0") github-cli

Step 6 — GitHub CLI.
  Adds the official GitHub apt repository and installs gh.
  If GITHUB_PAT is set, runs: gh auth login --with-token.

EOF
            ;;
        copilot)
            cat <<EOF
Usage: $(basename "$0") copilot

Step 7 — GitHub Copilot CLI.
  Installs via: curl -fsSL https://gh.io/copilot-install | bash
  Provides: gh copilot suggest / gh copilot explain

EOF
            ;;
        gemini)
            cat <<EOF
Usage: $(basename "$0") gemini

Step 8 — Google Gemini CLI.
  Installs via: sudo npm install -g @google/gemini-cli
  Requires Node.js (step 3). Skipped if gemini is already present.

EOF
            ;;
        android-studio)
            cat <<EOF
Usage: $(basename "$0") android-studio

Step 9 — Android Studio.
  Installs via: snap install android-studio --classic
  Also writes ANDROID_HOME + PATH to /etc/profile.d/android.sh.
  Launch via SSH X11: ssh -X <user>@<ip> android-studio

EOF
            ;;
        qt)
            cat <<EOF
Usage: $(basename "$0") qt

Step 10 — Qt 6 & Qt Creator.
  Installs: qtcreator qt6-base-dev cmake qt6-tools-dev (if available)
  Launch via SSH X11: ssh -X <user>@<ip> qtcreator

EOF
            ;;
        x11)
            cat <<EOF
Usage: $(basename "$0") x11

Step 11 — SSH X11 forwarding.
  Sets in /etc/ssh/sshd_config:
    X11Forwarding yes
    X11UseLocalhost no
  Restarts sshd.

EOF
            ;;
        bashrc)
            cat <<EOF
Usage: $(basename "$0") bashrc

Step 12 — Bashrc settings.
  - Creates ~/bin and ~/.local/bin
  - Writes ~/.ssh/environment with current PATH (makes ~/bin available
    use: ssh <vm> ~/bin/provision-aidvm.sh <step>)
  - Appends a guarded block to ~/.bashrc (skipped if already present):
      - Adds ~/bin and ~/.local/bin to PATH
      - Applies host env vars from /tmp/aid-env.sh if present:
          PS1, NAME, EMAIL, DEBFULLNAME, DEBEMAIL,
          VISUAL, XEDITOR, EDITOR, ANDROID_HOME

EOF
            ;;
        cleanup)
            cat <<EOF
Usage: $(basename "$0") cleanup

Step 13 — Cleanup.
  apt-get autoremove + apt-get clean

EOF
            ;;
        *)
            print_help_main
            ;;
    esac
}

# ── Provisioning steps ─────────────────────────────────────────────────────────

step_update() {
    log_title "System update"
    sudo apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

step_dev_tools() {
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
        tree \
        xauth \
        x11-apps \
        openssh-server
}

step_nodejs() {
    log_title "Node.js (LTS)"
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi
    log "Node.js $(node --version), npm $(npm --version)"
}

step_virtiofs() {
    log_title "Virtiofs shared directories"
    sudo modprobe virtiofs 2>/dev/null || true

    for spec in "claude:$HOME/.claude" "gemini:$HOME/.gemini" "copilot:$HOME/.copilot" "nvim-config:$HOME/.config/nvim"; do
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
}

step_claude() {
    log_title "Claude CLI"
    curl -fsSL https://claude.ai/install.sh | bash
    log "Claude CLI $(claude --version 2>/dev/null || echo 'installed')"

    if [ -n "$CLAUDE_API_KEY" ]; then
        if ! grep -q "ANTHROPIC_API_KEY" "$HOME/.bashrc" 2>/dev/null; then
            echo "export ANTHROPIC_API_KEY='${CLAUDE_API_KEY}'" >> "$HOME/.bashrc"
        else
            sed -i "s|^export ANTHROPIC_API_KEY=.*|export ANTHROPIC_API_KEY='${CLAUDE_API_KEY}'|" "$HOME/.bashrc"
        fi
        log "Claude API key written to ~/.bashrc"
    fi
}

step_github_cli() {
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
}

step_copilot() {
    log_title "GitHub Copilot CLI"
    curl -fsSL https://gh.io/copilot-install | bash
    log "Copilot: gh copilot suggest / gh copilot explain"
}

step_gemini() {
    log_title "Gemini CLI"
    if command -v gemini &>/dev/null; then
        log "Gemini CLI already installed: $(gemini --version 2>/dev/null || echo 'present')"
    else
        sudo npm install -g @google/gemini-cli
        log "Gemini CLI $(gemini --version 2>/dev/null || echo 'installed')"
    fi
}

step_android_studio() {
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
}

step_qt() {
    log_title "Qt & Qt Creator"
    sudo apt-get install -y \
        qtcreator \
        qt6-base-dev \
        cmake
    sudo apt-get install -y qt6-tools-dev 2>/dev/null || true
    log "Qt Creator installed. Launch with: qtcreator"
}

step_x11() {
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
}

step_bashrc() {
    log_title "Bashrc settings"

    mkdir -p "$HOME/bin" "$HOME/.local/bin"
    [[ ":$PATH:" != *":$HOME/bin:"* ]] && export PATH="$HOME/bin:$PATH"
    [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"
    log "~/bin and ~/.local/bin created and added to PATH"

    local BEGIN="# >>> aid provision begin <<<"
    local END="# >>> aid provision end <<<"

    # Remove existing block so we always write fresh content (makes re-runs update PS1 etc.)
    if grep -q "$BEGIN" "$HOME/.bashrc" 2>/dev/null; then
        sed -i "/$BEGIN/,/$END/d" "$HOME/.bashrc"
        log "Replacing existing bashrc settings block."
    fi

    {
        echo ""
        echo "$BEGIN"

        echo '# PATH'
        echo '[ -d "$HOME/bin" ]        && [[ ":$PATH:" != *":$HOME/bin:"*        ]] && export PATH="$HOME/bin:$PATH"'
        echo '[ -d "$HOME/.local/bin" ] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"'

        echo ''
        echo '# Colored prompt'
        echo 'export PS1='\''\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '\'''

        if [ -f /tmp/aid-env.sh ]; then
            echo ""
            echo "# Host environment"
            cat /tmp/aid-env.sh
        fi

        echo "$END"
    } >> "$HOME/.bashrc"
    log "Bashrc settings applied."
}

step_cleanup() {
    log_title "Cleanup"
    sudo apt-get autoremove -y
    sudo apt-get clean
}

# ── Full run ───────────────────────────────────────────────────────────────────

cmd_run() {
    step_update
    step_dev_tools
    step_nodejs
    step_virtiofs
    step_claude
    step_github_cli
    step_copilot
    step_gemini
    step_android_studio
    step_qt
    step_x11
    step_bashrc
    step_cleanup

    log_title "Provisioning complete!"
    echo
    log "Installed tools:"
    log "  - git, vim, neovim, tmux, curl, build-essential, cmake, tree, python3"
    log "  - Node.js $(node --version)"
    log "  - Claude CLI          →  claude"
    log "  - GitHub CLI          →  gh"
    log "  - GitHub Copilot      →  gh copilot suggest / gh copilot explain"
    log "  - Gemini CLI          →  gemini"
    log "  - Android Studio      →  android-studio  (X11)"
    log "  - Qt Creator          →  qtcreator       (X11)"
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
        true-run)            print_help_run ;;
        true-update)         print_help_step update ;;
        true-dev-tools)      print_help_step dev-tools ;;
        true-nodejs)         print_help_step nodejs ;;
        true-virtiofs)       print_help_step virtiofs ;;
        true-claude)         print_help_step claude ;;
        true-github-cli)     print_help_step github-cli ;;
        true-copilot)        print_help_step copilot ;;
        true-gemini)         print_help_step gemini ;;
        true-android-studio) print_help_step android-studio ;;
        true-qt)             print_help_step qt ;;
        true-x11)            print_help_step x11 ;;
        true-bashrc)         print_help_step bashrc ;;
        true-cleanup)        print_help_step cleanup ;;
        *)                   print_help_main ;;
    esac
    exit 0
fi

case "$COMMAND" in
    help)
        print_help_step "${POSITIONAL[1]:-}"
        ;;
    run)            cmd_run ;;
    update)         step_update ;;
    dev-tools)      step_dev_tools ;;
    nodejs)         step_nodejs ;;
    virtiofs)       step_virtiofs ;;
    claude)         step_claude ;;
    github-cli)     step_github_cli ;;
    copilot)        step_copilot ;;
    gemini)         step_gemini ;;
    android-studio) step_android_studio ;;
    qt)             step_qt ;;
    x11)            step_x11 ;;
    bashrc)         step_bashrc ;;
    cleanup)        step_cleanup ;;
    *)
        log_error "Unknown command: $COMMAND"
        print_help_main >&2
        exit 1
        ;;
esac
