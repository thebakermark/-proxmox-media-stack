#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SOURCE_DIR
readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

AUTO_DATA_DISK="no"
for arg in "$@"; do
  case "$arg" in
    --auto-data-disk) AUTO_DATA_DISK="yes" ;;
    *) die "Unknown option: $arg" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./10-install-media-stack.sh"
[[ -r /etc/os-release ]] || die "This installer requires Ubuntu Server 26.04 LTS."
[[ ! -e "$ENV_FILE" ]] || die "An installation already exists at $STACK_DIR. Use 40-update-stack.sh instead of reinstalling."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu Server 26.04 LTS."
[[ "${VERSION_ID:-}" == "26.04" ]] || die "Expected Ubuntu 26.04 LTS; detected ${PRETTY_NAME:-unknown OS}."

TARGET_USER="${SUDO_USER:-mediaadmin}"
id "$TARGET_USER" >/dev/null 2>&1 || die "User '$TARGET_USER' does not exist."
PUID="$(id -u "$TARGET_USER")"
PGID="$(id -g "$TARGET_USER")"
TZ_VALUE="America/Chicago"
DATA_ROOT="/data"
CONFIG_ROOT="/opt/media-stack/config"
LAN_SUBNET=""
BIND_IP="0.0.0.0"
PROTON_COUNTRIES="United States"

default_subnet="$(ip -4 route show scope link | awk '$1 ~ /^[0-9]+\./ {print $1; exit}')"
read -r -p "LAN subnet [${default_subnet:-192.168.1.0/24}]: " LAN_SUBNET
LAN_SUBNET="${LAN_SUBNET:-${default_subnet:-192.168.1.0/24}}"

default_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
read -r -p "VM IP to bind application ports [${default_ip:-0.0.0.0}]: " BIND_IP
BIND_IP="${BIND_IP:-${default_ip:-0.0.0.0}}"

# TESTABLE:BEGIN — pure/read-only logic, unit tested by tests/run-tests.sh
device_is_verified_blank() {
  local device="$1"
  [[ -b "$device" ]] || return 1
  [[ "$(lsblk -dn -o TYPE "$device")" == "disk" ]] || return 1
  lsblk -nr -o MOUNTPOINTS "$device" | grep -q '/' && return 1
  [[ -z "$(blkid "$device" 2>/dev/null || true)" ]] || return 1
  [[ -z "$(lsblk -n -o FSTYPE "$device" | tr -d '[:space:]')" ]] || return 1
  return 0
}

format_and_mount_data_disk() {
  local device="$1"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y e2fsprogs
  mkfs.ext4 -L media-data -m 0 "$device"
  local uuid
  uuid="$(blkid -s UUID -o value "$device")"
  [[ -n "$uuid" ]] || die "Unable to determine the new filesystem UUID."
  printf 'UUID=%s /data ext4 defaults,noatime 0 2\n' "$uuid" >> /etc/fstab
  mount "$DATA_ROOT"
}

find_sole_blank_secondary_disk() {
  local root_source root_disk candidate candidates=() match=""
  root_source="$(findmnt -no SOURCE / 2>/dev/null || true)"
  root_disk="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  while IFS= read -r candidate; do
    [[ -n "$candidate" && "$candidate" != "$root_disk" ]] && candidates+=("$candidate")
  done < <(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}')
  [[ "${#candidates[@]}" -eq 1 ]] || return 1
  match="/dev/${candidates[0]}"
  device_is_verified_blank "$match" && printf '%s' "$match"
}
# TESTABLE:END

configure_data_mount() {
  install -d -m 0775 "$DATA_ROOT"
  if mountpoint -q "$DATA_ROOT"; then
    info "$DATA_ROOT is already a mounted filesystem."
    return
  fi

  info "$DATA_ROOT is not a separate mounted filesystem."

  if [[ "$AUTO_DATA_DISK" == "yes" ]]; then
    local auto_device
    if auto_device="$(find_sole_blank_secondary_disk)"; then
      info "Automatically formatting the blank data disk provisioned by the Proxmox installer: $auto_device"
      format_and_mount_data_disk "$auto_device"
      return
    fi
    info "Could not automatically identify a single verified-blank secondary disk; falling back to manual selection."
  fi

  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
  read -r -p "Enter a BLANK data device to format and mount (example /dev/sdb), or press Enter to stop: " DATA_DEVICE
  [[ -n "$DATA_DEVICE" ]] || die "Stopped without changing storage. Attach or mount the media data disk and rerun."
  device_is_verified_blank "$DATA_DEVICE" || die "$DATA_DEVICE is not a whole, unmounted, signature-free block device. The installer will not erase it."
  read -r -p "Type the exact device path '$DATA_DEVICE' to authorize formatting this blank disk: " CONFIRM_DEVICE
  [[ "$CONFIRM_DEVICE" == "$DATA_DEVICE" ]] || die "Device confirmation did not match."

  format_and_mount_data_disk "$DATA_DEVICE"
}

configure_data_mount

info "Installing Docker Engine from Docker's official Ubuntu repository..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg jq openssl qemu-guest-agent
systemctl enable --now qemu-guest-agent
install -m 0755 -d /etc/apt/keyrings
curl --fail --silent --show-error --location https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker "$TARGET_USER"

install -d -m 0750 "$STACK_DIR" "$CONFIG_ROOT"
install -m 0644 "$SOURCE_DIR/compose.yml" "$STACK_DIR/compose.yml"
install -m 0644 "$SOURCE_DIR/compose.intel.yml" "$STACK_DIR/compose.intel.yml"
install -m 0644 "$SOURCE_DIR/IPTV-PVR.md" "$STACK_DIR/IPTV-PVR.md"
install -m 0755 "$SOURCE_DIR/20-wire-arr-apps.sh" "$STACK_DIR/20-wire-arr-apps.sh"
install -m 0755 "$SOURCE_DIR/30-verify-stack.sh" "$STACK_DIR/30-verify-stack.sh"
install -m 0755 "$SOURCE_DIR/40-update-stack.sh" "$STACK_DIR/40-update-stack.sh"
install -m 0755 "$SOURCE_DIR/50-backup-stack.sh" "$STACK_DIR/50-backup-stack.sh"

for path in \
  torrents/movies torrents/tv torrents/music torrents/books \
  usenet/incomplete usenet/complete/movies usenet/complete/tv usenet/complete/music usenet/complete/books \
  media/movies media/tv media/music media/books media/audiobooks media/podcasts; do
  install -d -m 0775 -o "$PUID" -g "$PGID" "$DATA_ROOT/$path"
done

for path in recordings/movies recordings/shows recordings/sports recordings/manual; do
  install -d -m 0775 -o "$PUID" -g "$PGID" "$DATA_ROOT/$path"
done

for app in gluetun qbittorrent jellyfin sonarr radarr prowlarr bazarr seerr plex tautulli lidarr audiobookshelf sabnzbd recyclarr homepage uptime-kuma dispatcharr tunarr; do
  install -d -m 0775 -o "$PUID" -g "$PGID" "$CONFIG_ROOT/$app"
done

RENDER_GID="$(getent group render | cut -d: -f3 || true)"
RENDER_GID="${RENDER_GID:-109}"
DISPATCHARR_SECRET_KEY="$(openssl rand -hex 32)"

info "Provide a Proton VPN WireGuard configuration downloaded from your Proton account (a P2P/port-forwarding server)."
info "Paste its full contents below and finish with Ctrl-D on an empty line,"
info "or type the path to a .conf file already present on this VM and press Ctrl-D."
PROTON_INPUT="$(cat)"
if [[ "$PROTON_INPUT" != *$'\n'* && -r "$PROTON_INPUT" ]]; then
  PROTON_CONFIG_CONTENT="$(cat -- "$PROTON_INPUT")"
else
  PROTON_CONFIG_CONTENT="$PROTON_INPUT"
fi
PROTON_PRIVATE_KEY="$(awk -F' *= *' '$1=="PrivateKey" {print $2; exit}' <<<"$PROTON_CONFIG_CONTENT")"
PROTON_ADDRESSES="$(awk -F' *= *' '$1=="Address" {gsub(/ /, "", $2); print $2; exit}' <<<"$PROTON_CONFIG_CONTENT")"
[[ -n "$PROTON_PRIVATE_KEY" ]] || die "PrivateKey was not found in the Proton configuration."
[[ -n "$PROTON_ADDRESSES" ]] || die "Address was not found in the Proton configuration."
unset PROTON_INPUT PROTON_CONFIG_CONTENT

cat > "$ENV_FILE" <<EOF
PUID=${PUID}
PGID=${PGID}
TZ=${TZ_VALUE}
BIND_IP=${BIND_IP}
LAN_SUBNET=${LAN_SUBNET}
DATA_ROOT=${DATA_ROOT}
CONFIG_ROOT=${CONFIG_ROOT}
RENDER_GID=${RENDER_GID}
PROTON_WIREGUARD_PRIVATE_KEY=${PROTON_PRIVATE_KEY}
PROTON_WIREGUARD_ADDRESSES=${PROTON_ADDRESSES}
PROTON_SERVER_COUNTRIES=${PROTON_COUNTRIES}
DISPATCHARR_SECRET_KEY=${DISPATCHARR_SECRET_KEY}
PLEX_CLAIM=
COMPOSE_PROFILES=
EOF
chmod 0600 "$ENV_FILE"
unset PROTON_PRIVATE_KEY

install -d -m 0775 -o "$PUID" -g "$PGID" "$CONFIG_ROOT/qbittorrent/qBittorrent"
cat > "$CONFIG_ROOT/qbittorrent/qBittorrent/qBittorrent.conf" <<'EOF'
[Preferences]
Downloads\SavePath=/data/torrents/
WebUI\Address=*
WebUI\LocalHostAuth=false
WebUI\Port=8080
WebUI\ServerDomains=*
Connection\UPnP=false
Connection\RandomPort=false
EOF
chown "$PUID:$PGID" "$CONFIG_ROOT/qbittorrent/qBittorrent/qBittorrent.conf"
chmod 0660 "$CONFIG_ROOT/qbittorrent/qBittorrent/qBittorrent.conf"

COMPOSE_ARGS=(-f "$STACK_DIR/compose.yml")
if [[ -e /dev/dri/renderD128 ]]; then
  info "Intel/DRM render device detected; enabling the hardware-acceleration override."
  COMPOSE_ARGS+=(-f "$STACK_DIR/compose.intel.yml")
else
  info "No /dev/dri/renderD128 was detected. Jellyfin will start without GPU passthrough."
fi

cd "$STACK_DIR"
docker compose "${COMPOSE_ARGS[@]}" config --quiet
docker compose "${COMPOSE_ARGS[@]}" pull
docker compose "${COMPOSE_ARGS[@]}" up -d

sleep 8
QBIT_PASSWORD="$(docker logs qbittorrent 2>&1 | sed -n 's/.*temporary password is provided for this session: //p' | tail -1 || true)"

chown -R "$PUID:$PGID" "$CONFIG_ROOT"
info "Core media stack installation is complete."
info "Jellyfin:    http://${BIND_IP}:8096"
info "Seerr:       http://${BIND_IP}:5055"
info "Sonarr:      http://${BIND_IP}:8989"
info "Radarr:      http://${BIND_IP}:7878"
info "Prowlarr:    http://${BIND_IP}:9696"
info "Bazarr:      http://${BIND_IP}:6767"
info "qBittorrent: http://${BIND_IP}:8080 (username: admin)"
info "Optional IPTV: set COMPOSE_PROFILES=iptv in ${ENV_FILE}, then run docker compose up -d"
if [[ -n "$QBIT_PASSWORD" ]]; then
  info "qBittorrent temporary password: $QBIT_PASSWORD"
else
  info "Get the qBittorrent temporary password with: docker logs qbittorrent"
fi
info "Change the qBittorrent password immediately, then run: sudo ${STACK_DIR}/20-wire-arr-apps.sh"
info "Finally verify VPN containment with: sudo ${STACK_DIR}/30-verify-stack.sh"
