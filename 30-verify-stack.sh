#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"
readonly CORE_SERVICES=(gluetun qbittorrent jellyfin sonarr radarr prowlarr bazarr seerr)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

PASS_NAMES=()
WARN_NAMES=(); WARN_FIXES=()
FAIL_NAMES=(); FAIL_FIXES=()

record_pass() { PASS_NAMES+=("$1"); printf 'PASS: %s\n' "$1"; }
record_warn() { WARN_NAMES+=("$1"); WARN_FIXES+=("$2"); printf 'WARN: %s\n' "$1"; }
record_fail() { FAIL_NAMES+=("$1"); FAIL_FIXES+=("$2"); printf 'FAIL: %s\n' "$1"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo."
[[ -r "$ENV_FILE" ]] || die "$ENV_FILE is missing. Run 10-install-media-stack.sh first."
# shellcheck disable=SC1090
source "$ENV_FILE"
cd "$STACK_DIR"

container_status() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true; }
container_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true; }
port_reachable() {
  local host="$1" port="$2"
  [[ "$host" == "0.0.0.0" ]] && host="127.0.0.1"
  timeout 3 bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# --- Ubuntu version ---------------------------------------------------------
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "26.04" ]]; then
    record_pass "Host OS is Ubuntu Server 26.04 LTS"
  else
    record_fail "Host OS is ${PRETTY_NAME:-unknown}, not Ubuntu Server 26.04 LTS" \
      "Reinstall the guest from the official Ubuntu 26.04 LTS cloud image."
  fi
else
  record_fail "Could not read /etc/os-release" "Confirm this VM is running Ubuntu Server."
fi

# --- Docker Engine / Compose -------------------------------------------------
if docker version >/dev/null 2>&1; then
  record_pass "Docker Engine is running ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
else
  record_fail "Docker Engine is not running or not installed" "sudo systemctl start docker"
fi

if docker compose version >/dev/null 2>&1; then
  record_pass "Docker Compose plugin is available ($(docker compose version --short 2>/dev/null))"
else
  record_fail "Docker Compose plugin is not available" \
    "sudo apt-get install -y docker-compose-plugin"
fi

# --- QEMU guest agent ---------------------------------------------------------
if systemctl is-active --quiet qemu-guest-agent 2>/dev/null; then
  record_pass "QEMU guest agent is running"
else
  record_warn "QEMU guest agent is not active" \
    "sudo apt-get install -y qemu-guest-agent && sudo systemctl enable --now qemu-guest-agent"
fi

# --- Required containers up + healthy ----------------------------------------
for service in "${CORE_SERVICES[@]}"; do
  state="$(container_status "$service")"
  if [[ "$state" == "running" ]]; then
    record_pass "$service container is running"
  else
    record_fail "$service container is not running (state: ${state:-missing})" \
      "cd $STACK_DIR && sudo docker compose up -d $service; sudo docker compose logs $service"
    continue
  fi
  health="$(container_health "$service")"
  case "$health" in
    healthy|none) : ;;
    starting) record_warn "$service healthcheck is still starting" "Wait a minute and rerun this script." ;;
    *) record_fail "$service healthcheck reports '$health'" "sudo docker compose logs $service" ;;
  esac
done

# --- Optional IPTV profile ----------------------------------------------------
if [[ ",${COMPOSE_PROFILES:-}," == *,iptv,* ]]; then
  for service in dispatcharr tunarr; do
    state="$(container_status "$service")"
    if [[ "$state" == "running" ]]; then
      record_pass "$service container is running"
    else
      record_fail "$service container is not running (state: ${state:-missing})" \
        "cd $STACK_DIR && sudo docker compose up -d $service"
    fi
  done
  if curl -fsS --max-time 10 "http://${BIND_IP}:9191" >/dev/null 2>&1; then
    record_pass "Dispatcharr web interface responds"
  else
    record_warn "Dispatcharr web interface did not respond" "It may still be starting; recheck in a minute."
  fi
  if curl -fsS --max-time 10 "http://${BIND_IP}:8000" >/dev/null 2>&1; then
    record_pass "Tunarr web interface responds"
  else
    record_warn "Tunarr web interface did not respond" "It may still be starting; recheck in a minute."
  fi
fi

# --- VPN isolation: qBittorrent network mode ---------------------------------
QBIT_NETWORK_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' qbittorrent 2>/dev/null || true)"
if [[ "$QBIT_NETWORK_MODE" == container:* ]]; then
  record_pass "qBittorrent shares only Gluetun's network namespace (no independent WAN path)"
else
  record_fail "Unexpected qBittorrent network mode: ${QBIT_NETWORK_MODE:-missing}" \
    "qBittorrent must use 'network_mode: service:gluetun' in compose.yml."
fi

# --- VPN kill-switch (non-disruptive check) -----------------------------------
GLUETUN_FIREWALL_OFF="no"
if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' gluetun 2>/dev/null | grep -qi '^FIREWALL=off$'; then
  GLUETUN_FIREWALL_OFF="yes"
fi
if [[ "$GLUETUN_FIREWALL_OFF" == "yes" ]]; then
  record_fail "Gluetun's firewall/kill-switch is explicitly disabled (FIREWALL=off)" \
    "Remove FIREWALL=off from the gluetun environment in compose.yml."
elif docker logs gluetun 2>&1 | tail -n 200 | grep -qi 'firewall'; then
  record_pass "Gluetun firewall (kill-switch) is enabled; qBittorrent has no path out if the tunnel drops"
else
  record_warn "Could not confirm Gluetun's firewall state from recent logs" \
    "sudo docker compose logs gluetun | grep -i firewall"
fi

# --- Gluetun health + Proton VPN connectivity ---------------------------------
GLUETUN_HEALTH="$(container_health gluetun)"
if [[ "$GLUETUN_HEALTH" == "healthy" ]]; then
  record_pass "Gluetun reports a healthy Proton VPN tunnel"
else
  record_fail "Gluetun health is '${GLUETUN_HEALTH:-missing}'" "sudo docker compose logs gluetun"
fi

# --- Torrent public IP must differ from the VM/host public IP ----------------
HOST_IP="$(curl -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
VPN_IP="$(docker run --rm --network container:gluetun curlimages/curl:latest -4fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$HOST_IP" || -z "$VPN_IP" ]]; then
  record_warn "Could not obtain both public IP addresses to compare" \
    "Check outbound internet access from the VM and from inside the gluetun network namespace."
elif [[ "$HOST_IP" == "$VPN_IP" ]]; then
  record_fail "VPN leak: host and torrent network report the same public IP ($HOST_IP)" \
    "sudo docker compose logs gluetun; verify PROTON_WIREGUARD_PRIVATE_KEY/ADDRESSES in $ENV_FILE"
else
  record_pass "Torrent network exits through a different public IP ($VPN_IP) than the VM ($HOST_IP)"
fi

# --- Proton VPN port forwarding status ----------------------------------------
FORWARDED_PORT="$(docker logs --since 30m gluetun 2>&1 | grep -oE 'port forwarded is [0-9]+' | tail -1 | grep -oE '[0-9]+' || true)"
if [[ -n "$FORWARDED_PORT" ]]; then
  record_pass "Proton VPN port forwarding is active (port $FORWARDED_PORT)"
else
  record_warn "No forwarded port observed in recent Gluetun logs" \
    "Port forwarding can take a few minutes after startup, or the selected Proton server may not support it."
fi

# --- /data mount, storage, permissions ----------------------------------------
if findmnt -rn /data >/dev/null 2>&1; then
  record_pass "/data is a separate mounted filesystem"
else
  record_warn "/data is not a separate mount" "Hardlinks may consume the VM OS disk; attach a dedicated data disk."
fi

if [[ -d /data ]]; then
  AVAIL_KB="$(df --output=avail -k /data 2>/dev/null | tail -1 | tr -d ' ')"
  AVAIL_PCT="$(df --output=pcent /data 2>/dev/null | tail -1 | tr -d ' %')"
  if [[ -n "$AVAIL_KB" ]]; then
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    if [[ -n "$AVAIL_PCT" && "$AVAIL_PCT" -ge 95 ]]; then
      record_warn "/data is ${AVAIL_PCT}% full (${AVAIL_GB} GiB free)" "Free up space or expand the data disk."
    else
      record_pass "/data has ${AVAIL_GB} GiB free"
    fi
  fi

  PERM_OK="yes"
  for path in torrents media usenet recordings; do
    [[ -d "/data/$path" ]] || continue
    owner_uid="$(stat -c %u "/data/$path")"
    if [[ -n "${PUID:-}" && "$owner_uid" != "$PUID" ]]; then
      PERM_OK="no"
    fi
  done
  if [[ "$PERM_OK" == "yes" ]]; then
    record_pass "/data subdirectories are owned by the configured PUID ($PUID)"
  else
    record_warn "One or more /data subdirectories are not owned by PUID $PUID" \
      "sudo chown -R ${PUID:-1000}:${PGID:-1000} /data"
  fi
else
  record_fail "/data does not exist" "Rerun 10-install-media-stack.sh."
fi

# --- Hardlink capability (host) -----------------------------------------------
if [[ -d /data/torrents && -d /data/media ]]; then
  test_file="/data/torrents/.hardlink-test-$$"
  test_link="/data/media/.hardlink-test-$$"
  trap 'rm -f "$test_file" "$test_link"' EXIT
  printf 'hardlink-test' > "$test_file"
  if ln "$test_file" "$test_link" 2>/dev/null; then
    inode_a="$(stat -c %i "$test_file")"
    inode_b="$(stat -c %i "$test_link")"
    if [[ "$inode_a" == "$inode_b" ]]; then
      record_pass "Hardlinks work between /data/torrents and /data/media on the host"
    else
      record_fail "Hardlink inode mismatch between /data/torrents and /data/media" \
        "Ensure both paths are on the same filesystem."
    fi
  else
    record_fail "Cannot hardlink between /data/torrents and /data/media" \
      "Both directories must be on the same filesystem for atomic imports to work."
  fi
  rm -f "$test_file" "$test_link"
  trap - EXIT
else
  record_warn "Skipped host hardlink test; /data/torrents or /data/media is missing" ""
fi

# --- Servarr / download-client path consistency (inside containers) ----------
check_container_path_consistency() {
  local service="$1"
  [[ "$(container_status "$service")" == "running" ]] || return
  local dev_torrents dev_media
  dev_torrents="$(docker exec "$service" sh -c 'stat -c %d /data/torrents 2>/dev/null' 2>/dev/null || true)"
  dev_media="$(docker exec "$service" sh -c 'stat -c %d /data/media 2>/dev/null' 2>/dev/null || true)"
  if [[ -z "$dev_torrents" || -z "$dev_media" ]]; then
    record_warn "$service: could not verify /data/torrents and /data/media inside the container" \
      "docker exec $service sh -c 'ls /data'"
  elif [[ "$dev_torrents" == "$dev_media" ]]; then
    record_pass "$service sees /data/torrents and /data/media on the same filesystem (hardlink-safe)"
  else
    record_fail "$service: /data/torrents and /data/media are on different filesystems inside the container" \
      "Check the volume mounts for $service in compose.yml; both must come from the same \${DATA_ROOT} mount."
  fi
}
for service in sonarr radarr qbittorrent; do
  check_container_path_consistency "$service"
done

# --- Expected listening ports -------------------------------------------------
declare -A EXPECTED_PORTS=(
  [jellyfin]=8096 [sonarr]=8989 [radarr]=7878 [prowlarr]=9696
  [bazarr]=6767 [seerr]=5055 [qbittorrent]=8080
)
for service in "${!EXPECTED_PORTS[@]}"; do
  port="${EXPECTED_PORTS[$service]}"
  [[ "$(container_status "$service")" == "running" ]] || continue
  if port_reachable "${BIND_IP:-0.0.0.0}" "$port"; then
    record_pass "$service is listening on ${BIND_IP:-0.0.0.0}:$port"
  else
    record_warn "$service does not appear to be listening on ${BIND_IP:-0.0.0.0}:$port yet" \
      "It may still be starting; sudo docker compose logs $service"
  fi
done

# --- GPU passthrough (informational) ------------------------------------------
if [[ -e /dev/dri/renderD128 ]]; then
  record_pass "GPU render device is visible inside the media VM"
else
  record_warn "No GPU render device is visible; media transcoding will use the CPU" ""
fi

# --- Executive summary ---------------------------------------------------------
printf '\n=====================================\n'
if [[ "${#FAIL_NAMES[@]}" -eq 0 ]]; then
  printf 'MEDIA STACK: HEALTHY\n'
  printf '=====================================\n'
  printf '%d passed, %d warnings, 0 failures\n' "${#PASS_NAMES[@]}" "${#WARN_NAMES[@]}"
  exit 0
else
  printf 'MEDIA STACK: ATTENTION REQUIRED\n'
  printf '=====================================\n'
  printf '%d passed, %d warnings, %d failures\n\n' "${#PASS_NAMES[@]}" "${#WARN_NAMES[@]}" "${#FAIL_NAMES[@]}"
  for i in "${!FAIL_NAMES[@]}"; do
    printf 'FAILED: %s\n' "${FAIL_NAMES[$i]}"
    [[ -n "${FAIL_FIXES[$i]}" ]] && printf '  fix: %s\n' "${FAIL_FIXES[$i]}"
  done
  exit 1
fi
