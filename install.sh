#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_URL="https://github.com/thebakermark/-proxmox-media-stack.git"
readonly INSTALL_DIR="/opt/proxmox-media-stack-installer"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run this installer as root on the Proxmox host."
command -v qm >/dev/null 2>&1 || die "qm was not found. Run this on a Proxmox VE host."
command -v git >/dev/null 2>&1 || {
  info "Installing git..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git
}

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Refreshing existing installer checkout..."
  git -C "$INSTALL_DIR" fetch origin main
  git -C "$INSTALL_DIR" checkout main
  git -C "$INSTALL_DIR" reset --hard origin/main
else
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 --branch main "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR"/*.sh
info "Starting Ubuntu 26.04 LTS media VM provisioning..."
exec "$INSTALL_DIR/00-create-proxmox-vm.sh" "$@"
