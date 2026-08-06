#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly BACKUP_DIR="/opt/media-stack-backups"

[[ ${EUID} -eq 0 ]] || { printf 'Run with sudo.\n' >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
tar --exclude='jellyfin/cache' -C "$STACK_DIR" -czf "$BACKUP_DIR/config-before-update-${timestamp}.tar.gz" config .env compose.yml compose.intel.yml

args=(-f compose.yml)
[[ -e /dev/dri/renderD128 ]] && args+=(-f compose.intel.yml)
cd "$STACK_DIR"
docker compose "${args[@]}" config --quiet
docker compose "${args[@]}" pull
docker compose "${args[@]}" up -d --remove-orphans
docker image prune -f
printf 'Update completed. Backup: %s\n' "$BACKUP_DIR/config-before-update-${timestamp}.tar.gz"

