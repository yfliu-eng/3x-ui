#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Stable Egress Node Provisioner
# Run on a fresh Ubuntu 22.04+ VPS (AWS Lightsail / DigitalOcean / Vultr)
#
# Usage: ./provision.sh [--role primary|backup] [--peer-endpoint <backup-ip>]
# =============================================================================

ROLE="${1:---role}"
ROLE_VALUE="${2:-primary}"
PEER_ENDPOINT="${4:-}"  # backup node's public IP, for primary; or primary's, for backup

if [[ "$ROLE" == "--role" ]]; then
    ROLE="$ROLE_VALUE"
else
    ROLE="primary"
fi

WG_PORT=51820
WG_INTERFACE="wg0"
WSTUNNEL_PORT=443  # TCP fallback on HTTPS port to survive hostile networks

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# --- Pre-flight ---
[[ $EUID -ne 0 ]] && err "Run as root"
[[ ! -f /etc/os-release ]] && err "Unsupported OS"
source /etc/os-release
[[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && warn "Tested on Ubuntu/Debian only"

PUBLIC_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com)
[[ -z "$PUBLIC_IP" ]] && err "Cannot detect public IP"
log "Public IP: $PUBLIC_IP"
log "Role: $ROLE"

# =============================================================================
# Layer 1: Egress Identity — install WireGuard, generate persistent keys
# =============================================================================
log "Installing WireGuard..."
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools qrencode

# Generate server keys (only if not already present — idempotent)
WG_DIR="/etc/wireguard"
if [[ ! -f "$WG_DIR/server_private.key" ]]; then
    wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key"
    log "Generated new server keypair"
else
    log "Server keypair already exists, reusing"
fi

SERVER_PRIVKEY=$(cat "$WG_DIR/server_private.key")
SERVER_PUBKEY=$(cat "$WG_DIR/server_public.key")

# Server address: primary = 10.100.0.1, backup = 10.100.1.1
if [[ "$ROLE" == "primary" ]]; then
    SERVER_ADDR="10.100.0.1/24"
else
    SERVER_ADDR="10.100.1.1/24"
fi

# =============================================================================
# Layer 2: Transport — WireGuard config + TCP fallback via wstunnel
# =============================================================================

# Enable IP forwarding (persistent)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# Detect default interface
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IF" ]] && err "Cannot detect default network interface"
log "Default interface: $DEFAULT_IF"

# Write WireGuard server config
cat > "$WG_DIR/$WG_INTERFACE.conf" <<EOF
# Stable Egress Substrate — $ROLE node
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[Interface]
Address = $SERVER_ADDR
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIVKEY

# NAT masquerade for egress
PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT

# Clients will be added by gen-client-configs.sh
# [Peer] sections appended below this line
EOF

chmod 600 "$WG_DIR/$WG_INTERFACE.conf"

# Enable and start WireGuard
systemctl enable wg-quick@$WG_INTERFACE
systemctl restart wg-quick@$WG_INTERFACE
log "WireGuard is running on :$WG_PORT/udp"

# --- TCP fallback: wstunnel ---
# For hotel/airport/corporate networks that block UDP entirely
log "Installing wstunnel (TCP fallback)..."
WSTUNNEL_VERSION="10.1.0"
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  WSTUNNEL_ARCH="x86_64-unknown-linux-gnu" ;;
    aarch64) WSTUNNEL_ARCH="aarch64-unknown-linux-gnu" ;;
    *)       warn "wstunnel: unsupported arch $ARCH, skipping TCP fallback" ; WSTUNNEL_ARCH="" ;;
esac

if [[ -n "$WSTUNNEL_ARCH" ]]; then
    WSTUNNEL_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VERSION}/wstunnel_${WSTUNNEL_VERSION}_${WSTUNNEL_ARCH}.tar.gz"
    curl -sL "$WSTUNNEL_URL" | tar xz -C /usr/local/bin/ wstunnel 2>/dev/null || {
        warn "wstunnel download failed — TCP fallback not installed"
        warn "Install manually from https://github.com/erebe/wstunnel/releases"
    }

    if command -v wstunnel &>/dev/null; then
        # systemd service: WebSocket tunnel wrapping WireGuard UDP
        cat > /etc/systemd/system/wstunnel-server.service <<SVCEOF
[Unit]
Description=wstunnel server — TCP fallback for WireGuard
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel server wss://0.0.0.0:${WSTUNNEL_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

        systemctl daemon-reload
        systemctl enable wstunnel-server
        systemctl restart wstunnel-server
        log "wstunnel TCP fallback running on :$WSTUNNEL_PORT/tcp (WSS)"
    fi
fi

# =============================================================================
# Layer 5: Operational Hygiene — hardening
# =============================================================================
log "Applying OS hardening..."
bash "$(dirname "$0")/harden.sh" || warn "Hardening script not found, skipping"

log ""
log "=========================================="
log " Node provisioned successfully"
log " Role:       $ROLE"
log " Public IP:  $PUBLIC_IP"
log " WG subnet:  $SERVER_ADDR"
log " WG port:    $WG_PORT/udp"
log " TCP fb:     $WSTUNNEL_PORT/tcp (wstunnel)"
log " Server pub: $SERVER_PUBKEY"
log "=========================================="
log ""
log "Next: run gen-client-configs.sh to create device configs"
