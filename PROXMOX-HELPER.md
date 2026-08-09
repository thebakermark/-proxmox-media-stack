# Proxmox Helper Installer

`proxmox-helper.sh` is the guided installer for the complete media-stack VM. Its interaction model is inspired by the Community Scripts Proxmox VE project while preserving this repository's Ubuntu Server VM + Docker architecture.

## Run it

Open **Shell** on the Proxmox host as `root` and run:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/thebakermark/-proxmox-media-stack/main/proxmox-helper.sh)"
```

## What it does

The helper:

1. Verifies root access, amd64 architecture, and a supported Proxmox VE release.
2. Offers **Default** or **Advanced** VM settings.
3. Finds the next safe VM ID and checks for collisions.
4. Lets you choose Proxmox storage for the Ubuntu OS disk and the separate `/data` disk.
5. Uses the existing `00-create-proxmox-vm.sh` provisioner to download/checksum Ubuntu Server 26.04 LTS and create the VM.
6. Adds a one-time cloud-init bootstrap to install Git and QEMU Guest Agent, clone this repository, and install the media stack.
7. If a Proton VPN WireGuard config is supplied, injects it only for bootstrap, installs the Docker stack, then removes the temporary bootstrap copy and custom cloud-init snippet after completion.
8. Waits for the QEMU Guest Agent and the bootstrap's completion marker, then prints the VM IP, application URLs, and the exact command to run the verification script yourself (it does not run `30-verify-stack.sh` automatically).

The VM is created with `--no-password`: no cloud-init password is set, and the helper never touches SSH. All guest interaction happens over the QEMU Guest Agent (`qm guest exec`). If you need a conventional login afterward (console or SSH), set one explicitly:

```bash
qm set VMID --cipassword 'a-strong-password-here'
```

A fallback SSH key is still generated and injected automatically by `00-create-proxmox-vm.sh` (at `/root/.proxmox-media-stack/id_ed25519` on the Proxmox host) even in `--no-password` mode, so the host itself always has a way in if the guest agent ever stops responding.

## Default VM settings

- Ubuntu Server 26.04 LTS
- next available VM ID
- VM name: `media-stack`
- 4 vCPU
- 6 GiB RAM
- 80 GiB OS disk
- 500 GiB separate data disk
- `vmbr0`
- DHCP
- cloud-init user: `mediaadmin`

Storage is still selected interactively because media capacity differs between Proxmox hosts.

## Proton VPN

For a fully automated install, download a Proton VPN WireGuard configuration to the Proxmox host before running the helper. When prompted, enter its local path, for example:

```text
/root/proton-us-p2p.conf
```

Do not commit this file or its private key.

If you leave the Proton path blank, the helper still creates Ubuntu, attaches the data disk, installs the bootstrap prerequisites, and clones the repository, but it does not start the Docker media services. Finish inside the VM with:

```bash
cd /opt/proxmox-media-stack
sudo ./10-install-media-stack.sh
```

## Verify

Inside the completed Ubuntu VM:

```bash
sudo /opt/media-stack/30-verify-stack.sh
```

Bootstrap log:

```bash
sudo cat /var/log/media-stack-bootstrap.log
```

## Safety

The helper creates a new Proxmox-managed virtual data disk. It does not select, wipe, or format an existing physical disk. The guest installer retains its blank-disk/signature checks before creating `/data`.

The helper does not check whether your chosen storage has enough *real* backing capacity for the sizes you request. On a thin-provisioned pool (LVM-thin or similar), the pool can report far more space as "available" than physically exists once every VM's allocation is summed. Before accepting the 500 GiB data-disk default, check actual free space with `pvesm status` and size down if the pool is tight — over-allocating a thin pool risks I/O errors across *every* VM on that storage, not just this one, if it ever fills up for real.

## Testing status

The core VM/cloud-init/guest-agent mechanics have been reviewed against real Proxmox VE 9.2 command output and corrected where they didn't match (see git history), but this script has not yet been run end-to-end against real hardware. Report issues by checking `/var/log/proxmox-media-stack-helper.log` on the Proxmox host and `/var/log/media-stack-bootstrap.log` inside the VM.
