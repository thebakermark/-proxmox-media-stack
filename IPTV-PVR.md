# IPTV, program guide and DVR setup

This integration is for an IPTV subscription and content you are authorized to
access. The repository does not contain playlists, channels, account
credentials or guide data.

## Architecture

```text
IPTV subscription ──> Dispatcharr ──> Jellyfin Live TV ──> /recordings
                              ^
Jellyfin library ──> Tunarr ──┘
```

Dispatcharr is the single IPTV-management layer. It filters and organizes the
provider lineup, maps EPG data, limits concurrent streams and presents a clean
M3U/XMLTV or HDHomeRun-compatible output to Jellyfin. Tunarr is optional: it
creates scheduled channels from media already stored in Jellyfin.

IPTV does not share qBittorrent's Gluetun network. This is intentional. Only
the torrent client is forced through Proton VPN; routing live television
through the VPN adds latency and can conflict with provider location rules.

## Enable the profile

Edit `/opt/media-stack/.env`:

```text
COMPOSE_PROFILES=iptv
```

Profiles can be combined:

```text
COMPOSE_PROFILES=iptv,music,books,admin
```

Start the new services:

```bash
cd /opt/media-stack
sudo docker compose up -d
sudo /opt/media-stack/30-verify-stack.sh
```

Open:

- Dispatcharr: `http://MEDIA_VM_IP:9191`
- Tunarr: `http://MEDIA_VM_IP:8000`

## Configure Dispatcharr

1. Create the local Dispatcharr administrator account.
2. Add the subscription as either **Standard M3U** or **Xtream Codes**.
3. Enter the subscription credentials only in Dispatcharr.
4. Set **Max Streams** to the exact simultaneous-connection count purchased
   from the provider. Never set unlimited unless the plan explicitly allows it.
5. Select only the channel groups the family actually uses.
6. Add the provider's XMLTV/EPG source.
7. Match channels to guide entries and remove duplicates, adult groups,
   shopping channels and unwanted regional groups.
8. Copy the clean M3U and XMLTV output URLs shown by Dispatcharr. Do not publish
   URLs containing usernames, passwords or access tokens.

Prefer direct/pass-through stream profiles on the T1700. Use FFmpeg
transcoding only for channels that have incompatible audio or containers; the
i7-4790 is not an efficient modern live transcoder.

## Add Dispatcharr to Jellyfin

In Jellyfin, open **Dashboard → Live TV**.

1. Add a **M3U Tuner**.
2. Paste the clean M3U URL copied from Dispatcharr.
3. Set the simultaneous stream limit to the subscription's purchased limit.
4. Add an **XMLTV** guide provider using Dispatcharr's clean XMLTV URL.
5. Refresh guide data and inspect channel mapping.
6. Under DVR/recording settings, use `/recordings` as the recording root.

The host directories are created automatically:

```text
/data/recordings
├── manual
├── movies
├── shows
└── sports
```

Jellyfin sees that directory as `/recordings`. Plex, when its optional profile
is enabled, sees the same files under `/data/recordings`.

## Create family channels with Tunarr

1. Create a Jellyfin API key under **Dashboard → API Keys**.
2. In Tunarr, add Jellyfin using `http://jellyfin:8096` and that API key.
3. Build channels such as Family Movie Night, Saturday Morning Cartoons,
   Christmas Movies or Random Sitcoms.
4. Configure schedules, filler and channel logos.
5. Copy Tunarr's generated M3U and XMLTV URLs.
6. Import those URLs into Dispatcharr so subscription and custom channels share
   one organized lineup, or add Tunarr as a second tuner in Jellyfin.

Keep the API key private. If it is accidentally published, revoke it in
Jellyfin and create a new one.

## Recording and storage guidance

- Recording one channel consumes one provider connection.
- Watching another channel while recording generally consumes a second.
- Recordings can be large; monitor `/data` capacity in Proxmox.
- Do not record directly to the VM's operating-system disk.
- Back up irreplaceable recordings separately from disposable live-TV content.
- Use direct stream whenever possible to reduce CPU use and preserve quality.

## Remote access and security

Do not forward ports 9191, 8000 or the Jellyfin administration interface from
the router. Use Tailscale or another private remote-access method. Keep IPTV
credentials out of screenshots, issue reports, Git commits and support logs.

