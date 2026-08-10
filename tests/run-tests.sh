#!/usr/bin/env bash
# Static/unit tests for installer behavior that don't require a Proxmox host,
# a real Ubuntu guest, or Docker. Run from anywhere: bash tests/run-tests.sh
set -Eeuo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TESTS_DIR
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"
readonly REPO_DIR

FAILED=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s: %s\n' "$1" "$2"; FAILED=$((FAILED + 1)); }

# --- 1. Checksum manifest parsing --------------------------------------------
test_checksum_parsing() {
  local name="checksum manifest parsing (asterisk-prefixed filename, no space)"
  local canary='$2 == "*" image || $2 == image {print; exit}'
  if ! grep -qF "$canary" "$REPO_DIR/00-create-proxmox-vm.sh"; then
    not_ok "$name" "expected awk expression not found in 00-create-proxmox-vm.sh; update this test to match"
    return
  fi
  local result
  result="$(awk -v image="ubuntu-26.04-server-cloudimg-amd64.img" "$canary" "$TESTS_DIR/fixtures/SHA256SUMS.sample")"
  if [[ "$result" == "9dc7c5363c0146a08ba0c9aa834d82c2c6dfbb1c471ad9a2f0aba1189e21be05 *ubuntu-26.04-server-cloudimg-amd64.img" ]]; then
    ok "$name"
  else
    not_ok "$name" "expected the amd64.img line, got: '$result'"
    return
  fi

  local no_match
  no_match="$(awk -v image="ubuntu-26.04-server-cloudimg-arm64.img" "$canary" "$TESTS_DIR/fixtures/SHA256SUMS.sample")"
  if [[ -z "$no_match" ]]; then
    ok "checksum manifest parsing (no false match for absent file)"
  else
    not_ok "checksum manifest parsing (no false match for absent file)" "unexpectedly matched: '$no_match'"
  fi
}

# --- 2. OS detection ----------------------------------------------------------
test_os_detection() {
  local name_prefix="OS detection"
  for cond in '[[ "${ID:-}" == "ubuntu" ]]' '[[ "${VERSION_ID:-}" == "26.04" ]]'; do
    if ! grep -qF "$cond" "$REPO_DIR/10-install-media-stack.sh"; then
      not_ok "$name_prefix" "expected condition not found in 10-install-media-stack.sh: $cond"
      return
    fi
  done

  # Accepts Ubuntu 26.04
  ( ID="ubuntu"; VERSION_ID="26.04"
    if [[ "${ID:-}" == "ubuntu" ]] && [[ "${VERSION_ID:-}" == "26.04" ]]; then exit 0; else exit 1; fi
  ) && ok "$name_prefix accepts Ubuntu 26.04" || not_ok "$name_prefix accepts Ubuntu 26.04" "condition rejected valid OS"

  # Rejects Debian
  ( ID="debian"; VERSION_ID="26.04"
    if [[ "${ID:-}" == "ubuntu" ]] && [[ "${VERSION_ID:-}" == "26.04" ]]; then exit 1; else exit 0; fi
  ) && ok "$name_prefix rejects non-Ubuntu" || not_ok "$name_prefix rejects non-Ubuntu" "condition accepted wrong distro"

  # Rejects Ubuntu 24.04
  ( ID="ubuntu"; VERSION_ID="24.04"
    if [[ "${ID:-}" == "ubuntu" ]] && [[ "${VERSION_ID:-}" == "26.04" ]]; then exit 1; else exit 0; fi
  ) && ok "$name_prefix rejects wrong Ubuntu version" || not_ok "$name_prefix rejects wrong Ubuntu version" "condition accepted wrong version"
}

# --- 3. Storage safety: device_is_verified_blank (real scsi_debug disk) ------
# A loopback device reports lsblk TYPE=loop, not TYPE=disk, so it can't exercise
# the real whole-disk check. scsi_debug creates a fake SCSI disk that behaves
# like a real /dev/sdX for lsblk/blkid purposes.
test_storage_safety() {
  local name="storage safety: device_is_verified_blank"
  if [[ "$(uname -s)" != "Linux" ]] || [[ ${EUID} -ne 0 ]]; then
    printf 'skip - %s: requires Linux + root (run as: sudo bash tests/run-tests.sh)\n' "$name"
    return
  fi
  if ! modprobe scsi_debug dev_size_mb=64 2>/dev/null; then
    printf 'skip - %s: scsi_debug kernel module is unavailable in this environment\n' "$name"
    return
  fi

  local root_source root_disk dev="" tries=0
  root_source="$(findmnt -no SOURCE / 2>/dev/null || true)"
  root_disk="$(lsblk -no PKNAME "$root_source" 2>/dev/null || true)"
  while [[ -z "$dev" && $tries -lt 20 ]]; do
    dev="$(lsblk -dn -o NAME,TYPE | awk -v root="$root_disk" '$2=="disk" && $1!=root{print $1; exit}')"
    [[ -n "$dev" ]] || { sleep 0.5; tries=$((tries + 1)); }
  done
  if [[ -z "$dev" ]]; then
    printf 'skip - %s: scsi_debug disk did not appear\n' "$name"
    modprobe -r scsi_debug 2>/dev/null || true
    return
  fi
  dev="/dev/$dev"

  local funcs_file
  funcs_file="$(mktemp)"
  sed -n '/# TESTABLE:BEGIN/,/# TESTABLE:END/p' "$REPO_DIR/10-install-media-stack.sh" > "$funcs_file"
  # shellcheck disable=SC1090
  source "$funcs_file"
  rm -f "$funcs_file"

  if device_is_verified_blank "$dev"; then
    ok "$name (blank disk accepted)"
  else
    not_ok "$name (blank disk accepted)" "a genuinely blank disk ($dev) was rejected"
  fi

  mkfs.ext4 -q -F "$dev" >/dev/null 2>&1

  if ! device_is_verified_blank "$dev"; then
    ok "$name (formatted disk rejected)"
  else
    not_ok "$name (formatted disk rejected)" "a disk with an existing filesystem ($dev) was accepted"
  fi

  modprobe -r scsi_debug 2>/dev/null || true
}

# --- 4. compose.yml only references env vars the installer writes ------------
test_required_env_vars() {
  local name="compose.yml env vars are all provided by 10-install-media-stack.sh"
  local compose_vars written_vars missing=()
  compose_vars="$(grep -oE '\$\{[A-Z_]+(:-[^}]*)?\}' "$REPO_DIR/compose.yml" | sed -E 's/\$\{([A-Z_]+).*/\1/' | sort -u)"
  written_vars="$(sed -n '/^cat > "\$ENV_FILE" <<EOF$/,/^EOF$/p' "$REPO_DIR/10-install-media-stack.sh" | grep -oE '^[A-Z_]+=' | tr -d '=' | sort -u)"

  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    grep -qxF "$var" <<<"$written_vars" || missing+=("$var")
  done <<<"$compose_vars"

  if [[ "${#missing[@]}" -eq 0 ]]; then
    ok "$name"
  else
    not_ok "$name" "referenced but never written: ${missing[*]}"
  fi
}

# --- 5. Compose profiles match the README's documented list ------------------
test_compose_profiles() {
  local name="compose.yml profiles match README's documented profile list"
  local compose_profiles readme_profiles
  compose_profiles="$(grep -oE 'profiles: \["[a-z]+"\]' "$REPO_DIR/compose.yml" | grep -oE '"[a-z]+"' | tr -d '"' | sort -u)"
  readme_profiles="$(grep -oE '^- `[a-z]+`' "$REPO_DIR/README.md" | grep -oE '`[a-z]+`' | tr -d '`' | sort -u)"

  if [[ "$compose_profiles" == "$readme_profiles" ]]; then
    ok "$name"
  else
    not_ok "$name" "compose=[$(tr '\n' ',' <<<"$compose_profiles")] readme=[$(tr '\n' ',' <<<"$readme_profiles")]"
  fi
}

# --- 6. qBittorrent VPN network isolation is structurally enforced -----------
test_vpn_isolation_static() {
  local name="qbittorrent is network-isolated behind gluetun in compose.yml"
  local block
  block="$(awk '/^  qbittorrent:/{flag=1} /^  [a-z]/{if ($0 !~ /^  qbittorrent:/ && flag) exit} flag' "$REPO_DIR/compose.yml")"

  if grep -qF 'network_mode: service:gluetun' <<<"$block"; then
    ok "$name (network_mode: service:gluetun present)"
  else
    not_ok "$name (network_mode: service:gluetun present)" "qbittorrent service block did not declare network_mode: service:gluetun"
  fi

  if grep -qE '^\s+networks:' <<<"$block"; then
    not_ok "$name (no independent networks: key)" "qbittorrent must not declare its own networks: list while sharing gluetun's namespace"
  else
    ok "$name (no independent networks: key)"
  fi

  if grep -qF 'condition: service_healthy' <<<"$block"; then
    ok "$name (depends_on gluetun service_healthy)"
  else
    not_ok "$name (depends_on gluetun service_healthy)" "qbittorrent should wait for gluetun's healthcheck before starting"
  fi
}

# --- 7. Proton WireGuard config parsing: padding + IPv4-only Address --------
# Two regressions caught by actually running this against a real Proton
# config: (a) a previous version split on every '=' in the line, silently
# truncating the trailing '=' padding character that (almost) every
# WireGuard base64 private key ends with, producing an invalid 43-character
# key gluetun rejected outright ("illegal base64 data"); (b) Proton's
# Address field is IPv4,IPv6 comma-separated, and gluetun rejects the
# interface outright if an IPv6 address is present -- this stack is
# IPv4-only, so only the first address must be kept. Neither must regress.
test_proton_key_parsing() {
  local name="Proton config parsing preserves base64 '=' padding in PrivateKey"
  for canary in \
    "sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p'" \
    "sed -n 's/^Address[[:space:]]*=[[:space:]]*//p'" \
    "cut -d',' -f1"; do
    if ! grep -qF "$canary" "$REPO_DIR/10-install-media-stack.sh"; then
      not_ok "$name" "expected extraction expression not found in 10-install-media-stack.sh: $canary; update this test to match"
      return
    fi
  done

  local content key addr
  content='[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.2.0.2/32, 2a07:b944::2:2/128
DNS = 10.2.0.1, 2a07:b944::2:1

[Peer]
PublicKey = abcDEF123uvwXYZ789+/=
Endpoint = 1.2.3.4:51820
'
  key="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' <<<"$content" | head -1 | sed -E 's/[[:space:]]+$//')"
  addr="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' <<<"$content" | head -1 | cut -d',' -f1 | tr -d ' ')"

  if [[ "$key" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" && "${#key}" -eq 44 ]]; then
    ok "$name"
  else
    not_ok "$name" "expected a 44-char key ending in '=', got '$key' (${#key} chars)"
  fi

  if [[ "$addr" == "10.2.0.2/32" ]]; then
    ok "Proton config parsing (Address extracted as IPv4-only)"
  else
    not_ok "Proton config parsing (Address extracted as IPv4-only)" "got '$addr', expected IPv6 stripped"
  fi
}

# --- 7b. Masked/placeholder Proton private keys are rejected, not written ---
# Proton (and WireGuard generally) only shows a profile's real private key
# once, at creation -- re-opening or re-downloading an existing profile
# shows it masked as literal asterisks. Caught live: this silently wrote
# "*****" into .env, which gluetun then rejected with an opaque "illegal
# base64 data at input byte 0", far from where the actual problem was.
test_proton_key_validation() {
  local name="Proton config parsing rejects a masked/asterisk private key"
  local canary='^\*+$'
  if ! grep -qF "$canary" "$REPO_DIR/10-install-media-stack.sh"; then
    not_ok "$name" "expected masked-key rejection pattern not found in 10-install-media-stack.sh; update this test to match"
    return
  fi

  local masked_key="*****"
  if [[ "${#masked_key}" -ne 44 || "$masked_key" =~ ^\*+$ ]]; then
    ok "$name"
  else
    not_ok "$name" "the validation condition failed to flag a masked key as invalid"
  fi

  local real_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  if [[ "${#real_key}" -ne 44 || "$real_key" =~ ^\*+$ ]]; then
    not_ok "Proton config parsing accepts a valid 44-char key" "a genuine 44-char key was incorrectly flagged as invalid"
  else
    ok "Proton config parsing accepts a valid 44-char key"
  fi
}

# --- 8. qBittorrent WebUI password hash matches qBittorrent's own algorithm -
# Verified against a publicly documented reference hash (password
# "adminadmin") from qBittorrent's own PBKDF2-SHA512 implementation
# (src/base/utils/password.cpp: 100000 iterations, 64-byte output). Wrong
# iteration count, digest, or key length silently locks the generated
# credential out with no useful error, so this must never regress.
test_qbittorrent_password_hash() {
  local name="qBittorrent PBKDF2 hash generation matches qBittorrent's own algorithm"
  local canary="pbkdf2_hmac('sha512', sys.argv[1].encode(), salt, 100000, dklen=64)"
  if ! grep -qF "$canary" "$REPO_DIR/10-install-media-stack.sh"; then
    not_ok "$name" "expected PBKDF2 call not found in 10-install-media-stack.sh: $canary; update this test to match"
    return
  fi
  command -v python3 >/dev/null || { printf 'skip - %s: python3 not available\n' "$name"; return; }

  local result
  result="$(python3 -c "
import hashlib, base64
salt = base64.b64decode('ARQ77eY1NUZaQsuDHbIMCA==')
derived = hashlib.pbkdf2_hmac('sha512', b'adminadmin', salt, 100000, dklen=64)
print(base64.b64encode(derived).decode())
")"
  if [[ "$result" == "0WMRkYTUWVT9wVvdDtHAjU9b3b7uB8NR1Gur2hmQCvCDpm39Q+PsJRJPaCU51dEiz+dTzh8qbPsL8WkFljQYFQ==" ]]; then
    ok "$name"
  else
    not_ok "$name" "got '$result'"
  fi
}

# --- 9. Jellyfin/Seerr auto-setup: specific ordering/payload bugs caught live
# All three caught by actually running the automation against real
# containers, not by static review -- each failed silently or with a
# misleading error rather than an obvious one:
#  (a) POST /Startup/User 404s unless GET /Startup/User is called first
#      (it triggers Jellyfin's user-manager init, creating the implicit
#      first user the POST then renames/passwords).
#  (b) Seerr's own hostname builder string-concatenates a missing urlBase
#      as the literal word "undefined" into the connection URL.
#  (c) The Jellyfin/Seerr readiness probes must not use -f on calls whose
#      response body is needed on error (-f discards the body on any
#      non-2xx status), and must poll an endpoint that stays unauthenticated
#      regardless of setup state (/Startup/* requires auth once Jellyfin's
#      wizard is already complete, breaking a plain readiness check on an
#      idempotent re-run).
#  (d) Connecting Seerr to a media server does not by itself mark Seerr as
#      set up -- initialized stayed false until POST /settings/initialize,
#      the explicit final step Seerr's own frontend wizard calls, was added.
test_jellyfin_seerr_setup_order() {
  local name="Jellyfin/Seerr setup: known-bad request patterns don't regress"

  if ! grep -qF 'curl -fsS "$base/Startup/User" >/dev/null' "$REPO_DIR/20-wire-arr-apps.sh"; then
    not_ok "$name (GET /Startup/User called before POST)" "expected GET call not found in 20-wire-arr-apps.sh; update this test to match"
  else
    ok "$name (GET /Startup/User called before POST)"
  fi

  if grep -qF 'urlBase:""' "$REPO_DIR/20-wire-arr-apps.sh"; then
    ok "$name (Seerr fallback login includes urlBase)"
  else
    not_ok "$name (Seerr fallback login includes urlBase)" "expected urlBase:\"\" not found in the Seerr auth payload; a missing urlBase becomes the literal string 'undefined' in Seerr's own URL builder"
  fi

  if grep -qF 'curl -sS -c "$SEERR_COOKIE_JAR"' "$REPO_DIR/20-wire-arr-apps.sh"; then
    ok "$name (Seerr login calls omit -f so error bodies are readable)"
  else
    not_ok "$name (Seerr login calls omit -f so error bodies are readable)" "expected a non-f curl call for Seerr login; -f discards the response body needed to detect the 'no hostname' retry case"
  fi

  if grep -qF 'System/Info/Public' "$REPO_DIR/20-wire-arr-apps.sh" && grep -q 'for _ in \$(seq 1 30)' "$REPO_DIR/20-wire-arr-apps.sh"; then
    ok "$name (Jellyfin readiness probe uses an always-unauthenticated endpoint)"
  else
    not_ok "$name (Jellyfin readiness probe uses an always-unauthenticated endpoint)" "expected the readiness retry loop to poll System/Info/Public; /Startup/* requires auth once the wizard is already complete"
  fi

  if grep -qF 'settings/initialize' "$REPO_DIR/20-wire-arr-apps.sh"; then
    ok "$name (Seerr setup is explicitly marked complete)"
  else
    not_ok "$name (Seerr setup is explicitly marked complete)" "expected a call to settings/initialize; connecting a media server alone does not set Seerr's initialized flag"
  fi
}

test_checksum_parsing
test_os_detection
test_storage_safety
test_required_env_vars
test_compose_profiles
test_vpn_isolation_static
test_proton_key_parsing
test_proton_key_validation
test_qbittorrent_password_hash
test_jellyfin_seerr_setup_order

printf '\n'
if [[ "$FAILED" -eq 0 ]]; then
  printf 'All static installer tests passed.\n'
  exit 0
else
  printf '%d static installer test(s) failed.\n' "$FAILED"
  exit 1
fi
