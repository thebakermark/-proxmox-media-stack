#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPO_URL="https://github.com/thebakermark/-proxmox-media-stack.git"
readonly RAW_BASE="https://raw.githubusercontent.com/thebakermark/-proxmox-media-stack/main"
readonly WORK_DIR="/opt/proxmox-media-stack-helper"
readonly SNIPPET_DIR="/var/lib/vz/snippets"
readonly HELPER_LOG="/var/log/proxmox-media-stack-helper.log"

VMID=""
VM_NAME="media-stack"
VM_STORAGE=""
DATA_STORAGE=""
DATA_SIZE_GB="500"
CORES="4"
MEMORY_MB="6144"
OS_DISK_GB="80"
BRIDGE="vmbr0"
CI_USER="mediaadmin"
METHOD="default"
PROTON_CONFIG=""
SNIPPET_FILE=""
STARTED_VM="no"

YW="\033[33m"; BL="\033[36m"; RD="\033[01;31m"; GN="\033[1;92m"; CL="\033[m"
BFR="\r\033[K"; TAB="  "
CM="${TAB}✔️${TAB}"; CROSS="${TAB}✖️${TAB}"; INFO="${TAB}💡${TAB}"

header_info() {
  clear
  cat <<'EOF'
 __  __          _ _         ____  _             _
|  \/  | ___  __| (_) __ _  / ___|| |_ __ _  ___| | __
| |\/| |/ _ \/ _` | |/ _` | \___ \| __/ _` |/ __| |/ /
| |  | |  __/ (_| | | (_| |  ___) | || (_| | (__|   <
|_|  |_|\___|\__,_|_|\__,_| |____/ \__\__,_|\___|_|\_\

      Proxmox Media Stack Helper
EOF
}

msg_info() { echo -ne "${YW}${INFO}$1${CL}"; }
msg_ok() { echo -e "${BFR}${GN}${CM}$1${CL}"; }
msg_error() { echo -e "${BFR}${RD}${CROSS}$1${CL}" >&2; }
die() { msg_error "$*"; exit 1; }

cleanup() {
  local rc=$?
  if [[ -n "${SNIPPET_FILE:-}" && -f "$SNIPPET_FILE" && "$rc" -ne 0 && "$STARTED_VM" != "yes" ]]; then
    rm -f "$SNIPPET_FILE"
  fi
  exit "$rc"
}
trap cleanup EXIT

check_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this script as root from the Proxmox shell."
  command -v pveversion >/dev/null 2>&1 || die "This is not a Proxmox VE host."
}

ensure_deps() {
  local missing=()
  for cmd in curl git whiptail openssl pvesh pvesm qm awk sed grep base64; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    msg_info "Installing helper dependencies..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl git whiptail openssl coreutils >/dev/null
    msg_ok "Installed helper dependencies"
  fi
}

pve_check() {
  local ver major minor
  ver="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  if [[ "$major" == "8" ]]; then return 0; fi
  if [[ "$major" == "9" && "$minor" =~ ^[0-9]+$ && "$minor" -le 2 ]]; then return 0; fi
  die "Unsupported Proxmox VE version ${ver}. This helper targets PVE 8.x and 9.0-9.2."
}

arch_check() {
  [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "This helper currently supports amd64 Proxmox hosts only."
}

next_vmid() {
  local id
  id="$(pvesh get /cluster/nextid)"
  while qm status "$id" >/dev/null 2>&1 || pct status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
  done
  printf '%s\n' "$id"
}

storage_menu() {
  local prompt="$1"
  local default_storage="${2:-}"
  local -a items=()
  local id type free state
  while read -r id type free state; do
    [[ -n "$id" ]] || continue
    local on="OFF"
    [[ "$id" == "$default_storage" ]] && on="ON"
    items+=("$id" "Type: $type | Free: $free | $state" "$on")
  done < <(pvesm status -content images | awk 'NR>1 {print $1, $2, $6, $3}')
  ((${#items[@]})) || die "No Proxmox storage capable of VM images was detected."
  whiptail --backtitle "Proxmox Media Stack Helper" --title "STORAGE" \
    --radiolist "$prompt" 18 78 8 "${items[@]}" 3>&1 1>&2 2>&3
}

default_settings() {
  METHOD="default"
  VMID="$(next_vmid)"
  VM_NAME="media-stack"
  CORES="4"
  MEMORY_MB="6144"
  OS_DISK_GB="80"
  BRIDGE="vmbr0"
  CI_USER="mediaadmin"
  DATA_SIZE_GB="500"
}

advanced_settings() {
  METHOD="advanced"
  VMID="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "VM ID" \
    --inputbox "Virtual Machine ID" 8 58 "$(next_vmid)" 3>&1 1>&2 2>&3)" || exit 0
  [[ "$VMID" =~ ^[1-9][0-9]+$ ]] || die "VM ID must be numeric."
  (qm status "$VMID" >/dev/null 2>&1 || pct status "$VMID" >/dev/null 2>&1) && die "VM ID $VMID is already in use."

  VM_NAME="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "VM NAME" \
    --inputbox "VM name" 8 58 "media-stack" 3>&1 1>&2 2>&3)" || exit 0
  VM_NAME="$(echo "${VM_NAME,,}" | tr -cs 'a-z0-9-' '-' | sed 's/^-//;s/-$//')"
  [[ -n "$VM_NAME" ]] || VM_NAME="media-stack"

  CORES="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "CPU" --inputbox "CPU cores" 8 58 "4" 3>&1 1>&2 2>&3)" || exit 0
  MEMORY_MB="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "MEMORY" --inputbox "RAM in MiB" 8 58 "6144" 3>&1 1>&2 2>&3)" || exit 0
  OS_DISK_GB="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "OS DISK" --inputbox "Ubuntu OS disk in GiB" 8 58 "80" 3>&1 1>&2 2>&3)" || exit 0
  DATA_SIZE_GB="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "DATA DISK" --inputbox "Media data disk in GiB" 8 58 "500" 3>&1 1>&2 2>&3)" || exit 0
  BRIDGE="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "NETWORK" --inputbox "Proxmox bridge" 8 58 "vmbr0" 3>&1 1>&2 2>&3)" || exit 0

  [[ "$CORES" =~ ^[1-9][0-9]*$ ]] || die "CPU cores must be a positive integer."
  [[ "$MEMORY_MB" =~ ^[1-9][0-9]*$ ]] || die "RAM must be a positive integer."
  [[ "$OS_DISK_GB" =~ ^[1-9][0-9]*$ ]] || die "OS disk size must be a positive integer."
  [[ "$DATA_SIZE_GB" =~ ^[1-9][0-9]*$ ]] || die "Data disk size must be a positive integer."
  ip link show "$BRIDGE" >/dev/null 2>&1 || die "Bridge '$BRIDGE' does not exist."
}

choose_settings() {
  if whiptail --backtitle "Proxmox Media Stack Helper" --title "SETTINGS" \
    --yesno "Use recommended default VM settings?\n\n4 vCPU\n6 GiB RAM\n80 GiB Ubuntu disk\n500 GiB data disk\nvmbr0 / DHCP" 14 62 \
    --yes-button "Default" --no-button "Advanced"; then
    default_settings
  else
    advanced_settings
  fi
  local suggested
  suggested="$(pvesm status -content images | awk 'NR==2 {print $1}')"
  VM_STORAGE="$(storage_menu "Choose storage for the Ubuntu OS disk." "$suggested")" || exit 0
  DATA_STORAGE="$(storage_menu "Choose storage for the media data disk." "$VM_STORAGE")" || exit 0
}

get_proton_config() {
  PROTON_CONFIG="$(whiptail --backtitle "Proxmox Media Stack Helper" --title "PROTON VPN" \
    --inputbox "Path on the Proxmox host to your Proton VPN WireGuard .conf file.\n\nLeave blank to create the VM and prepare the stack without starting the Docker services." \
    13 76 "" 3>&1 1>&2 2>&3)" || exit 0
  if [[ -n "$PROTON_CONFIG" ]]; then
    [[ -r "$PROTON_CONFIG" ]] || die "Cannot read Proton configuration: $PROTON_CONFIG"
    grep -q '^PrivateKey[[:space:]]*=' "$PROTON_CONFIG" || die "The selected Proton config has no PrivateKey."
    grep -q '^Address[[:space:]]*=' "$PROTON_CONFIG" || die "The selected Proton config has no Address."
  fi
}

validate_capacity() {
  pvesm status --storage "$VM_STORAGE" >/dev/null 2>&1 || die "OS storage '$VM_STORAGE' is unavailable."
  pvesm status --storage "$DATA_STORAGE" >/dev/null 2>&1 || die "Data storage '$DATA_STORAGE' is unavailable."
}

refresh_repo() {
  if [[ -d "$WORK_DIR/.git" ]]; then
    git -C "$WORK_DIR" fetch --quiet origin main
    git -C "$WORK_DIR" reset --hard origin/main >/dev/null
  else
    rm -rf "$WORK_DIR"
    git clone --quiet --depth 1 --branch main "$REPO_URL" "$WORK_DIR"
  fi
  chmod +x "$WORK_DIR"/*.sh
}

ensure_snippet_storage() {
  install -d -m 0700 "$SNIPPET_DIR"
  local content
  content="$(pvesm config local 2>/dev/null | awk -F': ' '$1=="content"{print $2}')"
  if [[ ",$content," != *",snippets,"* ]]; then
    msg_info "Enabling snippets on Proxmox 'local' storage..."
    local new_content="${content:+${content},}snippets"
    pvesm set local --content "$new_content"
    msg_ok "Enabled snippets storage"
  fi
}

yaml_indent_file() { sed 's/^/      /' "$1"; }

write_cloud_init() {
  SNIPPET_FILE="${SNIPPET_DIR}/media-stack-${VMID}-user-data.yml"
  local proton_block=""
  local install_cmd=""
  if [[ -n "$PROTON_CONFIG" ]]; then
    proton_block="$(yaml_indent_file "$PROTON_CONFIG")"
    install_cmd="printf '\\n\\n/dev/sdb\\n/dev/sdb\\n/root/proton-wireguard.conf\\n' | ./10-install-media-stack.sh"
  else
    install_cmd="echo 'Proton VPN config not supplied; stack repository prepared but Docker media services were not installed.'"
  fi

  cat >"$SNIPPET_FILE" <<EOF
#cloud-config
package_update: true
packages:
  - git
  - qemu-guest-agent
write_files:
EOF
  if [[ -n "$PROTON_CONFIG" ]]; then
    cat >>"$SNIPPET_FILE" <<EOF
  - path: /root/proton-wireguard.conf
    owner: root:root
    permissions: '0600'
    content: |
${proton_block}
EOF
  else
    cat >>"$SNIPPET_FILE" <<'EOF'
  - path: /root/proton-wireguard.conf.NOT_CONFIGURED
    owner: root:root
    permissions: '0600'
    content: |
      Proton VPN configuration was not supplied by the Proxmox helper.
EOF
  fi

  cat >>"$SNIPPET_FILE" <<EOF
runcmd:
  - [ systemctl, enable, --now, qemu-guest-agent ]
  - [ bash, -lc, "rm -rf /opt/proxmox-media-stack && git clone --depth 1 --branch main ${REPO_URL} /opt/proxmox-media-stack" ]
  - [ bash, -lc, "chmod +x /opt/proxmox-media-stack/*.sh" ]
  - [ bash, -lc, "cd /opt/proxmox-media-stack && (${install_cmd}) >>/var/log/media-stack-bootstrap.log 2>&1" ]
  - [ bash, -lc, "if [ -x /opt/media-stack/30-verify-stack.sh ]; then /opt/media-stack/30-verify-stack.sh >>/var/log/media-stack-bootstrap.log 2>&1 || true; fi" ]
  - [ bash, -lc, "rm -f /root/proton-wireguard.conf" ]
  - [ bash, -lc, "install -d -m 0755 /var/lib/media-stack-helper && date -Is > /var/lib/media-stack-helper/complete" ]
final_message: "Proxmox Media Stack helper bootstrap completed."
EOF
  chmod 0600 "$SNIPPET_FILE"
}

create_vm() {
  msg_info "Creating Ubuntu 26.04 LTS VM..."
  "$WORK_DIR/00-create-proxmox-vm.sh" \
    --vmid "$VMID" --name "$VM_NAME" --storage "$VM_STORAGE" --bridge "$BRIDGE" \
    --cores "$CORES" --memory "$MEMORY_MB" --os-disk "$OS_DISK_GB" --user "$CI_USER" \
    --data-storage "$DATA_STORAGE" --data-size "$DATA_SIZE_GB" --no-start
  msg_ok "Created Ubuntu VM $VMID"
}

attach_cloud_init_and_start() {
  msg_info "Attaching one-time media-stack bootstrap..."
  qm set "$VMID" --cicustom "user=local:snippets/$(basename "$SNIPPET_FILE")" >/dev/null
  qm cloudinit update "$VMID" >/dev/null 2>&1 || true
  qm start "$VMID"
  STARTED_VM="yes"
  msg_ok "Started VM $VMID"
}

wait_for_bootstrap() {
  msg_info "Waiting for Ubuntu cloud-init and media-stack bootstrap..."
  local deadline=$((SECONDS + 3600))
  local agent_seen="no"
  while ((SECONDS < deadline)); do
    if qm agent "$VMID" ping >/dev/null 2>&1; then
      agent_seen="yes"
      if qm guest exec "$VMID" -- test -f /var/lib/media-stack-helper/complete >/dev/null 2>&1; then
        msg_ok "Guest bootstrap completed"
        return 0
      fi
    fi
    sleep 10
  done
  if [[ "$agent_seen" == "yes" ]]; then
    msg_error "Timed out waiting for the media stack to finish. Inspect /var/log/media-stack-bootstrap.log inside the VM."
  else
    msg_error "Timed out waiting for QEMU Guest Agent. Open the VM console and inspect cloud-init."
  fi
  return 1
}

remove_secret_cloud_init() {
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    qm guest exec "$VMID" -- bash -lc \
      'rm -f /var/lib/cloud/instance/user-data.txt /var/lib/cloud/instance/vendor-data.txt /root/proton-wireguard.conf' \
      >/dev/null 2>&1 || true
  fi
  qm set "$VMID" --delete cicustom >/dev/null 2>&1 || true
  qm cloudinit update "$VMID" >/dev/null 2>&1 || true
  rm -f "$SNIPPET_FILE"
  SNIPPET_FILE=""
}

show_summary() {
  local ip=""
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    ip="$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
      grep -oE '"ip-address"\\s*:\\s*"([0-9]{1,3}\\.){3}[0-9]{1,3}"' | \
      grep -v '127\\.0\\.0\\.1' | head -1 | cut -d'"' -f4 || true)"
  fi
  echo
  echo -e "${GN}Media Stack VM created successfully.${CL}"
  echo "  VM ID:        $VMID"
  echo "  VM name:      $VM_NAME"
  echo "  Ubuntu:       26.04 LTS"
  echo "  VM storage:   $VM_STORAGE"
  echo "  Data storage: $DATA_STORAGE (${DATA_SIZE_GB} GiB)"
  [[ -n "$ip" ]] && echo "  VM IP:        $ip"
  echo
  if [[ -n "$PROTON_CONFIG" ]]; then
    echo "Verification:"
    echo "  sudo /opt/media-stack/30-verify-stack.sh"
    [[ -n "$ip" ]] && cat <<EOF
Web interfaces:
  Jellyfin:     http://${ip}:8096
  Sonarr:       http://${ip}:8989
  Radarr:       http://${ip}:7878
  Prowlarr:     http://${ip}:9696
  Bazarr:       http://${ip}:6767
  Seerr:        http://${ip}:5055
  qBittorrent:  http://${ip}:8080
EOF
  else
    echo "Ubuntu and the repository are ready, but Docker media services were not started because no Proton config was supplied."
    echo "Inside the VM: cd /opt/proxmox-media-stack && sudo ./10-install-media-stack.sh"
  fi
  echo "Bootstrap log inside VM: /var/log/media-stack-bootstrap.log"
}

main() {
  header_info
  check_root
  ensure_deps
  arch_check
  pve_check

  if ! whiptail --backtitle "Proxmox Media Stack Helper" --title "CREATE MEDIA STACK VM" \
    --yesno "This creates a new Ubuntu Server 26.04 LTS VM and a separate media data disk.\n\nIt never formats existing physical disks. The new virtual data disk is blank and will be formatted inside the guest.\n\nProceed?" 16 76; then
    exit 0
  fi

  choose_settings
  get_proton_config
  validate_capacity

  header_info
  echo -e "${BL}Configuration${CL}"
  echo "  Method:       $METHOD"
  echo "  VM ID:        $VMID"
  echo "  Name:         $VM_NAME"
  echo "  CPU/RAM:      ${CORES} cores / ${MEMORY_MB} MiB"
  echo "  OS disk:      ${OS_DISK_GB} GiB on $VM_STORAGE"
  echo "  Data disk:    ${DATA_SIZE_GB} GiB on $DATA_STORAGE"
  echo "  Bridge:       $BRIDGE"
  echo "  Proton VPN:   $([[ -n "$PROTON_CONFIG" ]] && echo configured || echo deferred)"

  whiptail --backtitle "Proxmox Media Stack Helper" --title "CONFIRM" \
    --yesno "Create VM $VMID ($VM_NAME) with these settings?" 10 64 || exit 0

  refresh_repo
  ensure_snippet_storage
  write_cloud_init
  create_vm
  attach_cloud_init_and_start

  if wait_for_bootstrap; then
    remove_secret_cloud_init
    show_summary | tee -a "$HELPER_LOG"
  else
    echo "Troubleshooting snippet retained at: $SNIPPET_FILE"
    echo "It contains the Proton configuration if one was supplied. Remove it after troubleshooting."
    exit 1
  fi
}

main "$@"
