# Music Streaming + Ad Blocking Architecture

This stack separates three responsibilities so a failure or policy change in one does not take down the others.

## 1. Local music: Navidrome + Lidarr + Aurral

- **Lidarr** manages permanent local music acquisition and organization.
- **Aurral** provides music discovery and recommendations and is already wired to Lidarr.
- **Navidrome** streams the local library to web, mobile, desktop, and Subsonic/OpenSubsonic-compatible clients.
- Local music lives at `/data/media/music` and Navidrome mounts it read-only.

Enable the foundation from a checkout of this repository on the media VM:

```bash
sudo ./60-enable-music-streaming.sh
```

Navidrome is then available on port `4533` and creates its first administrator from the web UI.

## 2. Future request/orchestration app

The planned request app should be a provider-neutral orchestrator, not a YouTube downloader.

Request flow:

1. User searches for a song, album, artist, playlist, or station.
2. Resolver checks the local Navidrome catalog first.
3. If local media exists, play it from Navidrome.
4. Otherwise resolve a permitted external playback provider.
5. Offer **Add to Library** to send a permanent acquisition request to Lidarr.
6. Future requests prefer the local copy once Lidarr imports it.

Core domain objects should include:

- users / household profiles
- tracks, artists, albums
- playlists and collaborative playlists
- queue entries and voting
- radio/station definitions
- playback providers
- playback targets
- request history
- parental/explicit-content policy
- library acquisition requests

Provider adapters should be independently replaceable. Initial candidates:

- Navidrome/OpenSubsonic: local playback
- Lidarr: acquisition
- Aurral/ListenBrainz-style sources: discovery
- YouTube official player/API: external playback where permitted
- Invidious: optional experimental provider, never a required dependency

Do not build the application around ripping or extracting YouTube audio. Keep external playback and local-library acquisition as separate paths.

## 3. Network ad blocking: AdGuard Home

AdGuard Home should run as a **separate Proxmox service**, not inside the media VM.

Reasons:

- DNS should remain available while the media VM is restarting or being upgraded.
- Network-wide DNS is infrastructure, not a media application dependency.
- A dedicated service can retain clean networking and client identity.
- Router/DHCP can point the household LAN to this DNS service independently of the media stack.

Recommended deployment target:

- dedicated lightweight Proxmox LXC or VM
- static LAN IP
- AdGuard Home stable release
- upstream DNS chosen independently
- router DHCP advertises the AdGuard IP as DNS
- remote administration restricted to LAN/Tailscale

AdGuard Home handles DNS-level ad/tracker/malware filtering. It should not be represented as a guaranteed YouTube video-ad blocker.

## 4. Invidious position

Invidious remains optional. Its current production deployment includes PostgreSQL and Invidious Companion and has materially higher operational overhead than Navidrome. It should therefore be isolated behind an optional profile/service boundary and must never be required for local music playback.

## Implementation order

1. Navidrome local streaming foundation. **Started in this branch.**
2. Add Navidrome to Hubarr and stack verification.
3. Add a dedicated AdGuard Home Proxmox helper/install path.
4. Define the music orchestrator API and provider interfaces.
5. Implement local-library search/playback and Lidarr `Add to Library` first.
6. Add YouTube official playback adapter.
7. Evaluate Invidious as an optional experimental adapter.
8. Add household queues, playlists, radio/stations, voting, profiles, and policy controls.
