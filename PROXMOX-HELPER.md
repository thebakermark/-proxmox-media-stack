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
8. Waits for QEMU Guest Agent, runs the stack verification script, and prints the VM IP and application URLs.

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
