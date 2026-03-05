#!/bin/bash
# Provisioning script for AI Dev VM.
# Runs on the VM via SSH. Expects GITHUB_PAT and CLAUDE_API_KEY as env vars.
set -euo pipefail

GITHUB_PAT="${GITHUB_PAT:-}"
CLAUDE_API_KEY="${CLAUDE_API_KEY:-}"

log()       { echo -e "\033[0;32m[provision]\033[0m $*"; }
log_title() { echo -e "\n\033[0;35m===== $* =====\033[0m\n"; }
log_warn()  { echo -e "\033[0;33m[warning]\033[0m $*"; }

# ── System update ──────────────────────────────────────────────────────────────

log_title "System update"
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ── Common dev tools ───────────────────────────────────────────────────────────

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

# ── Node.js (LTS) ──────────────────────────────────────────────────────────────

log_title "Node.js (LTS)"
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi
log "Node.js $(node --version), npm $(npm --version)"

# ── Virtiofs shared directories ────────────────────────────────────────────────

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

# ── Claude CLI ─────────────────────────────────────────────────────────────────

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

# ── GitHub CLI ─────────────────────────────────────────────────────────────────

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

# ── GitHub Copilot CLI ─────────────────────────────────────────────────────────

log_title "GitHub Copilot CLI"
curl -fsSL https://gh.io/copilot-install | bash
log "Copilot: gh copilot suggest / gh copilot explain"

# ── Android Studio ─────────────────────────────────────────────────────────────

log_title "Android Studio"

# Install snapd if not present
if ! command -v snap &>/dev/null; then
    sudo apt-get install -y snapd
    sudo systemctl enable --now snapd.socket
    # snapd needs a moment before snap commands work
    sleep 5
fi

# Ensure the snap core is available (required for classic snaps)
sudo snap install core 2>/dev/null || true

sudo snap install android-studio --classic
log "Android Studio installed via snap"

# Environment for Android SDK (populated on first Studio launch)
if ! grep -q "ANDROID_HOME" /etc/profile.d/android.sh 2>/dev/null; then
    sudo tee /etc/profile.d/android.sh > /dev/null << 'EOF'
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/tools"
EOF
fi
log "Android environment written to /etc/profile.d/android.sh"
log "Launch with: android-studio  (accepts X11 display)"

# ── Qt ─────────────────────────────────────────────────────────────────────────

log_title "Qt & Qt Creator"
sudo apt-get install -y \
    qtcreator \
    qt6-base-dev \
    cmake
# qt6-tools-dev is not always available by name; qtcreator pulls what's needed
sudo apt-get install -y qt6-tools-dev 2>/dev/null || true
log "Qt Creator installed. Launch with: qtcreator"

# ── SSH X11 forwarding ─────────────────────────────────────────────────────────

log_title "SSH X11 forwarding"
SSHD_CFG="/etc/ssh/sshd_config"

# Set or replace X11Forwarding
if grep -q "^#*X11Forwarding" "$SSHD_CFG"; then
    sudo sed -i 's/^#*X11Forwarding.*/X11Forwarding yes/' "$SSHD_CFG"
else
    echo "X11Forwarding yes" | sudo tee -a "$SSHD_CFG" > /dev/null
fi

# Set or replace X11UseLocalhost
if grep -q "^#*X11UseLocalhost" "$SSHD_CFG"; then
    sudo sed -i 's/^#*X11UseLocalhost.*/X11UseLocalhost no/' "$SSHD_CFG"
else
    echo "X11UseLocalhost no" | sudo tee -a "$SSHD_CFG" > /dev/null
fi

sudo systemctl restart ssh
log "X11 forwarding enabled. Connect with: ssh -X user@ip"

# ── Bashrc settings ────────────────────────────────────────────────────────────

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

# ── Cleanup ────────────────────────────────────────────────────────────────────

log_title "Cleanup"
sudo apt-get autoremove -y
sudo apt-get clean

# ── Summary ────────────────────────────────────────────────────────────────────

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
