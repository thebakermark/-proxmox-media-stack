#!/usr/bin/env bash
set -Eeuo pipefail

# Surgically replace the Proton VPN WireGuard credentials in an existing
# install, without a full reinstall. Useful if the original config was
# pasted wrong (a masked/placeholder key, a stale profile, etc.) and
# gluetun is failing to start as a result.

readonly STACK_DIR="/opt/media-stack"
readonly ENV_FILE="${STACK_DIR}/.env"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[[ ${EUID} -eq 0 ]] || die "Run with sudo: sudo ./fix-proton-vpn.sh"
[[ -r "$ENV_FILE" ]] || die "$ENV_FILE not found. Run 10-install-media-stack.sh first."

info "Paste your Proton VPN WireGuard configuration below (the actual"
info "downloaded file contents, not a masked/displayed version), then press Ctrl-D."
info "Note: Proton (like WireGuard generally) only shows a profile's real"
info "private key once, at creation. Re-opening an existing profile shows it"
info "masked -- if that's what you have, generate a brand-new profile instead."
PROTON_INPUT="$(cat)"
if [[ "$PROTON_INPUT" != *$'\n'* && -r "$PROTON_INPUT" ]]; then
  PROTON_CONFIG_CONTENT="$(cat -- "$PROTON_INPUT")"
else
  PROTON_CONFIG_CONTENT="$PROTON_INPUT"
fi
PROTON_CONFIG_CONTENT="$(tr -d '\r' <<<"$PROTON_CONFIG_CONTENT")"

PROTON_PRIVATE_KEY="$(sed -n 's/^PrivateKey[[:space:]]*=[[:space:]]*//p' <<<"$PROTON_CONFIG_CONTENT" | head -1 | sed -E 's/[[:space:]]+$//')"
PROTON_ADDRESSES="$(sed -n 's/^Address[[:space:]]*=[[:space:]]*//p' <<<"$PROTON_CONFIG_CONTENT" | head -1 | cut -d',' -f1 | tr -d ' ')"

[[ -n "$PROTON_PRIVATE_KEY" ]] || die "PrivateKey was not found in the pasted configuration."
[[ -n "$PROTON_ADDRESSES" ]] || die "Address was not found in the pasted configuration."
if [[ "${#PROTON_PRIVATE_KEY}" -ne 44 || "$PROTON_PRIVATE_KEY" =~ ^\*+$ ]]; then
  die "PrivateKey doesn't look like a real WireGuard key (got ${#PROTON_PRIVATE_KEY} characters, expected 44). Generate a brand-new WireGuard configuration profile in your Proton account and use that file immediately."
fi

sed -i "s|^PROTON_WIREGUARD_PRIVATE_KEY=.*|PROTON_WIREGUARD_PRIVATE_KEY=${PROTON_PRIVATE_KEY}|" "$ENV_FILE"
sed -i "s|^PROTON_WIREGUARD_ADDRESSES=.*|PROTON_WIREGUARD_ADDRESSES=${PROTON_ADDRESSES}|" "$ENV_FILE"
chmod 0600 "$ENV_FILE"
unset PROTON_INPUT PROTON_CONFIG_CONTENT PROTON_PRIVATE_KEY

info "Updated $ENV_FILE. Restarting gluetun and qBittorrent..."
cd "$STACK_DIR"
docker compose up -d --force-recreate gluetun qbittorrent

info "Waiting for gluetun to report healthy..."
STATUS="none"
for _ in $(seq 1 24); do
  STATUS="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' gluetun 2>/dev/null || true)"
  if [[ "$STATUS" == "healthy" ]]; then
    info "SUCCESS: gluetun is healthy."
    exit 0
  fi
  sleep 5
done
info "gluetun did not report healthy in time (status: $STATUS)."
info "--- recent gluetun logs ---"
docker logs gluetun 2>&1 | tail -15
exit 1
