# Claude Notes — aid project

## User
- Name: Peter Csaszar (Császár Péter), login: csjpeter

## Project purpose
Scripts to create and provision KVM-based AI developer VMs (`aidvm2`, `aidvm3`, etc.).

## Key files
- `manage-aidvm.sh` — orchestrator: config collection, VM creation, provisioning trigger
- `provision-aidvm.sh` — runs on the VM via SSH, installs all dev tools
- `LICENSE` — BSD 3-Clause
- `README.md` — GitHub project documentation

## KVM utils
Included as a git submodule at `kvm/`. Always study these before modifying VM creation logic:
- `kvm-create-vm.sh` — creates VM from cloud image
- `kvm-import-image.sh` — imports cloud image into libvirt
- `kvm-net-define.sh` — creates libvirt NAT network
- `kvm-remote.sh` — runs kvm scripts on a remote host
- `kvm-include.sh` — shared logging functions (`log_title`, `log_info`, `log_warning`, `log_error`)

## Design decisions
- One config file per VM: `~/.config/aid/<vm-name>.conf`, always `chmod 600`
- Default resources: 4 vCPUs, 32G RAM, 200G disk, ubuntu24 image
- VM IP last octet matches VM name suffix: `aidvm3` → `x.x.x.3`; suffix 1 is forbidden (gateway)
- GitHub authentication uses fine-grained PAT (not classic token)
- Claude CLI installed via `curl -fsSL https://claude.ai/install.sh | bash` (not npm)
- GitHub Copilot CLI installed via `curl -fsSL https://gh.io/copilot-install | bash` (not gh extension)
- `~/.claude`, `~/.local/share/claude-userdata` and `~/.copilot` shared host→guest via virtiofs (`kvm-share.sh`); tags: `claude`, `claude-userdata`, `copilot`
- `~/.claude.json` copied to VM via SCP on every `create` run (single file, not virtiofs-shareable)
- Virtiofs requires shared memory backing (memfd); `kvm-share.sh attach` configures this automatically
- Android Studio installed via `snap install android-studio --classic`
- Qt installed via apt (`qtcreator`, `qt6-base-dev`)
- GUI apps accessed via SSH X11 forwarding (`ssh -X`)
- ANTHROPIC_API_KEY written to `~/.bashrc` on the VM
- License: BSD 3-Clause, copyright: Peter Csaszar (Császár Péter)
