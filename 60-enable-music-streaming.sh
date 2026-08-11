#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"
readonly BASE_COMPOSE="${STACK_DIR}/compose.yml"
readonly MUSIC_COMPOSE="${STACK_DIR}/compose.music-streaming.yml"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./60-enable-music-streaming.sh"
[[ -r "$ENV_FILE" ]] || die "Media stack environment not found at $ENV_FILE."
[[ -r "$BASE_COMPOSE" ]] || die "Base compose file not found at $BASE_COMPOSE."
[[ -r "$MUSIC_COMPOSE" ]] || die "Music streaming compose overlay not found at $MUSIC_COMPOSE."

# shellcheck disable=SC1090
source "$ENV_FILE"
: "${PUID:?PUID is required in .env}"
: "${PGID:?PGID is required in .env}"
: "${CONFIG_ROOT:?CONFIG_ROOT is required in .env}"
: "${DATA_ROOT:?DATA_ROOT is required in .env}"
: "${BIND_IP:?BIND_IP is required in .env}"

install -d -m 0775 -o "$PUID" -g "$PGID" "$CONFIG_ROOT/navidrome"
install -d -m 0775 -o "$PUID" -g "$PGID" "$DATA_ROOT/media/music"

info "Validating the combined media + music streaming Compose configuration..."
docker compose \
  --env-file "$ENV_FILE" \
  -f "$BASE_COMPOSE" \
  -f "$MUSIC_COMPOSE" \
  config >/dev/null

info "Starting Lidarr, Aurral, and Navidrome..."
COMPOSE_PROFILES=music docker compose \
  --env-file "$ENV_FILE" \
  -f "$BASE_COMPOSE" \
  -f "$MUSIC_COMPOSE" \
  up -d lidarr aurral navidrome

info "Waiting for Navidrome to answer on port 4533..."
ready="no"
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 3 "http://${BIND_IP}:4533/" >/dev/null 2>&1; then
    ready="yes"
    break
  fi
  sleep 2
done

[[ "$ready" == "yes" ]] || die "Navidrome did not become reachable at http://${BIND_IP}:4533/. Check: docker logs navidrome"

info "Music streaming foundation is running."
info "Navidrome: http://${BIND_IP}:4533/"
info "Lidarr:    http://${BIND_IP}:8686/"
info "Aurral:    http://${BIND_IP}:3001/"
info "Create the initial Navidrome admin account in the web UI, then it will scan ${DATA_ROOT}/media/music automatically."
