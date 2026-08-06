# Proxmox Media Stack Installer

This package creates a Debian 13 VM on Proxmox and installs a mapped media
automation stack designed for the Dell Precision T1700 host:

- Jellyfin (enabled by default)
- Plex and Tautulli (optional `plex` profile)
- Sonarr, Radarr, Prowlarr, Bazarr and Seerr (formerly Jellyseerr)
- qBittorrent isolated behind Gluetun and Proton VPN
- Automatic Proton VPN port forwarding into qBittorrent
- Optional Lidarr, Audiobookshelf, SABnzbd and Recyclarr profiles
- Optional Homepage, Dozzle and Uptime Kuma administration profile
- Optional Dispatcharr IPTV/EPG manager and virtual tuner
- Optional Tunarr channels built from the Jellyfin library

The installer deliberately does not configure piracy sources. Add only
indexers and downloads you are legally authorized to use.

## Before starting

1. Install the 1 TB SSD in the T1700 and use it for Proxmox and VM disks.
2. Decide how the several-terabyte disks will be presented as one Proxmox
   storage target. A ZFS pool made from matched disks is the preferred route.
3. Back up any disk containing files. The host script never wipes physical
   disks, and the guest installer refuses disks containing a filesystem.
4. Download a Proton VPN WireGuard configuration for a P2P/port-forwarding
   server. Keep the file private; do not paste its private key into chat.

## Stage 1 — create the VM

Upload this folder to the Proxmox host, open **Shell**, and run:

```bash
chmod +x ./*.sh
sudo ./00-create-proxmox-vm.sh --storage local-lvm
```

To allocate a new data virtual disk from an already-configured Proxmox storage
pool, add its storage ID and desired size:

```bash
sudo ./00-create-proxmox-vm.sh \
  --storage local-lvm \
  --data-storage media-zfs \
  --data-size 6000
```

Defaults are VM ID = next available, 4 vCPU, 6 GiB RAM, 80 GiB OS disk,
DHCP networking on `vmbr0`, and Debian user `mediaadmin`.

The data-size example is only an example. Do not request a volume larger than
the available capacity shown by `pvesm status`.

## Stage 2 — install the applications

Open the new VM's Proxmox console, sign in as `mediaadmin`, copy this package
into the VM, and run:

```bash
chmod +x ./*.sh
sudo ./10-install-media-stack.sh
```

The installer will:

1. Ask for the VM's LAN subnet and IP.
2. Require `/data` to be a separate mount.
3. Offer to format only a completely blank, explicitly selected virtual disk.
4. Install Docker from Docker's official Debian repository.
5. Read the Proton WireGuard configuration locally.
6. Start the core stack.

After installation, change qBittorrent's temporary password and run:

```bash
sudo /opt/media-stack/20-wire-arr-apps.sh
sudo /opt/media-stack/30-verify-stack.sh
```

The wiring script gives Sonarr and Radarr a consistent `/data` view and
connects them to qBittorrent through Gluetun. The verification script confirms
that the host and torrent network have different public IPs and that hardlinks
work.

## Addresses

Replace `MEDIA_VM_IP` with the VM's address.

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

None of these administration ports should be forwarded through the home
router. Use Tailscale or another trusted private-access method when away from
home.

## Optional application groups

Edit `/opt/media-stack/.env` and set `COMPOSE_PROFILES` to a comma-separated
list. Available profiles are:

- `plex` — Plex and Tautulli
- `music` — Lidarr
- `books` — Audiobookshelf
- `usenet` — SABnzbd
- `automation` — Recyclarr
- `admin` — Homepage, Dozzle and Uptime Kuma
- `iptv` — Dispatcharr and Tunarr

Example:

```text
COMPOSE_PROFILES=music,books,admin
```

Then run:

```bash
cd /opt/media-stack
sudo docker compose up -d
```

Do not enable every profile merely because it is available. The T1700 has
16 GiB RAM and also needs capacity for Home Assistant and development VMs.

For IPTV subscription, guide, DVR and custom-channel setup, follow
[IPTV-PVR.md](IPTV-PVR.md). IPTV provider credentials are stored only in
Dispatcharr and are not added to this repository or `.env` file.

## Hardware transcoding

The base configuration works without GPU passthrough. If `/dev/dri/renderD128`
is later exposed to the Debian VM, the installer and update script automatically
apply `compose.intel.yml` to give Jellyfin, Plex, Dispatcharr and Tunarr access
to it. The i7-4790's
Intel HD 4600 is useful for older H.264 workloads but should not be expected to
handle modern HEVC/AV1 transcoding like a newer Intel iGPU.

The NVIDIA NVS 310 should not be used as the media transcoder.

## Updates and backups

Update containers after creating an automatic configuration backup:

```bash
sudo /opt/media-stack/40-update-stack.sh
```

Create a configuration-only backup:

```bash
sudo /opt/media-stack/50-backup-stack.sh
```

These backups exclude the media library. Use Proxmox Backup Server, ZFS
snapshots/replication, or another separate backup target for irreplaceable data.

## What still requires account-specific input

No safe installer can manufacture these credentials or choices:

- Proton WireGuard configuration
- Legal torrent/indexer accounts
- Subtitle-provider credentials
- Jellyfin administrator account
- Optional Plex claim token
- Optional Usenet provider credentials
- IPTV M3U/XMLTV or Xtream Codes credentials

Those are entered through the appropriate local application interface after
the infrastructure, paths, permissions and VPN containment are established.
