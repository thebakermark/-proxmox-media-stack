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

ensure_config_bool() {
  local app="$1" base="$2" key="$3" endpoint="$4" field="$5" desc="$6"
  local config id
  config="$(curl -fsS -H "X-Api-Key: $key" "$base/api/v3/config/$endpoint")"
  if [[ "$(jq -r ".$field" <<<"$config")" == "true" ]]; then
    return
  fi
  id="$(jq -r '.id' <<<"$config")"
  curl -fsS -X PUT -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    --data "$(jq -c ".$field = true" <<<"$config")" \
    "$base/api/v3/config/$endpoint/$id" >/dev/null
  info "$app: enabled $desc."
}

wire_bazarr() {
  local bazarr_config="$STACK_DIR/config/bazarr/config/config.yaml"
  if [[ ! -r "$bazarr_config" ]]; then
    info "Bazarr config not found yet; skipping Bazarr wiring (it may still be starting)."
    return
  fi
  command -v python3 >/dev/null || { info "python3 not found; skipping Bazarr wiring."; return; }

  local already
  already="$(python3 -c "
import yaml
with open('$bazarr_config') as f:
    cfg = yaml.safe_load(f) or {}
g = cfg.get('general', {})
print('yes' if g.get('use_sonarr') and g.get('use_radarr') else 'no')
" 2>/dev/null || echo no)"
  if [[ "$already" == "yes" ]]; then
    info "Bazarr is already connected to Sonarr and Radarr."
    return
  fi

  if python3 -c "
import yaml
path = '$bazarr_config'
with open(path) as f:
    cfg = yaml.safe_load(f)
cfg['sonarr']['apikey'] = '$SONARR_KEY'
cfg['sonarr']['ip'] = 'sonarr'
cfg['radarr']['apikey'] = '$RADARR_KEY'
cfg['radarr']['ip'] = 'radarr'
cfg['general']['use_sonarr'] = True
cfg['general']['use_radarr'] = True
with open(path, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=True)
" 2>/dev/null; then
    docker restart bazarr >/dev/null 2>&1 || true
    info "Connected Bazarr to Sonarr and Radarr (restarted Bazarr to apply)."
  else
    info "Could not update Bazarr's configuration; leaving it untouched. Connect it manually in Bazarr's Settings > Sonarr/Radarr."
  fi
}

wire_seerr() {
  local seerr_base="http://${LOCAL_HOST}:5055"
  local initialized
  initialized="$(curl -fsS "$seerr_base/api/v1/settings/public" 2>/dev/null | jq -r '.initialized // empty')"
  if [[ "$initialized" != "true" ]]; then
    info "Seerr has not completed its own setup yet (it needs to be connected to Jellyfin first, in its own UI)."
    info "Once you've done that, Seerr's Settings > Services page is where to add Sonarr and Radarr --"
    info "Seerr has no service-account API key, only an admin login, so this step can't be automated here."
    return
  fi
  info "Seerr setup is complete. Add Sonarr (http://sonarr:8989, key ${SONARR_KEY}) and Radarr"
  info "(http://radarr:7878, key ${RADARR_KEY}) under Seerr's Settings > Services -- this needs your"
  info "Seerr admin login, so it isn't automated here either."
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

QBIT_USER="${QBIT_USERNAME:-admin}"
if [[ -z "${QBIT_PASSWORD:-}" ]]; then
  # Older installs (or a manually-cleared credential) won't have this in
  # .env -- fall back to asking, same as before.
  read -r -p "qBittorrent username [admin]: " input_user
  QBIT_USER="${input_user:-admin}"
  read -r -s -p "qBittorrent password: " QBIT_PASSWORD
  printf '\n'
  [[ -n "$QBIT_PASSWORD" ]] || die "qBittorrent password cannot be blank."
fi
ensure_qbittorrent Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" tvCategory tv "$QBIT_USER" "$QBIT_PASSWORD"
ensure_qbittorrent Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" movieCategory movies "$QBIT_USER" "$QBIT_PASSWORD"
unset QBIT_PASSWORD

PROWLARR_KEY="$(wait_for_key Prowlarr "$STACK_DIR/config/prowlarr/config.xml")"
ensure_prowlarr_application Sonarr Sonarr "http://sonarr:8989" "$SONARR_KEY"
ensure_prowlarr_application Radarr Radarr "http://radarr:7878" "$RADARR_KEY"

ensure_config_bool Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" mediamanagement copyUsingHardlinks "hardlink imports"
ensure_config_bool Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" naming renameEpisodes "automatic file renaming"
ensure_config_bool Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" mediamanagement copyUsingHardlinks "hardlink imports"
ensure_config_bool Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" naming renameMovies "automatic file renaming"

wire_bazarr
wire_seerr

info "Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent and the shared /data paths are connected."
info "Add only your authorized indexers in Prowlarr; they will synchronize into Sonarr and Radarr."
