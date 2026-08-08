#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly BACKUP_DIR="/opt/media-stack-backups"
readonly CORE_SERVICES=(gluetun qbittorrent jellyfin sonarr radarr prowlarr bazarr seerr)
readonly HEALTH_TIMEOUT_S=120

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo."
[[ -r "${STACK_DIR}/.env" ]] || die "${STACK_DIR}/.env is missing. Run 10-install-media-stack.sh first."

mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
tar --exclude='jellyfin/cache' -C "$STACK_DIR" -czf "$BACKUP_DIR/config-before-update-${timestamp}.tar.gz" config .env compose.yml compose.intel.yml
info "Configuration backed up to $BACKUP_DIR/config-before-update-${timestamp}.tar.gz"

args=(-f compose.yml)
[[ -e /dev/dri/renderD128 ]] && args+=(-f compose.intel.yml)
cd "$STACK_DIR"
docker compose "${args[@]}" config --quiet

declare -A PREVIOUS_IMAGE_ID PREVIOUS_IMAGE_REF
for service in "${CORE_SERVICES[@]}"; do
  id="$(docker inspect -f '{{.Image}}' "$service" 2>/dev/null || true)"
  ref="$(docker inspect -f '{{.Config.Image}}' "$service" 2>/dev/null || true)"
  [[ -n "$id" && -n "$ref" ]] && { PREVIOUS_IMAGE_ID["$service"]="$id"; PREVIOUS_IMAGE_REF["$service"]="$ref"; }
done

info "Pulling updated images..."
docker compose "${args[@]}" pull
info "Applying updates..."
docker compose "${args[@]}" up -d --remove-orphans
docker image prune -f

check_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT_S))
  while ((SECONDS < deadline)); do
    local all_ok="yes"
    for service in "${CORE_SERVICES[@]}"; do
      local state health
      state="$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null || true)"
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$service" 2>/dev/null || true)"
      if [[ "$state" != "running" ]] || [[ "$health" != "healthy" && "$health" != "none" && "$health" != "starting" ]]; then
        all_ok="no"
      fi
    done
    [[ "$all_ok" == "yes" ]] && return 0
    sleep 5
  done
  return 1
}

info "Waiting for core services to report healthy (up to ${HEALTH_TIMEOUT_S}s)..."
if check_health; then
  info "Update completed successfully. All core services are running."
  exit 0
fi

info "One or more core services failed to come up healthy after the update. Rolling back..."
rollback_failed="no"
for service in "${!PREVIOUS_IMAGE_ID[@]}"; do
  docker tag "${PREVIOUS_IMAGE_ID[$service]}" "${PREVIOUS_IMAGE_REF[$service]}" 2>/dev/null || rollback_failed="yes"
done
docker compose "${args[@]}" up -d --remove-orphans || rollback_failed="yes"

if [[ "$rollback_failed" == "no" ]] && check_health; then
  info "Rollback to the previous images succeeded. Core services are healthy again."
  info "Investigate before retrying the update: sudo docker compose logs"
  exit 1
else
  info "ROLLBACK ALSO FAILED. Manual intervention is required."
  info "Restore configuration from: $BACKUP_DIR/config-before-update-${timestamp}.tar.gz"
  info "Check container status with: sudo docker compose ps && sudo docker compose logs"
  exit 2
fi
