#!/usr/bin/env bash
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly DEFAULT_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
readonly CHECKSUM_URL="https://cloud.debian.org/images/cloud/trixie/latest/SHA512SUMS"
readonly IMAGE_DIR="/var/lib/vz/template/iso"
readonly IMAGE_PATH="${IMAGE_DIR}/debian-13-genericcloud-amd64.qcow2"

VMID=""
VM_NAME="media-stack"
VM_STORAGE="local-lvm"
BRIDGE="vmbr0"
CORES="4"
MEMORY_MB="6144"
OS_DISK_GB="80"
CI_USER="mediaadmin"
DATA_STORAGE=""
DATA_DISK_GB=""
START_VM="yes"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

usage() {
  cat <<'EOF'
Create a Debian 13 media-stack VM on Proxmox VE.

Usage:
  sudo ./00-create-proxmox-vm.sh [options]

Options:
  --vmid ID              VM ID (default: next available)
  --name NAME            VM name (default: media-stack)
  --storage ID           Proxmox storage for OS disk (default: local-lvm)
  --bridge NAME          Network bridge (default: vmbr0)
  --cores N              vCPU count (default: 4)
  --memory MB            RAM in MiB (default: 6144)
  --os-disk GB           OS disk size (default: 80)
  --user NAME            Cloud-init admin user (default: mediaadmin)
  --data-storage ID      Create an empty second virtual disk on this storage
  --data-size GB         Size of the second virtual disk; requires --data-storage
  --no-start             Create but do not start the VM
  -h, --help             Show this help

This script never formats or wipes physical data drives. If a second data disk
is requested, it allocates a new Proxmox-managed virtual disk only.
EOF
}

while (($#)); do
  case "$1" in
    --vmid) VMID="${2:?missing VM ID}"; shift 2 ;;
    --name) VM_NAME="${2:?missing VM name}"; shift 2 ;;
    --storage) VM_STORAGE="${2:?missing storage ID}"; shift 2 ;;
    --bridge) BRIDGE="${2:?missing bridge}"; shift 2 ;;
    --cores) CORES="${2:?missing core count}"; shift 2 ;;
    --memory) MEMORY_MB="${2:?missing memory}"; shift 2 ;;
    --os-disk) OS_DISK_GB="${2:?missing disk size}"; shift 2 ;;
    --user) CI_USER="${2:?missing username}"; shift 2 ;;
    --data-storage) DATA_STORAGE="${2:?missing data storage}"; shift 2 ;;
    --data-size) DATA_DISK_GB="${2:?missing data disk size}"; shift 2 ;;
    --no-start) START_VM="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run this script as root on the Proxmox host."
command -v qm >/dev/null || die "qm was not found. Run this on a Proxmox VE host."
command -v pvesm >/dev/null || die "pvesm was not found."
command -v curl >/dev/null || die "curl is required."
command -v sha512sum >/dev/null || die "sha512sum is required."

[[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "--cores must be a positive integer."
[[ "$MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "--memory must be a positive integer."
[[ "$OS_DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "--os-disk must be a positive integer."
[[ -z "$DATA_STORAGE" || -n "$DATA_DISK_GB" ]] || die "--data-storage requires --data-size."
[[ -z "$DATA_DISK_GB" || "$DATA_DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "--data-size must be a positive integer."

pvesm status --storage "$VM_STORAGE" >/dev/null 2>&1 || die "Storage '$VM_STORAGE' is unavailable. Run 'pvesm status' to list storage IDs."
if [[ -n "$DATA_STORAGE" ]]; then
  pvesm status --storage "$DATA_STORAGE" >/dev/null 2>&1 || die "Data storage '$DATA_STORAGE' is unavailable."
fi
ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' does not exist."

if [[ -z "$VMID" ]]; then
  VMID="$(pvesh get /cluster/nextid)"
fi
[[ "$VMID" =~ ^[1-9][0-9]+$ ]] || die "VM ID must be numeric."
qm status "$VMID" >/dev/null 2>&1 && die "VM ID $VMID already exists."

install -d -m 0755 "$IMAGE_DIR"
CHECKSUM_FILE="$(mktemp /tmp/debian-cloud-sha512.XXXXXX)"
trap 'rm -f "$CHECKSUM_FILE"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --output "$CHECKSUM_FILE" "$CHECKSUM_URL"
EXPECTED_SUM_LINE="$(grep ' debian-13-genericcloud-amd64.qcow2$' "$CHECKSUM_FILE" || true)"
[[ -n "$EXPECTED_SUM_LINE" ]] || die "Debian checksum manifest did not contain the expected image."

image_is_current="no"
if [[ -s "$IMAGE_PATH" ]] && (cd "$IMAGE_DIR" && printf '%s\n' "$EXPECTED_SUM_LINE" | sha512sum --check --status); then
  image_is_current="yes"
fi

if [[ "$image_is_current" != "yes" ]]; then
  info "Downloading the current Debian 13 generic cloud image..."
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "${IMAGE_PATH}.partial" "$DEFAULT_IMAGE_URL"
  mv "${IMAGE_PATH}.partial" "$IMAGE_PATH"
  (cd "$IMAGE_DIR" && printf '%s\n' "$EXPECTED_SUM_LINE" | sha512sum --check --status) \
    || die "Debian image checksum verification failed."
else
  info "Using checksum-verified cached Debian image: $IMAGE_PATH"
fi
rm -f "$CHECKSUM_FILE"
trap - EXIT

read -r -s -p "Password for Debian user '${CI_USER}': " CI_PASSWORD
printf '\n'
[[ ${#CI_PASSWORD} -ge 12 ]] || die "Use a password of at least 12 characters."
read -r -s -p "Repeat password: " CI_PASSWORD_CONFIRM
printf '\n'
[[ "$CI_PASSWORD" == "$CI_PASSWORD_CONFIRM" ]] || die "Passwords did not match."
unset CI_PASSWORD_CONFIRM

cleanup_failed_vm() {
  local exit_code=$?
  if ((exit_code != 0)) && qm status "$VMID" >/dev/null 2>&1; then
    info "VM creation failed. The partial VM $VMID was left in place for inspection."
  fi
  exit "$exit_code"
}
trap cleanup_failed_vm EXIT

info "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --description "Debian media stack: Jellyfin + Servarr + Proton VPN isolated qBittorrent" \
  --ostype l26 \
  --machine q35 \
  --cpu host \
  --sockets 1 \
  --cores "$CORES" \
  --memory "$MEMORY_MB" \
  --balloon 2048 \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=${BRIDGE},firewall=1" \
  --agent enabled=1 \
  --onboot 1 \
  --startup order=30,up=30,down=60 \
  --serial0 socket \
  --vga serial0

qm set "$VMID" --scsi0 "${VM_STORAGE}:0,import-from=${IMAGE_PATH},discard=on,ssd=1,iothread=1"
qm disk resize "$VMID" scsi0 "${OS_DISK_GB}G"
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --ciuser "$CI_USER" --cipassword "$CI_PASSWORD"
qm set "$VMID" --ipconfig0 ip=dhcp
unset CI_PASSWORD

if [[ -n "$DATA_STORAGE" ]]; then
  info "Allocating a new ${DATA_DISK_GB} GiB data disk on ${DATA_STORAGE}..."
  qm set "$VMID" --scsi1 "${DATA_STORAGE}:${DATA_DISK_GB},discard=on,iothread=1"
fi

if [[ "$START_VM" == "yes" ]]; then
  qm start "$VMID"
fi

trap - EXIT
info "VM $VMID created successfully."
info "Open its Proxmox console and sign in as '$CI_USER'."
info "Copy the remaining package files into the VM, then run: sudo ./10-install-media-stack.sh"
if [[ -n "$DATA_STORAGE" ]]; then
  info "The new blank data disk will appear in Debian as an additional block device."
fi
