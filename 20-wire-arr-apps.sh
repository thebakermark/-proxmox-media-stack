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

# A single generated password shared across Sonarr/Radarr/Prowlarr/Bazarr's
# own WebUI logins (each with its own <appname>admin username). Generated
# once and reused on idempotent re-runs, same as the other credentials
# above -- not regenerated (and not un-set) just because the script ran
# again. Auth is required only from outside the LAN where each app
# supports that distinction; local access stays unauthenticated.
if [[ -z "${APP_ADMIN_PASSWORD:-}" ]]; then
  APP_ADMIN_PASSWORD="$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9' | head -c 12)"
  sed -i '/^APP_ADMIN_PASSWORD=/d' "$ENV_FILE"
  echo "APP_ADMIN_PASSWORD=${APP_ADMIN_PASSWORD}" >> "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  info "Generated a shared admin password for Sonarr/Radarr/Prowlarr/Bazarr (saved in ${ENV_FILE})."
fi

secure_servarr_app() {
  local app="$1" base="$2" key="$3" api_ver="$4" username="$5"
  local config
  config="$(curl -fsS -H "X-Api-Key: $key" "$base/api/$api_ver/config/host")"
  if [[ "$(jq -r '.authenticationMethod' <<<"$config")" == "forms" \
     && "$(jq -r '.username' <<<"$config")" == "$username" ]]; then
    info "$app: authentication already set (username: $username)."
    return
  fi
  local new
  new="$(jq -c --arg u "$username" --arg p "$APP_ADMIN_PASSWORD" \
    '.authenticationMethod = "forms" | .authenticationRequired = "disabledForLocalAddresses"
     | .username = $u | .password = $p | .passwordConfirmation = $p' \
    <<<"$config")"
  curl -fsS -X PUT -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
    --data "$new" "$base/api/$api_ver/config/host/1" >/dev/null
  info "$app: authentication set (username: $username; not required from the LAN, only remotely)."
}

secure_bazarr_auth() {
  local bazarr_config="$STACK_DIR/config/bazarr/config/config.yaml"
  [[ -r "$bazarr_config" ]] || return
  command -v python3 >/dev/null || return

  local already
  already="$(python3 -c "
import yaml
with open('$bazarr_config') as f:
    cfg = yaml.safe_load(f) or {}
a = cfg.get('auth', {})
print('yes' if a.get('type') == 'form' and a.get('username') == 'bazarradmin' else 'no')
" 2>/dev/null || echo no)"
  if [[ "$already" == "yes" ]]; then
    info "Bazarr: authentication already set (username: bazarradmin)."
    return
  fi

  # Bazarr has no LAN-bypass equivalent to the Servarr apps' "disabled for
  # local addresses" -- setting a login here means it's always required.
  if python3 -c "
import yaml
path = '$bazarr_config'
with open(path) as f:
    cfg = yaml.safe_load(f)
cfg['auth']['type'] = 'form'
cfg['auth']['username'] = 'bazarradmin'
cfg['auth']['password'] = '$APP_ADMIN_PASSWORD'
with open(path, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=True)
" 2>/dev/null; then
    docker restart bazarr >/dev/null 2>&1 || true
    info "Bazarr: authentication set (username: bazarradmin; Bazarr has no LAN-bypass, so this is always required)."
  else
    info "Bazarr: could not set authentication; leaving it untouched."
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

  # The login above is attempted whether or not Seerr is already
  # initialized (it also refreshes the session cookie for the calls
  # below), so check its actual result rather than assuming success --
  # a stale saved credential (e.g. you changed Jellyfin's password
  # yourself, as suggested you could) fails it just as a first-time
  # bootstrap failure would, and both need to stop here rather than
  # proceed with no valid session.
  if ! jq -e '.id' <<<"$login_resp" >/dev/null 2>&1; then
    if [[ "$initialized" == "true" ]]; then
      info "Seerr: already set up, but could not refresh its session (the saved Jellyfin credential may be"
      info "stale -- e.g. if you changed Jellyfin's admin password since). Skipping Sonarr/Radarr wiring;"
      info "sign in to Seerr directly if you need to change anything there."
    else
      info "Seerr: could not bootstrap automatically yet (it may still be starting); re-run this script in a"
      info "minute, or connect it manually in Seerr's own setup UI."
    fi
    return
  fi

  if [[ "$initialized" != "true" ]]; then
    info "Seerr: connected to Jellyfin using the generated admin account."
    # Connecting a media server alone doesn't mark Seerr as set up -- its
    # own frontend wizard calls this explicitly as the final step after
    # you click through it by hand; do the same here.
    curl -fsS -b "$SEERR_COOKIE_JAR" -X POST "$seerr_base/api/v1/settings/initialize" >/dev/null 2>&1 \
      && info "Seerr: setup marked complete." \
      || info "Seerr: connected, but could not mark setup complete; check its UI."
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

# Aurral is a Lidarr companion for music discovery, picked over AI-driven
# alternatives (Digarr, Mixarr) specifically because it needs no LLM
# provider or API cost -- its recommendations come from Last.fm/
# ListenBrainz/tags. Only runs if the "music" profile (Lidarr) is enabled;
# Aurral is meaningless without it. Its own docs don't publish a request
# schema for automated setup, so this was ground-truthed against its
# actual route source (backend/routes/onboarding.js): one call creates the
# admin account and connects Lidarr together.
wire_aurral() {
  [[ ",${COMPOSE_PROFILES:-}," == *,music,* ]] || return
  local aurral_base="http://${LOCAL_HOST}:3001"

  local bootstrap="" attempts=0
  while ((attempts < 30)); do
    bootstrap="$(curl -fsS "$aurral_base/api/health/bootstrap" 2>/dev/null || true)"
    [[ -n "$bootstrap" ]] && break
    sleep 2
    ((attempts+=1))
  done
  if [[ -z "$bootstrap" ]]; then
    info "Aurral: never became reachable; skipping. Complete its setup manually at $aurral_base."
    return
  fi
  if [[ "$(jq -r '.onboardingRequired // false' <<<"$bootstrap" 2>/dev/null)" != "true" ]]; then
    info "Aurral setup is already complete."
    return
  fi

  local lidarr_key="" lidarr_config="$STACK_DIR/config/lidarr/config.xml"
  attempts=0
  while ((attempts < 30)); do
    [[ -r "$lidarr_config" ]] && lidarr_key="$(read_api_key "$lidarr_config")"
    [[ -n "$lidarr_key" ]] && break
    sleep 2
    ((attempts+=1))
  done
  if [[ -z "$lidarr_key" ]]; then
    info "Aurral: Lidarr isn't ready yet; skipping. Re-run this script once Lidarr has started."
    return
  fi

  # localNetworkBypass mirrors the Servarr apps' "disabled for local
  # addresses" -- auth is only required from outside the LAN. Password
  # reuses the shared APP_ADMIN_PASSWORD (Aurral requires >= 8 characters;
  # it's 12).
  local payload resp
  payload="$(jq -nc --arg u aurraladmin --arg p "$APP_ADMIN_PASSWORD" --arg key "$lidarr_key" \
    '{authUser: $u, authPassword: $p,
      lidarr: {url: "http://lidarr:8686", apiKey: $key, defaultMonitorOption: "none", searchOnAdd: false},
      security: {localNetworkBypass: {enabled: true}}}')"
  resp="$(curl -sS -X POST -H 'Content-Type: application/json' --data "$payload" \
    "$aurral_base/api/onboarding/complete" 2>/dev/null || true)"
  if jq -e '.success == true' <<<"$resp" >/dev/null 2>&1; then
    info "Aurral: connected to Lidarr and secured (username: aurraladmin; not required from the LAN, only remotely)."
  else
    info "Aurral: could not complete setup automatically; connect it manually at $aurral_base."
  fi
}

# Hubarr is this stack's own name for the gethomepage/homepage dashboard
# (compose.yml's "hubarr" service) -- one page showing live status for
# every app. It needs each app's own API key/credential to do that, not a
# new account of its own, so this reuses what's already been generated
# above instead of minting anything new.
wire_hubarr() {
  local config_dir="$STACK_DIR/config/hubarr"
  local services_file="$config_dir/services.yaml"
  if [[ -f "$services_file" ]]; then
    info "Hubarr: dashboard already configured; leaving it (and any customizing you've done) alone."
    return
  fi
  command -v python3 >/dev/null || { info "Hubarr: python3 unavailable; skipping dashboard setup."; return; }

  # Jellyfin has no API key of its own yet -- create one the same way its
  # own Dashboard > API Keys page would, using the same admin session
  # pattern setup_jellyfin() above already established.
  local jellyfin_key=""
  if [[ -n "${JELLYFIN_PASSWORD:-}" ]]; then
    local jf_base="http://${LOCAL_HOST}:8096" jf_auth jf_token
    jf_auth="$(curl -fsS -X POST \
      -H 'X-Emby-Authorization: MediaBrowser Client="media-stack-installer", Device="server", DeviceId="proxmox-media-stack-installer", Version="1.0.0"' \
      -H 'Content-Type: application/json' \
      --data "$(jq -nc --arg u "${JELLYFIN_USERNAME:-admin}" --arg p "$JELLYFIN_PASSWORD" '{Username:$u,Pw:$p}')" \
      "$jf_base/Users/AuthenticateByName" 2>/dev/null || true)"
    jf_token="$(jq -r '.AccessToken // empty' <<<"$jf_auth" 2>/dev/null)"
    if [[ -n "$jf_token" ]]; then
      curl -fsS -X POST -H "X-Emby-Token: $jf_token" "$jf_base/Auth/Keys?app=Hubarr" >/dev/null 2>&1 || true
      jellyfin_key="$(curl -sS -H "X-Emby-Token: $jf_token" "$jf_base/Auth/Keys" 2>/dev/null \
        | jq -r '[.Items[]? | select(.AppName=="Hubarr")][0].AccessToken // empty' 2>/dev/null || true)"
    fi
  fi

  # Seerr has no separate API-key-only auth path either -- read the key it
  # already generated for itself, over the admin session still live in
  # $SEERR_COOKIE_JAR from wire_seerr above (if that succeeded). A non-empty
  # cookie jar isn't proof the session is actually authenticated -- Seerr
  # can set a cookie on a failed login too -- so this deliberately omits -f
  # and treats any non-2xx (a 401/403 here) the same as "no session": empty
  # key, not a crash. Caught live: without this, a stale Jellyfin credential
  # (see wire_seerr above) left an unauthenticated cookie that made this an
  # uncaught curl -f failure under set -e.
  local seerr_key=""
  if [[ -s "$SEERR_COOKIE_JAR" ]]; then
    seerr_key="$(curl -sS -b "$SEERR_COOKIE_JAR" \
      "http://${LOCAL_HOST}:5055/api/v1/settings/main" 2>/dev/null | jq -r '.apiKey // empty' 2>/dev/null || true)"
  fi

  local bazarr_config="$STACK_DIR/config/bazarr/config/config.yaml" bazarr_key=""
  if [[ -r "$bazarr_config" ]]; then
    bazarr_key="$(python3 -c "
import yaml
try:
    with open('$bazarr_config') as f:
        print((yaml.safe_load(f) or {}).get('auth', {}).get('apikey') or '')
except Exception:
    pass
" 2>/dev/null)"
  fi

  install -d -m 0775 -o "${PUID:-1000}" -g "${PGID:-1000}" "$config_dir"

  python3 - "$config_dir" "$LOCAL_HOST" \
    "$SONARR_KEY" "$RADARR_KEY" "$PROWLARR_KEY" "$bazarr_key" "$jellyfin_key" "$seerr_key" \
    "${HUBARR_QBIT_USER:-admin}" "${HUBARR_QBIT_PASS:-}" <<'PYEOF'
import sys, os, yaml

config_dir, host = sys.argv[1], sys.argv[2]
sonarr_key, radarr_key, prowlarr_key = sys.argv[3], sys.argv[4], sys.argv[5]
bazarr_key, jellyfin_key, seerr_key = sys.argv[6], sys.argv[7], sys.argv[8]
qbit_user, qbit_pass = sys.argv[9], sys.argv[10]


def service(name, icon, port, key=None, wtype=None, extra=None, creds=None):
    entry = {"icon": icon, "href": f"http://{host}:{port}"}
    if wtype and (key or creds):
        widget = {"type": wtype, "url": f"http://{host}:{port}"}
        if key:
            widget["key"] = key
        if creds:
            widget.update(creds)
        if extra:
            widget.update(extra)
        entry["widget"] = widget
    return {name: entry}


groups = [
    {"Watch & Request": [
        service("Jellyfin", "jellyfin.png", 8096, key=jellyfin_key, wtype="jellyfin", extra={"version": 2}),
        service("Seerr", "overseerr.png", 5055, key=seerr_key, wtype="seerr"),
    ]},
    {"Automation": [
        service("Sonarr", "sonarr.png", 8989, key=sonarr_key, wtype="sonarr", extra={"enableQueue": True}),
        service("Radarr", "radarr.png", 7878, key=radarr_key, wtype="radarr", extra={"enableQueue": True}),
        service("Prowlarr", "prowlarr.png", 9696, key=prowlarr_key, wtype="prowlarr"),
        service("Bazarr", "bazarr.png", 6767, key=bazarr_key, wtype="bazarr"),
    ]},
    {"Downloads": [
        service("qBittorrent", "qbittorrent.png", 8080, wtype="qbittorrent",
                creds={"username": qbit_user, "password": qbit_pass} if qbit_pass else None),
    ]},
]

with open(os.path.join(config_dir, "services.yaml"), "w") as f:
    yaml.safe_dump(groups, f, default_flow_style=False, sort_keys=False)

settings_path = os.path.join(config_dir, "settings.yaml")
if not os.path.exists(settings_path):
    with open(settings_path, "w") as f:
        yaml.safe_dump({"title": "Hubarr", "theme": "dark", "color": "slate"}, f, default_flow_style=False)
PYEOF

  chown -R "${PUID:-1000}:${PGID:-1000}" "$config_dir" 2>/dev/null || true
  docker restart hubarr >/dev/null 2>&1 || true
  info "Hubarr: dashboard configured at http://${LOCAL_HOST}:3000 with live status for every app."
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
# Hubarr's qBittorrent widget (wired up much later below, after Jellyfin/
# Seerr) needs this too -- keep one copy under its own name rather than
# delaying the unset below, which exists specifically to stop carrying the
# plaintext password through the rest of this script's execution.
HUBARR_QBIT_USER="$QBIT_USER"
HUBARR_QBIT_PASS="$QBIT_PASSWORD"
unset QBIT_PASSWORD

PROWLARR_KEY="$(wait_for_key Prowlarr "$STACK_DIR/config/prowlarr/config.xml")"
ensure_prowlarr_application Sonarr Sonarr "http://sonarr:8989" "$SONARR_KEY"
ensure_prowlarr_application Radarr Radarr "http://radarr:7878" "$RADARR_KEY"

ensure_config_bool Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" mediamanagement copyUsingHardlinks "hardlink imports"
ensure_config_bool Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" naming renameEpisodes "automatic file renaming"
ensure_config_bool Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" mediamanagement copyUsingHardlinks "hardlink imports"
ensure_config_bool Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" naming renameMovies "automatic file renaming"

wire_bazarr

secure_servarr_app Sonarr "http://${LOCAL_HOST}:8989" "$SONARR_KEY" v3 sonarradmin
secure_servarr_app Radarr "http://${LOCAL_HOST}:7878" "$RADARR_KEY" v3 radarradmin
secure_servarr_app Prowlarr "http://${LOCAL_HOST}:9696" "$PROWLARR_KEY" v1 prowlarradmin
secure_bazarr_auth

setup_jellyfin
wire_seerr
wire_aurral
wire_hubarr

info "Sonarr, Radarr, Prowlarr, Bazarr, Jellyfin, Seerr, Hubarr, qBittorrent and the shared /data paths are connected."
info "Hubarr (this stack's control-center dashboard): http://${LOCAL_HOST}:3000"
if [[ ",${COMPOSE_PROFILES:-}," == *,music,* ]]; then
  info "Aurral (music discovery): http://${LOCAL_HOST}:3001"
fi
info "Add only your authorized indexers in Prowlarr; they will synchronize into Sonarr and Radarr."
