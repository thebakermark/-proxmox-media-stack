#!/usr/bin/env bash
set -Eeuo pipefail

readonly STACK_DIR="/opt/media-stack"
readonly BACKUP_DIR="${1:-/opt/media-stack-backups}"

[[ ${EUID} -eq 0 ]] || { printf 'Run with sudo.\n' >&2; exit 1; }
mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output="$BACKUP_DIR/media-stack-config-${timestamp}.tar.gz"

cd "$STACK_DIR"
docker compose stop
trap 'cd "$STACK_DIR" && docker compose start >/dev/null 2>&1 || true' EXIT
tar --exclude='jellyfin/cache' -czf "$output" config .env compose.yml compose.intel.yml ./*.sh
docker compose start
trap - EXIT
chmod 0600 "$output"
printf 'Configuration backup created: %s\n' "$output"
printf 'Media files under /data are not included; protect them with Proxmox/ZFS backups.\n'

