# Proxmox Media Stack Installer

This project creates an **Ubuntu Server 26.04 LTS (Resolute Raccoon)** VM on Proxmox and installs a mapped media automation stack designed for the Dell Precision T1700 host.

Core applications:

- Jellyfin
- Sonarr, Radarr, Prowlarr, Bazarr and Seerr
- qBittorrent isolated behind Gluetun and Proton VPN
- Automatic Proton VPN port forwarding into qBittorrent
- Optional Plex and Tautulli
- Optional Lidarr, Audiobookshelf, SABnzbd and Recyclarr
- Optional Homepage, Dozzle and Uptime Kuma
- Optional Dispatcharr IPTV/EPG manager and virtual tuner
- Optional Tunarr channels built from the Jellyfin library

The installer deliberately does not configure piracy sources. Add only indexers and downloads you are legally authorized to use.

## Recommended operating system

Do **not** install a desktop operating system for the media VM.

Use **Ubuntu Server 26.04 LTS**. The Proxmox provisioning script downloads Canonical's official amd64 cloud image and verifies it against Canonical's published SHA-256 manifest before importing it into Proxmox.

## Before starting

1. Install the 1 TB SSD in the T1700 and use it for Proxmox and VM disks.
2. Decide how the several-terabyte disks will be presented as one Proxmox storage target. A ZFS pool made from matched disks is the preferred route.
3. Back up any disk containing files. The host script never wipes physical disks, and the guest installer refuses disks containing a filesystem.
4. Download a Proton VPN WireGuard configuration for a P2P/port-forwarding server. Keep the file private; never commit or paste its private key.

## Fastest install

Open **Shell** on the Proxmox host and run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/thebakermark/-proxmox-media-stack/main/install.sh)
```

The bootstrap script downloads the current repository and starts VM provisioning.

Defaults:

- Ubuntu Server 26.04 LTS
- next available Proxmox VM ID
- VM name `media-stack`
- 4 vCPU
- 6 GiB RAM
- 80 GiB OS disk
- DHCP networking on `vmbr0`
- cloud-init user `mediaadmin`
- OS storage `local-lvm`

You will be asked to create a password of at least 12 characters for `mediaadmin`.

## Using a dedicated Proxmox media storage target

If you have already created a Proxmox storage target such as `media-zfs`, you can pass options through the one-command installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/thebakermark/-proxmox-media-stack/main/install.sh) \
  --storage local-lvm \
  --data-storage media-zfs \
  --data-size 6000
```

The `6000` value is only an example. Check `pvesm status` and never request a virtual disk larger than the available capacity.

The host script allocates only a new Proxmox-managed virtual disk. It does not format physical disks.

## Manual Stage 1 — create the Ubuntu VM

If you prefer to clone the repository first:

```bash
git clone https://github.com/thebakermark/-proxmox-media-stack.git
cd ./-proxmox-media-stack
chmod +x ./*.sh
sudo ./00-create-proxmox-vm.sh --storage local-lvm
```

The provisioning script:

1. Confirms it is running on Proxmox.
2. Verifies the selected Proxmox storage and network bridge.
3. Downloads the official Ubuntu Server 26.04 LTS cloud image.
4. Verifies the image using Canonical's published SHA-256 manifest.
5. Creates a Q35/KVM VM with VirtIO networking and VirtIO-SCSI storage.
6. Adds a Proxmox cloud-init disk.
7. Configures the `mediaadmin` account and DHCP.
8. Optionally allocates a separate blank virtual media disk.
9. Starts the VM.

## Stage 2 — install the applications inside Ubuntu

Open the new VM's **Console** in Proxmox and sign in as `mediaadmin`.

Then run:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/thebakermark/-proxmox-media-stack.git
cd ./-proxmox-media-stack
sudo ./10-install-media-stack.sh
```

The guest installer requires Ubuntu Server 26.04 LTS and will stop if it detects another distribution or Ubuntu release.

It will:

1. Ask for the VM LAN subnet and IP.
2. Require `/data` to be a separate mounted filesystem.
3. Offer to format only a completely blank, explicitly selected virtual disk.
4. Install QEMU Guest Agent.
5. Install Docker Engine and Compose from Docker's official Ubuntu repository.
6. Read your Proton WireGuard configuration locally.
7. Create the media/download directory structure.
8. Start the core stack.

After installation, change qBittorrent's temporary password and run:

```bash
sudo /opt/media-stack/20-wire-arr-apps.sh
sudo /opt/media-stack/30-verify-stack.sh
```

The wiring script gives Sonarr and Radarr a consistent `/data` view and connects them to qBittorrent through Gluetun. The verification script confirms that the host and torrent network have different public IPs and that hardlinks work.

## Application addresses

Replace `MEDIA_VM_IP` with the Ubuntu VM's address.

| Application | Address |
| --- | --- |
| Jellyfin | `http://MEDIA_VM_IP:8096` |
| Seerr requests | `http://MEDIA_VM_IP:5055` |
| Sonarr | `http://MEDIA_VM_IP:8989` |
| Radarr | `http://MEDIA_VM_IP:7878` |
| Prowlarr | `http://MEDIA_VM_IP:9696` |
| Bazarr | `http://MEDIA_VM_IP:6767` |
| qBittorrent | `http://MEDIA_VM_IP:8080` |
| Dispatcharr IPTV | `http://MEDIA_VM_IP:9191` |
| Tunarr custom channels | `http://MEDIA_VM_IP:8000` |

Do not forward these administration ports through the home router. Use Tailscale or another trusted private-access method when away from home.

## Optional application groups

Edit `/opt/media-stack/.env` and set `COMPOSE_PROFILES` to a comma-separated list.

Available profiles:

- `plex` — Plex and Tautulli
- `music` — Lidarr
- `books` — Audiobookshelf
- `usenet` — SABnzbd
- `automation` — Recyclarr
- `admin` — Homepage, Dozzle and Uptime Kuma
- `iptv` — Dispatcharr and Tunarr

Example:

```text
COMPOSE_PROFILES=music,books,admin,iptv
```

Then run:

```bash
cd /opt/media-stack
sudo docker compose up -d
```

Do not enable every profile merely because it is available. The T1700 has 16 GiB RAM and also needs capacity for other Proxmox workloads.

For IPTV subscription, guide, DVR and custom-channel setup, follow `IPTV-PVR.md`. IPTV provider credentials are stored only in Dispatcharr and are not added to this repository or `.env`.

## Hardware transcoding

The base configuration works without GPU passthrough.

If `/dev/dri/renderD128` is later exposed to the Ubuntu VM, the installer and update script automatically apply `compose.intel.yml` to give supported media applications access to the render device.

The i7-4790's Intel HD 4600 can help with older H.264 workloads but should not be expected to handle modern HEVC/AV1 transcoding like a newer Intel iGPU.

The NVIDIA NVS 310 should not be used as the primary media transcoder.

## Updates and backups

Update containers after creating an automatic configuration backup:

```bash
sudo /opt/media-stack/40-update-stack.sh
```

Create a configuration-only backup:

```bash
sudo /opt/media-stack/50-backup-stack.sh
```

These backups exclude the media library. Use Proxmox Backup Server, ZFS snapshots/replication, or another separate backup target for irreplaceable data.

## Account-specific input still required

No safe installer can manufacture these credentials or choices:

- Proton WireGuard configuration
- legal torrent/indexer accounts
- subtitle-provider credentials
- Jellyfin administrator account
- optional Plex claim token
- optional Usenet provider credentials
- IPTV M3U/XMLTV or Xtream Codes credentials

Those values are entered locally after the VM, paths, permissions and VPN containment are established.
