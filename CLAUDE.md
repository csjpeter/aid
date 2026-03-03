# Claude Notes — aid project

## User
- Name: Peter Csaszar (Császár Péter), login: csjpeter

## Project purpose
Scripts to create and provision KVM-based AI developer VMs (`ai-dev-vm-1`, `ai-dev-vm-2`, etc.).

## Key files
- `create-ai-dev-vm.sh` — interactive orchestrator: config collection, VM creation, provisioning trigger
- `provision-ai-dev-vm.sh` — runs on the VM via SSH, installs all dev tools
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
- VM IP last octet matches VM name suffix: `ai-dev-vm-3` → `x.x.x.3`; suffix 1 is forbidden (gateway)
- GitHub authentication uses fine-grained PAT (not classic token)
- Android Studio installed via `snap install android-studio --classic`
- Qt installed via apt (`qtcreator`, `qt6-base-dev`)
- GUI apps accessed via SSH X11 forwarding (`ssh -X`)
- ANTHROPIC_API_KEY written to `~/.bashrc` on the VM
- License: BSD 3-Clause, copyright: Peter Csaszar (Császár Péter)
