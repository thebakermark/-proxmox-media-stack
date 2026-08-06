#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo."
[[ -r "$ENV_FILE" ]] || die "$ENV_FILE is missing."
# shellcheck disable=SC1090
source "$ENV_FILE"

cd "$STACK_DIR"
docker compose ps --status running >/dev/null || die "Docker Compose is unavailable."

for service in gluetun qbittorrent jellyfin sonarr radarr prowlarr bazarr seerr; do
  state="$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null || true)"
  [[ "$state" == "running" ]] && pass "$service is running" || die "$service is not running (state: ${state:-missing})"
done

if [[ ",${COMPOSE_PROFILES:-}," == *,iptv,* ]]; then
  for service in dispatcharr tunarr; do
    state="$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null || true)"
    [[ "$state" == "running" ]] && pass "$service is running" || die "$service is not running (state: ${state:-missing})"
  done
  curl -fsS --max-time 10 "http://${BIND_IP}:9191" >/dev/null && pass "Dispatcharr web interface responds" || warn "Dispatcharr is starting or not responding yet"
  curl -fsS --max-time 10 "http://${BIND_IP}:8000" >/dev/null && pass "Tunarr web interface responds" || warn "Tunarr is starting or not responding yet"
fi

GLUETUN_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' gluetun)"
[[ "$GLUETUN_HEALTH" == "healthy" ]] && pass "Gluetun reports a healthy VPN tunnel" || die "Gluetun health is $GLUETUN_HEALTH"

HOST_IP="$(curl -4fsS --max-time 15 https://api.ipify.org)"
VPN_IP="$(docker run --rm --network container:gluetun curlimages/curl:latest -4fsS --max-time 15 https://api.ipify.org)"
[[ -n "$HOST_IP" && -n "$VPN_IP" ]] || die "Could not obtain both public IP addresses."
if [[ "$HOST_IP" == "$VPN_IP" ]]; then
  die "VPN leak test failed: host and torrent network report the same public IP."
fi
pass "Torrent network exits through a different public IP than the VM"

QBIT_NETWORK_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' qbittorrent)"
[[ "$QBIT_NETWORK_MODE" == container:* ]] && pass "qBittorrent shares only Gluetun's network namespace" || die "Unexpected qBittorrent network mode: $QBIT_NETWORK_MODE"

if findmnt -rn /data >/dev/null; then
  pass "/data is a separate mounted filesystem"
else
  warn "/data is not a separate mount; hardlinks may consume the VM OS disk"
fi

test_file="/data/torrents/.hardlink-test-$$"
test_link="/data/media/.hardlink-test-$$"
trap 'rm -f "$test_file" "$test_link"' EXIT
printf 'hardlink-test' > "$test_file"
if ln "$test_file" "$test_link"; then
  inode_a="$(stat -c %i "$test_file")"
  inode_b="$(stat -c %i "$test_link")"
  [[ "$inode_a" == "$inode_b" ]] && pass "Hardlinks work between downloads and media" || die "Hardlink inode test failed"
else
  die "Cannot hardlink between /data/torrents and /data/media"
fi

if [[ -e /dev/dri/renderD128 ]]; then
  pass "GPU render device is visible inside the media VM"
else
  warn "No GPU render device is visible; media transcoding will use the CPU"
fi

pass "Media stack validation completed"
