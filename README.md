# aid — AI Dev VM

Scripts to create and provision KVM virtual machines as AI-assisted developer environments.

A provisioned VM includes:
- **Claude CLI** (`claude`) — Anthropic's Claude Code CLI
- **GitHub Copilot CLI** (`gh copilot`) — AI pair programmer in the terminal
- **GitHub CLI** (`gh`) — repo and PR management
- **Android Studio** — mobile development IDE
- **Qt Creator** — Qt/C++ development IDE
- **Common dev tools** — git, vim, tmux, Node.js, Python, cmake, build-essential

GUI apps are accessed via SSH X11 forwarding (`ssh -X`).

---

## Requirements (on the host machine)

- KVM/libvirt installed — see [kvm-utils](https://github.com/csjpeter/kvm-utils)
- SSH key pair in `~/.ssh/`
- `virsh`, `virt-install`, `xorriso`, `cloud-init` available

---

## Usage

```bash
./manage-aidvm.sh create
```

The script guides you through all configuration interactively and saves it to `~/.config/aid/<vm-name>.conf` for reuse.

### What it asks

| Prompt | Default |
|---|---|
| VM name | `aidvm2`, `aidvm3`, … (auto-incremented) |
| Base OS image | `ubuntu24` |
| vCPUs | `4` |
| RAM | `32G` |
| Disk size | `200G` |
| Admin username | `$USER` |
| KVM host | `local` (or remote hostname) |
| Libvirt network | `default` (or create new) |
| VM IP address | derived from VM number (e.g. `aidvm2` → `x.x.x.2`) |
| GitHub PAT | — (see below) |
| Claude API key | — (see [console.anthropic.com](https://console.anthropic.com/settings/keys)) |

Re-running the script for an existing VM name loads the saved config — press Enter at each prompt to keep the current value.

---

## GitHub Personal Access Token (PAT)

The script prints this guide before asking for the token:

1. Go to **https://github.com/settings/tokens?type=beta** (fine-grained PAT)
2. Click **Generate new token**
3. Set **Token name** — e.g. `aidvm2`
4. Set **Expiration** as desired
5. Under **Repository access** → choose **Only select repositories**
   and add only the repos this VM needs access to
6. Under **Repository permissions** grant:
   - **Contents**: Read and write *(clone, push, pull)*
   - **Pull requests**: Read and write *(if needed)*
   - **Metadata**: Read-only *(required)*
7. Under **Account permissions** grant:
   - **GitHub Copilot**: Read-only *(for Copilot CLI)*
8. Click **Generate token** — copy it now, it won't be shown again

---

## Multiple VMs

Each VM gets its own config file:

```
~/.config/aid/aidvm2.conf
~/.config/aid/aidvm3.conf
~/.config/aid/my-custom-name.conf
```

You can create as many VMs as your host resources allow. The script suggests the next available `aidvmN` name but accepts any custom name.

---

## Connecting to the VM

```bash
# Shell access
ssh user@<ip>

# GUI apps via X11 forwarding
ssh -X user@<ip> android-studio
ssh -X user@<ip> qtcreator
```

---

## Sharing ~/.claude between machines

`claude-share.sh` mounts `~/.claude` and `~/.local/share/claude-userdata` from the
home machine (server) onto another machine (client) via sshfs, so Claude sessions,
history and settings are shared automatically.

### Server side (t14 — where ~/.claude lives)

```bash
~/bin/aid/claude-share.sh setup-server --local-host=t14.wlan
```

### Client side (e.g. gulliver/t560 — mounts t14's ~/.claude)

```bash
~/ai-projects/aid/claude-share.sh setup-client \
    --home-user=csjpeter \
    --local-host=t14.wlan \
    --external-host=csjp.asuscomm.com \
    --external-port=65439 \
    --ssh-alias=t14-claude
```

> **Note:** use `--ssh-alias=t14-claude` (not `t14`) to avoid conflict with the
> `t14` entry in `/etc/hosts`.

### Other useful commands

```bash
# Undo setup-client (before re-running with different options)
~/ai-projects/aid/claude-share.sh uninstall-client --ssh-alias=t14-claude

# Mount manually (if auto-mount via systemd didn't fire)
~/ai-projects/aid/claude-share.sh mount

# Check status
~/ai-projects/aid/claude-share.sh status --local-host=t14.wlan

# Sync ~/.claude.json (newer side wins)
~/ai-projects/aid/claude-share.sh sync-json
```

---

## Files

| File | Purpose |
|---|---|
| `manage-aidvm.sh` | Orchestrator — collects config, creates and provisions the VM |
| `provision-aidvm.sh` | Provisioning script — runs on the VM via SSH |
| `claude-share.sh` | Share ~/.claude between machines via sshfs |
| `claude-backup.sh` | Tiered backup/restore of ~/.claude (hourly/daily/weekly/monthly) |

---

## Dependencies

Uses [kvm-utils](https://github.com/csjpeter/kvm-utils) as a git submodule at `kvm/`.
Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/csjpeter/aid.git
```

Or if already cloned:

```bash
git submodule update --init
```
