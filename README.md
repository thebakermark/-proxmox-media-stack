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

The bootstrap script downloads the current repository, creates the Ubuntu VM, then
automatically waits for it to boot and continues setup inside the guest over SSH —
no separate console login is required. You stay at the same terminal for the whole
installation and are only prompted for account-specific input (the `mediaadmin`
password, LAN/IP settings, your Proton VPN WireGuard configuration, and whether to
run the app-wiring and verification steps).

A dedicated SSH key is generated on the Proxmox host at
`/root/.proxmox-media-stack/id_ed25519` and installed into the guest via cloud-init
so `install.sh` can finish the job without any manual copy/paste. If the VM cannot
be reached automatically (for example, a firewalled or isolated VLAN), the script
prints the exact manual fallback commands instead of hanging.

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

## Manual step-by-step (optional)

Prefer to run each stage yourself, or need to recover from an interrupted automatic
run? Clone the repository and drive it stage by stage instead of using `install.sh`.

### Stage 1 — create the Ubuntu VM

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
9. Generates a dedicated SSH key and installs it into the guest via cloud-init.
10. Starts the VM.

Run standalone like this, it only creates the VM; it does not continue into the
guest automatically (that orchestration lives in `install.sh`).

### Stage 2 — install the applications inside Ubuntu

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
2. Require `/data` to be a separate mounted filesystem. If a blank virtual disk was
   provisioned by `00-create-proxmox-vm.sh --data-storage ...`, pass
   `--auto-data-disk` to format it automatically without a manual confirmation
   step — the installer only auto-formats a disk it can independently re-verify
   is blank; anything else still requires an explicit, typed confirmation.
3. Otherwise offer to format only a completely blank, explicitly selected virtual disk.
4. Install QEMU Guest Agent.
5. Install Docker Engine and Compose from Docker's official Ubuntu repository.
6. Ask for your Proton VPN WireGuard configuration — paste its contents directly
   (finish with Ctrl-D), or point it at a `.conf` file already on the VM. The key
   is validated (must be a real 44-character key, not a masked placeholder) before
   it's written anywhere, so a bad paste fails immediately with a clear message
   instead of silently breaking Gluetun later.
7. Create the media/download directory structure.
8. Start the core stack.

When run through `install.sh`, all of this happens automatically over the SSH
session it opens into the guest — steps 6 (the interactive prompts above) are the
only place you need to type or paste anything.

**If Gluetun ever fails to start** because the Proton config was wrong (a common
cause: Proton, like WireGuard generally, only shows a profile's real private key
once, at creation — re-opening or re-downloading an existing profile shows it
masked), fix just that piece without reinstalling anything else:

```bash
sudo /opt/media-stack/fix-proton-vpn.sh
```

qBittorrent's WebUI password is generated automatically during install (a machine
credential for internal API calls, printed at the end of `10-install-media-stack.sh`
and saved in `.env`) — no need to change it before continuing. Then run:

```bash
sudo /opt/media-stack/20-wire-arr-apps.sh
sudo /opt/media-stack/30-verify-stack.sh
```

The wiring script gives Sonarr and Radarr a consistent `/data` view; connects them
to qBittorrent through Gluetun; enables hardlink imports and automatic file renaming
in both; connects Bazarr to both; **completes Jellyfin's own setup wizard** (creates
an admin account — another generated machine credential, printed and saved in `.env`
the same way as qBittorrent's — and adds Movies/TV Shows/Music libraries pointed at
`/media/...`); and **connects Seerr to Jellyfin and to Sonarr/Radarr automatically**,
using that same generated Jellyfin login (Seerr's first Jellyfin connection doubles
as bootstrapping its own admin user, so no manual clicking is needed there either).
The verification script confirms the host and torrent network have different public
IPs and that hardlinks work.

It also **secures each app's own WebUI login** instead of leaving them open on the
LAN: Sonarr, Radarr, Prowlarr and Bazarr each get a dedicated username
(`sonarradmin`, `radarradmin`, `prowlarradmin`, `bazarradmin`) and one shared
generated password, saved as `APP_ADMIN_PASSWORD` in `.env` — retrieve it with
`sudo grep APP_ADMIN_PASSWORD /opt/media-stack/.env`. Sonarr, Radarr and Prowlarr
only require that login from *outside* the LAN (`disabledForLocalAddresses`), so
browsing to them from your own network stays password-free; Bazarr has no
equivalent local-address bypass, so it always prompts. Re-running the script is
idempotent and leaves an already-configured app alone.

After this script finishes, Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Seerr, and
qBittorrent are all fully wired to each other — the only things left are genuinely
account-specific: your legal indexers in Prowlarr, optional subtitle providers in
Bazarr, and (if you'd rather not use the generated one) changing Jellyfin's admin
password to something memorable. If you do change it, re-running
`20-wire-arr-apps.sh` will notice its saved copy is out of date, skip re-linking
Seerr with a clear message instead of failing, and leave everything else untouched
— just update `JELLYFIN_PASSWORD` in `.env` (or reconnect Seerr by hand) if you want
the automation to pick it back up.

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

## Verifying stack health

Run the acceptance test any time to check the whole stack — OS version, Docker,
every core container and its healthcheck, VPN tunnel and leak test, port
forwarding, kill-switch posture, `/data` mount and free space, permissions,
hardlink capability (both on the host and inside the Sonarr/Radarr/qBittorrent
containers), listening ports and the QEMU guest agent:

```bash
sudo /opt/media-stack/30-verify-stack.sh
```

It prints `PASS`/`WARN`/`FAIL` for each check and finishes with an executive
summary — `MEDIA STACK: HEALTHY` or `MEDIA STACK: ATTENTION REQUIRED` followed by
exactly which checks failed and how to fix them. It exits `0` when healthy and `1`
when attention is required, so it can be wired into monitoring or a cron job.

## Updates and backups

Update containers after creating an automatic configuration backup. The script
records each core service's current image, waits for the new containers to report
healthy, and automatically rolls back to the previous images if they don't:

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
- legal torrent/indexer accounts (Prowlarr)
- subtitle-provider credentials (Bazarr, optional)
- optional Plex claim token
- optional Usenet provider credentials
- IPTV M3U/XMLTV or Xtream Codes credentials

Jellyfin's admin account and its connections to Seerr, Sonarr, and Radarr, plus the
Sonarr/Radarr/Prowlarr/Bazarr WebUI logins, are all created automatically by
`20-wire-arr-apps.sh` (see above) — nothing left to manually click through there
unless you want to change a generated password.

Those values are entered locally after the VM, paths, permissions and VPN containment are established. When installed via `install.sh`, you enter them right in that same terminal session — there is no separate console login step.

## Continuous integration

Every push and pull request runs `.github/workflows/validate.yml`:

- Bash syntax check (`bash -n`) and ShellCheck on every script.
- `docker compose config` validation, including assertions that qBittorrent's
  resolved configuration is network-isolated behind Gluetun (`network_mode:
  service:gluetun`, no independent `networks:`/`ports:`, and it waits on Gluetun's
  healthcheck).
- Gitleaks secret scanning across the full git history.
- `tests/run-tests.sh`: static/unit tests for the Ubuntu checksum-manifest parsing,
  OS-version gating, the blank-disk safety check (exercised against a real kernel
  block device in CI, not a mock), `.env` variable consistency between
  `compose.yml` and the installer, and the documented Compose profile list.
