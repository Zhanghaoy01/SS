#!/usr/bin/env bash
#
# SS-NONE one-click installer
# Backend: sing-box
#
# Features:
#   - Shadowsocks method: none (no encryption)
#   - TCP + UDP on the same port
#   - Optional outbound interface / IPv4 binding
#   - systemd auto-start
#
# Usage:
#   bash install.sh
#   bash install.sh --port 12074
#   bash install.sh --port 12074 --out-iface eth0
#   bash install.sh --port 12074 --out-ip 1.2.3.4
#
# One-line GitHub usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)
#

set -Eeuo pipefail

PORT="12074"
OUT_IFACE=""
OUT_IP=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[-]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage:
  $0 [options]

Options:
  --port PORT          Shadowsocks listen port (default: 12074)
  --out-iface IFACE    Bind outbound traffic to interface, e.g. eth0
  --out-ip IPv4        Bind outbound traffic to IPv4 address
  -h, --help           Show this help

Examples:
  $0
  $0 --port 10001
  $0 --port 12074 --out-iface eth1
  $0 --port 12074 --out-ip 192.0.2.10
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            [[ $# -ge 2 ]] || error "--port requires a value"
            PORT="$2"
            shift 2
            ;;
        --out-iface)
            [[ $# -ge 2 ]] || error "--out-iface requires a value"
            OUT_IFACE="$2"
            shift 2
            ;;
        --out-ip)
            [[ $# -ge 2 ]] || error "--out-ip requires a value"
            OUT_IP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

[[ "${EUID}" -eq 0 ]] || error "Please run as root."

[[ "$PORT" =~ ^[0-9]+$ ]] || error "Invalid port: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || error "Port must be between 1 and 65535."

if [[ -n "$OUT_IFACE" ]]; then
    ip link show "$OUT_IFACE" >/dev/null 2>&1 || error "Interface not found: $OUT_IFACE"
fi

if [[ -n "$OUT_IP" ]]; then
    [[ "$OUT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || error "Invalid IPv4 address: $OUT_IP"
fi

command -v curl >/dev/null 2>&1 || {
    info "Installing curl..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl
    else
        error "curl is required but could not be installed automatically."
    fi
}

info "Installing/updating sing-box from the official installer..."
curl -fsSL https://sing-box.app/install.sh | sh

command -v sing-box >/dev/null 2>&1 || error "sing-box installation failed."

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"

mkdir -p "$CONFIG_DIR"

# Back up an existing configuration.
if [[ -f "$CONFIG_FILE" ]]; then
    BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$CONFIG_FILE" "$BACKUP"
    warn "Existing config backed up to: $BACKUP"
fi

OUTBOUND_EXTRA=""

if [[ -n "$OUT_IFACE" ]]; then
    OUTBOUND_EXTRA+=$',\n      "bind_interface": "'"$OUT_IFACE"'"'
fi

if [[ -n "$OUT_IP" ]]; then
    OUTBOUND_EXTRA+=$',\n      "inet4_bind_address": "'"$OUT_IP"'"'
fi

cat >"$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-none-in",
      "listen": "0.0.0.0",
      "listen_port": ${PORT},
      "method": "none",
      "password": "none"
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"${OUTBOUND_EXTRA}
    }
  ],
  "route": {
    "final": "direct-out"
  }
}
EOF

info "Checking sing-box configuration..."
sing-box check -c "$CONFIG_FILE" || error "Configuration check failed."

if command -v systemctl >/dev/null 2>&1; then
    info "Enabling and restarting sing-box..."
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box
else
    error "systemd/systemctl was not found. This script currently expects a systemd Linux server."
fi

# If UFW is already active, open both TCP and UDP automatically.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
    info "UFW detected: opening ${PORT}/tcp and ${PORT}/udp..."
    ufw allow "${PORT}/tcp" >/dev/null
    ufw allow "${PORT}/udp" >/dev/null
fi

# If firewalld is already active, open both TCP and UDP automatically.
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    info "firewalld detected: opening ${PORT}/tcp and ${PORT}/udp..."
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --permanent --add-port="${PORT}/udp" >/dev/null
    firewall-cmd --reload >/dev/null
fi

PUBLIC_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "$PUBLIC_IP" ]]; then
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
fi

echo
echo "=================================================="
echo " Shadowsocks NONE installation completed"
echo "=================================================="
echo " Server : ${PUBLIC_IP:-<server-ip>}"
echo " Port   : ${PORT}"
echo " Method : none"
echo " Pass   : none"
echo " TCP    : enabled"
echo " UDP    : enabled"
echo " Egress : ${OUT_IFACE:-default route}"
echo " Out IP : ${OUT_IP:-default source IP}"
echo " Config : ${CONFIG_FILE}"
echo "=================================================="
echo
echo "Client example:"
echo "  server   = ${PUBLIC_IP:-YOUR_SERVER_IP}"
echo "  port     = ${PORT}"
echo "  method   = none"
echo "  password = none"
echo
echo "Useful commands:"
echo "  systemctl status sing-box"
echo "  systemctl restart sing-box"
echo "  journalctl -u sing-box -f"
echo

if command -v ss >/dev/null 2>&1; then
    echo "Listening sockets:"
    ss -lntup 2>/dev/null | grep -E ":${PORT}\\b" || true
fi

warn "method=none provides NO encryption or confidentiality."
warn "Only expose this service on networks/servers where plaintext transport is acceptable."
