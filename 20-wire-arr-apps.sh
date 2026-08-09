#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo."
command -v jq >/dev/null || die "jq is required."
[[ -r "$ENV_FILE" ]] || die "$ENV_FILE is missing. Run 10-install-media-stack.sh first."
# shellcheck disable=SC1090
source "$ENV_FILE"

# Docker only listens on the exact address a port was published on. If
# BIND_IP is a specific interface (the installer's own suggested default,
# not 0.0.0.0), 127.0.0.1 is a *different* address and connections to it
# are refused -- use the same host the apps were actually published on.
readonly LOCAL_HOST="${BIND_IP:-127.0.0.1}"

read_api_key() {
  local config_file="$1"
  sed -n 's:.*<ApiKey>\([^<]*\)</ApiKey>.*:\1:p' "$config_file" | head -1
}

wait_for_key() {
  local app="$1" file="$2" attempts=0 key=""
  while ((attempts < 30)); do
    if [[ -r "$file" ]]; then
      key="$(read_api_key "$file")"
      [[ -n "$key" ]] && { printf '%s' "$key"; return 0; }
    fi
    sleep 2
    ((attempts+=1))
  done
  die "Timed out waiting for $app to create $file"
}

SONARR_KEY="$(wait_for_key Sonarr "$STACK_DIR/config/sonarr/config.xml")"
RADARR_KEY="$(wait_for_key Radarr "$STACK_DIR/config/radarr/config.xml")"

ensure_root_folder() {
  local base="$1" key="$2" path="$3"
  if ! curl -fsS -H "X-Api-Key: $key" "$base/api/v3/rootfolder" | jq -e --arg path "$path" '.[] | select(.path == $path)' >/dev/null; then
    curl -fsS -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg path "$path" '{path:$path}')" "$base/api/v3/rootfolder" >/dev/null
    info "Added root folder $path"
  fi
}

ensure_qbittorrent() {
  local app="$1" base="$2" key="$3" category_field="$4" category="$5" qbit_user="$6" qbit_password="$7"
  if curl -fsS -H "X-Api-Key: $key" "$base/api/v3/downloadclient" | jq -e '.[] | select(.name == "qBittorrent via Proton VPN")' >/dev/null; then
    info "$app already has its VPN qBittorrent client."
    return
  fi

  local schema payload
  schema="$(curl -fsS -H "X-Api-Key: $key" "$base/api/v3/downloadclient/schema")"
  payload="$(jq -c \
    --arg category_field "$category_field" --arg category "$category" \
    --arg qbit_user "$qbit_user" --arg qbit_password "$qbit_password" \
    '([.[] | select((.implementation | ascii_downcase) == "qbittorrent")][0])
     | .name = "qBittorrent via Proton VPN"
     | .enable = true
     | .priority = 1
     | .fields |= map(
         if .name == "host" then .value = "gluetun"
         elif .name == "port" then .value = 8080
         elif .name == "useSsl" then .value = false
         elif .name == "username" then .value = $qbit_user
         elif .name == "password" then .value = $qbit_password
         elif .name == $category_field then .value = $category
         else . end)' <<<"$schema")"
  [[ "$payload" != "null" ]] || die "Could not find the qBittorrent schema for $app."
  curl -fsS -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    --data "$payload" "$base/api/v3/downloadclient" >/dev/null
  info "Connected $app to qBittorrent through Gluetun."
}

ensure_prowlarr_application() {
  local name="$1" implementation="$2" app_url="$3" app_key="$4"
  local prowlarr_base="http://${LOCAL_HOST}:9696"
  if curl -fsS -H "X-Api-Key: $PROWLARR_KEY" "$prowlarr_base/api/v1/applications" | jq -e --arg name "$name" '.[] | select(.name == $name)' >/dev/null; then
    info "Prowlarr is already connected to $name."
    return
  fi

  local schema payload
  schema="$(curl -fsS -H "X-Api-Key: $PROWLARR_KEY" "$prowlarr_base/api/v1/applications/schema")"
  payload="$(jq -c \
    --arg implementation "$implementation" --arg name "$name" \
    --arg app_url "$app_url" --arg app_key "$app_key" \
    '([.[] | select((.implementation | ascii_downcase) == ($implementation | ascii_downcase))][0])
     | .name = $name
     | .enable = true
     | .syncLevel = "fullSync"
     | .fields |= map(
         if .name == "baseUrl" then .value = $app_url
         elif .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
         elif .name == "apiKey" then .value = $app_key
         else . end)' <<<"$schema")"
  [[ "$payload" != "null" ]] || die "Could not find the $implementation application schema in Prowlarr."
  curl -fsS -X POST -H "X-Api-Key: $PROWLARR_KEY" -H 'Content-Type: application/json' \
    --data "$payload" "$prowlarr_base/api/v1/applications" >/dev/null
  info "Connected Prowlarr to $name."
}

ensure_root_folder "http://${LOCAL_HOST}:8989" "$SONARR_KEY" "/data/media/tv"
ensure_root_folder "http://${LOCAL_HOST}:7878" "$RADARR_KEY" "/data/media/movies"
read -r -p "qBittorrent username [admin]: " QBIT_USER
QBIT_USER="${QBIT_USER:-admin}"
read -r -s -p "qBittorrent password (the permanent password you just set): " QBIT_PASSWORD
printf '\n'
[[ -n "$QBIT_PASSWORD" ]] || die "qBittorrent password cannot be blank."
ensure_qbittorrent Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" tvCategory tv "$QBIT_USER" "$QBIT_PASSWORD"
ensure_qbittorrent Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" movieCategory movies "$QBIT_USER" "$QBIT_PASSWORD"
unset QBIT_PASSWORD

PROWLARR_KEY="$(wait_for_key Prowlarr "$STACK_DIR/config/prowlarr/config.xml")"
ensure_prowlarr_application Sonarr Sonarr "http://sonarr:8989" "$SONARR_KEY"
ensure_prowlarr_application Radarr Radarr "http://radarr:7878" "$RADARR_KEY"

info "Sonarr, Radarr, Prowlarr, qBittorrent and the shared /data paths are connected."
info "Add only your authorized indexers in Prowlarr; they will synchronize into Sonarr and Radarr."
