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

SEERR_COOKIE_JAR="$(mktemp)"
trap 'rm -f "$SEERR_COOKIE_JAR"' EXIT

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

# Jellyfin's admin account is a machine credential in the same sense as
# QBIT_PASSWORD above -- auto-generated, saved in .env, printed for you to
# change later if you want a memorable password. This is what actually lets
# Seerr bootstrap itself below without any manual clicking: it authenticates
# to Jellyfin with these same credentials on first connection.
setup_jellyfin() {
  local base="http://${LOCAL_HOST}:8096"
  local completed

  # Jellyfin's container can report "running" for a few seconds before its
  # web server has fully initialized (caught live: 503s right after start).
  # /System/Info/Public is the only endpoint that's unauthenticated in both
  # fresh and already-configured states -- /Startup/* requires auth once
  # the wizard is complete, which broke this check on an idempotent re-run.
  local ready="no"
  for _ in $(seq 1 30); do
    completed="$(curl -fsS "$base/System/Info/Public" 2>/dev/null | jq -r '.StartupWizardCompleted // empty')"
    [[ -n "$completed" ]] && { ready="yes"; break; }
    sleep 2
  done
  if [[ "$ready" != "yes" ]]; then
    info "Jellyfin: never became ready; skipping automatic setup. Complete its wizard manually."
    return
  fi

  if [[ "$completed" != "true" ]]; then
    curl -fsS -X POST -H 'Content-Type: application/json' \
      --data '{"ServerName":"media-stack","UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' \
      "$base/Startup/Configuration" >/dev/null

    # GET /Startup/User triggers Jellyfin's user-manager initialization,
    # which creates an implicit first user; POST /Startup/User (which
    # renames it and sets its password) 404s without this first.
    curl -fsS "$base/Startup/User" >/dev/null

    JELLYFIN_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
    curl -fsS -X POST -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg n admin --arg p "$JELLYFIN_PASSWORD" '{Name:$n,Password:$p}')" \
      "$base/Startup/User" >/dev/null
    curl -fsS -X POST -H 'Content-Type: application/json' \
      --data '{"EnableRemoteAccess":true}' \
      "$base/Startup/RemoteAccess" >/dev/null
    curl -fsS -X POST "$base/Startup/Complete" >/dev/null

    sed -i '/^JELLYFIN_USERNAME=/d;/^JELLYFIN_PASSWORD=/d' "$ENV_FILE"
    { echo "JELLYFIN_USERNAME=admin"; echo "JELLYFIN_PASSWORD=${JELLYFIN_PASSWORD}"; } >> "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    info "Jellyfin: created admin account (username: admin, password: ${JELLYFIN_PASSWORD} -- also saved in ${ENV_FILE})."
  else
    info "Jellyfin setup wizard is already complete."
    if [[ -z "${JELLYFIN_PASSWORD:-}" ]]; then
      info "Jellyfin: no saved credential found (set up outside this script); skipping automatic library setup."
      return
    fi
  fi

  local auth_resp token
  auth_resp="$(curl -fsS -X POST \
    -H 'X-Emby-Authorization: MediaBrowser Client="media-stack-installer", Device="server", DeviceId="proxmox-media-stack-installer", Version="1.0.0"' \
    -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg u "${JELLYFIN_USERNAME:-admin}" --arg p "$JELLYFIN_PASSWORD" '{Username:$u,Pw:$p}')" \
    "$base/Users/AuthenticateByName" 2>/dev/null || true)"
  token="$(jq -r '.AccessToken // empty' <<<"$auth_resp")"
  if [[ -z "$token" ]]; then
    info "Jellyfin: could not authenticate to configure libraries; leave it for the UI."
    return
  fi

  local existing
  existing="$(curl -fsS -H "X-Emby-Token: $token" "$base/Library/VirtualFolders" 2>/dev/null || echo '[]')"

  add_jellyfin_library() {
    local name="$1" ctype="$2" path="$3"
    jq -e --arg n "$name" '.[] | select(.Name == $n)' <<<"$existing" >/dev/null && return
    curl -fsS -X POST -H "X-Emby-Token: $token" -H 'Content-Type: application/json' \
      -G "$base/Library/VirtualFolders" \
      --data-urlencode "name=$name" --data-urlencode "collectionType=$ctype" \
      --data-urlencode "paths=$path" --data-urlencode "refreshLibrary=false" \
      --data '{}' >/dev/null
    info "Jellyfin: added library '$name' ($path)."
  }
  add_jellyfin_library "Movies" movies /media/movies
  add_jellyfin_library "TV Shows" tvshows /media/tv
  add_jellyfin_library "Music" music /media/music
}

# Seerr has no service-account API key, but its first Jellyfin connection
# doubles as bootstrapping Seerr's own admin user from that same login --
# so the Jellyfin credential above is enough to fully automate this too,
# without ever touching Seerr's UI.
wire_seerr() {
  local seerr_base="http://${LOCAL_HOST}:5055"
  local initialized
  initialized="$(curl -fsS "$seerr_base/api/v1/settings/public" 2>/dev/null | jq -r '.initialized // false')"

  if [[ -z "${JELLYFIN_PASSWORD:-}" ]]; then
    info "Seerr: no Jellyfin admin credential available; connect it manually in Seerr's own setup UI,"
    info "then add Sonarr (http://sonarr:8989, key ${SONARR_KEY}) and Radarr (http://radarr:7878, key ${RADARR_KEY})"
    info "under Settings > Services."
    return
  fi

  # Seerr's own jellyfin.ip setting is inconsistently pre-filled at
  # container start (sometimes already set, sometimes not) -- try without
  # a hostname first, and only send one explicitly if that's rejected for
  # lacking one. urlBase must be sent even when empty: Seerr's own hostname
  # builder string-concatenates a missing field as the literal word
  # "undefined" into the URL, breaking the connection outright.
  # -f is deliberately omitted on these two calls: it discards the response
  # body on any non-2xx status, and the retry logic below depends on
  # reading that body to tell "no hostname configured yet" apart from a
  # real failure.
  local login_resp
  login_resp="$(curl -sS -c "$SEERR_COOKIE_JAR" -X POST -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg u "${JELLYFIN_USERNAME:-admin}" --arg p "$JELLYFIN_PASSWORD" '{username:$u,password:$p,serverType:2}')" \
    "$seerr_base/api/v1/auth/jellyfin" 2>/dev/null || true)"
  if jq -e '.error == "No hostname provided."' <<<"$login_resp" >/dev/null 2>&1; then
    login_resp="$(curl -sS -c "$SEERR_COOKIE_JAR" -X POST -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg u "${JELLYFIN_USERNAME:-admin}" --arg p "$JELLYFIN_PASSWORD" \
        '{username:$u,password:$p,serverType:2,hostname:"jellyfin",port:8096,urlBase:"",useSsl:false}')" \
      "$seerr_base/api/v1/auth/jellyfin" 2>/dev/null || true)"
  fi

  if [[ "$initialized" != "true" ]]; then
    if jq -e '.id' <<<"$login_resp" >/dev/null 2>&1; then
      info "Seerr: connected to Jellyfin using the generated admin account."
    else
      info "Seerr: could not bootstrap automatically yet (it may still be starting); re-run this script in a"
      info "minute, or connect it manually in Seerr's own setup UI."
      return
    fi
  else
    info "Seerr setup is already complete."
  fi

  [[ -s "$SEERR_COOKIE_JAR" ]] || { info "Seerr: no active session; skipping Sonarr/Radarr wiring."; return; }

  ensure_seerr_service() {
    local app="$1" hostname="$2" port="$3" key="$4" api_base="$5" settings_path="$6" extra_fields="$7"
    local existing
    existing="$(curl -fsS -b "$SEERR_COOKIE_JAR" "$seerr_base/api/v1/settings/$settings_path" 2>/dev/null || echo '[]')"
    if [[ "$(jq 'length' <<<"$existing" 2>/dev/null || echo 0)" -gt 0 ]]; then
      info "Seerr is already connected to $app."
      return
    fi
    local profile folder payload
    profile="$(curl -fsS -H "X-Api-Key: $key" "$api_base/api/v3/qualityprofile" | jq -c '([.[] | select(.name=="HD-1080p")][0]) // .[0]')"
    folder="$(curl -fsS -H "X-Api-Key: $key" "$api_base/api/v3/rootfolder" | jq -r '.[0].path')"
    [[ -n "$profile" && "$profile" != "null" && -n "$folder" ]] || { info "Seerr: could not read $app's profiles/root folder; skipping."; return; }
    payload="$(jq -nc --arg name "$app" --arg hostname "$hostname" --arg port "$port" --arg key "$key" \
      --arg dir "$folder" --argjson profile "$profile" --argjson extra "$extra_fields" \
      '{name:$name,hostname:$hostname,port:($port|tonumber),apiKey:$key,useSsl:false,baseUrl:"",
        activeProfileId:$profile.id,activeProfileName:$profile.name,activeDirectory:$dir,
        tags:[],is4k:false,isDefault:true,syncEnabled:true,preventSearch:false,tagRequests:false,overrideRule:[]}
       + $extra')"
    curl -fsS -b "$SEERR_COOKIE_JAR" -X POST -H 'Content-Type: application/json' \
      --data "$payload" "$seerr_base/api/v1/settings/$settings_path" >/dev/null
    info "Seerr: connected to $app."
  }

  ensure_seerr_service Radarr radarr 7878 "$RADARR_KEY" "http://${LOCAL_HOST}:7878" radarr \
    '{"minimumAvailability":"released"}'
  ensure_seerr_service Sonarr sonarr 8989 "$SONARR_KEY" "http://${LOCAL_HOST}:8989" sonarr \
    '{"seriesType":"standard","animeSeriesType":"standard","enableSeasonFolders":true,"monitorNewItems":"all","activeLanguageProfileId":1}'
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
setup_jellyfin
wire_seerr

info "Sonarr, Radarr, Prowlarr, Bazarr, Jellyfin, Seerr, qBittorrent and the shared /data paths are connected."
info "Add only your authorized indexers in Prowlarr; they will synchronize into Sonarr and Radarr."
