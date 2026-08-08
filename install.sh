#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_URL="https://github.com/thebakermark/-proxmox-media-stack.git"
readonly INSTALL_DIR="/opt/proxmox-media-stack-installer"
readonly STATE_DIR="/root/.proxmox-media-stack"
readonly STATE_FILE="${STATE_DIR}/last-vm.env"
readonly KNOWN_HOSTS_FILE="${STATE_DIR}/known_hosts"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run this installer as root on the Proxmox host."
command -v qm >/dev/null 2>&1 || die "qm was not found. Run this on a Proxmox VE host."
command -v git >/dev/null 2>&1 || {
  info "Installing git..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y git
}
command -v ssh >/dev/null 2>&1 || {
  info "Installing openssh-client..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-client
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

print_manual_fallback() {
  info ""
  info "Continue manually from the Proxmox console:"
  info "  1. Open the VM's Console in the Proxmox web UI and sign in."
  info "  2. sudo apt-get update && sudo apt-get install -y git"
  info "  3. git clone https://github.com/thebakermark/-proxmox-media-stack.git && cd ./-proxmox-media-stack"
  info "  4. sudo ./10-install-media-stack.sh"
  info "  5. sudo ./20-wire-arr-apps.sh && sudo ./30-verify-stack.sh"
}

info "Starting Ubuntu 26.04 LTS media VM provisioning..."
"$INSTALL_DIR/00-create-proxmox-vm.sh" "$@"

[[ -r "$STATE_FILE" ]] || die "VM creation script did not report its result at $STATE_FILE."
# shellcheck disable=SC1090
source "$STATE_FILE"

if [[ "${START_VM:-yes}" != "yes" ]]; then
  info "The VM was created with --no-start; automatic guest bootstrap is skipped."
  info "Start it with 'qm start ${VMID}', then rerun this bootstrap manually inside the guest."
  print_manual_fallback
  exit 0
fi

[[ -n "${VMID:-}" ]] || die "State file did not include a VM ID."
[[ -r "${SSH_KEY_PATH:-}" ]] || die "State file did not include a usable SSH key."

info ""
info "Waiting for VM ${VMID} to finish booting and report readiness via the QEMU guest agent..."
info "(This can take several minutes on first boot while cloud-init configures the system.)"

agent_ready="no"
for _ in $(seq 1 180); do
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    agent_ready="yes"
    break
  fi
  sleep 5
done

if [[ "$agent_ready" != "yes" ]]; then
  info "Timed out waiting for the QEMU guest agent to respond after 15 minutes."
  print_manual_fallback
  exit 0
fi
info "Guest agent is responding."

GUEST_IP=""
for _ in $(seq 1 60); do
  GUEST_IP="$(qm agent "$VMID" network-get-interfaces 2>/dev/null \
    | grep -oP '"ip-address"\s*:\s*"\K[0-9.]+' \
    | grep -v '^127\.' | grep -v '^169\.254\.' | head -1 || true)"
  [[ -n "$GUEST_IP" ]] && break
  sleep 5
done

if [[ -z "$GUEST_IP" ]]; then
  info "Timed out waiting for the VM to report a LAN IPv4 address."
  print_manual_fallback
  exit 0
fi
info "VM ${VMID} is reachable at ${GUEST_IP}."

rm -f "$KNOWN_HOSTS_FILE"
readonly SSH_OPTS=(-i "$SSH_KEY_PATH" -o "UserKnownHostsFile=${KNOWN_HOSTS_FILE}" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

info "Waiting for SSH to become available..."
ssh_ready="no"
for _ in $(seq 1 60); do
  if ssh "${SSH_OPTS[@]}" "${CI_USER}@${GUEST_IP}" true >/dev/null 2>&1; then
    ssh_ready="yes"
    break
  fi
  sleep 5
done

if [[ "$ssh_ready" != "yes" ]]; then
  info "Timed out waiting for SSH access to ${GUEST_IP}."
  print_manual_fallback
  exit 0
fi
info "SSH access confirmed. Continuing setup inside the guest..."
info ""

AUTO_DATA_DISK_ARG=""
[[ "${DATA_DISK_REQUESTED:-no}" == "yes" ]] && AUTO_DATA_DISK_ARG="--auto-data-disk"

# shellcheck disable=SC2016
REMOTE_SCRIPT='
set -e
if ! command -v git >/dev/null 2>&1; then
  echo "Installing git inside the guest..."
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git
fi
sudo install -d -m 0755 /opt/proxmox-media-stack-src
if [ -d /opt/proxmox-media-stack-src/.git ]; then
  sudo git -C /opt/proxmox-media-stack-src fetch origin main
  sudo git -C /opt/proxmox-media-stack-src reset --hard origin/main
else
  sudo git clone --depth 1 --branch main "'"$REPO_URL"'" /opt/proxmox-media-stack-src
fi
cd /opt/proxmox-media-stack-src
sudo chmod +x ./*.sh
sudo ./10-install-media-stack.sh '"$AUTO_DATA_DISK_ARG"'
read -r -p "Wire Sonarr/Radarr to qBittorrent and run the verification checks now? [Y/n]: " cont
cont="${cont:-Y}"
if [[ "$cont" =~ ^[Yy] ]]; then
  sudo ./20-wire-arr-apps.sh
  sudo ./30-verify-stack.sh
else
  echo "Skipped. Run these later with:"
  echo "  sudo /opt/media-stack/20-wire-arr-apps.sh"
  echo "  sudo /opt/media-stack/30-verify-stack.sh"
fi
'

if ssh -t "${SSH_OPTS[@]}" "${CI_USER}@${GUEST_IP}" "bash -s" <<<"$REMOTE_SCRIPT"; then
  info ""
  info "Media stack setup finished. See the output above for application URLs and any remaining"
  info "account-specific steps (Proton VPN, indexers, subtitle providers, Jellyfin admin, IPTV, Plex claim)."
else
  info ""
  info "The guest setup session exited with an error or was interrupted before finishing."
  print_manual_fallback
fi
