#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Variant A: Lightsail Single Node Provisioner
#
# Prerequisites (done in AWS console before running this script):
#   1. Create Lightsail instance: $5/mo Linux/Ubuntu, US region (e.g. us-east-1)
#      MUST be the $5 IPv4 bundle, NOT the $3.50 IPv6-only bundle
#   2. Attach a Lightsail Static IP to the instance
#      (Networking tab → Create static IP → Attach to instance)
#      Without this, the public IP changes on every stop/start
#   3. Open ports in Lightsail firewall:
#      - TCP 22 (SSH)
#      - UDP 41641 (Tailscale direct, optional but improves performance)
#   4. SSH in and run this script
#
# Usage: ./provision-lightsail.sh [--authkey tskey-auth-xxxxx]
# =============================================================================

TS_AUTHKEY="${2:-}"

# --- Colors / helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me || curl -4 -s icanhazip.com)
[[ -z "$PUBLIC_IP" ]] && err "Cannot detect public IPv4 — is this a $3.50 IPv6-only instance?"
log "Public IPv4: $PUBLIC_IP"

# --- Verify static IP ---
# On Lightsail, the metadata service can tell us if a static IP is attached.
# Without static IP, this whole module's invariant (fixed egress identity) breaks.
warn "VERIFY: Is a Lightsail Static IP attached to this instance?"
warn "If not, the public IP ($PUBLIC_IP) will change on stop/start."
warn "Attach one via: AWS Console → Lightsail → Networking → Static IPs"
echo ""

# =============================================================================
# Layer 1: Egress Identity — Tailscale exit node
# =============================================================================
log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

# Enable IP forwarding (required for exit node)
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf
log "IP forwarding enabled"

# Start Tailscale and advertise as exit node
if [[ -n "$TS_AUTHKEY" ]]; then
    tailscale up --authkey="$TS_AUTHKEY" --advertise-exit-node --hostname="us-egress-primary"
    log "Tailscale started with authkey, advertising as exit node"
else
    tailscale up --advertise-exit-node --hostname="us-egress-primary"
    log "Tailscale started — complete authentication in the URL above"
    warn "After auth, approve this node as exit node in Tailscale admin console:"
    warn "  https://login.tailscale.com/admin/machines"
    warn "  → Click the node → Edit route settings → Allow exit node"
fi

# =============================================================================
# Layer 2: Raw WireGuard fallback (no Tailscale dependency)
# =============================================================================
log "Installing WireGuard (fallback)..."
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools qrencode

WG_DIR="/etc/wireguard"
if [[ ! -f "$WG_DIR/server_private.key" ]]; then
    wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key"
    log "Generated WireGuard server keypair"
fi

SERVER_PRIVKEY=$(cat "$WG_DIR/server_private.key")
SERVER_PUBKEY=$(cat "$WG_DIR/server_public.key")

DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)
[[ -z "$DEFAULT_IF" ]] && err "Cannot detect default network interface"

cat > "$WG_DIR/wg0.conf" <<EOF
# Raw WireGuard fallback — use only if Tailscale is unacceptable
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[Interface]
Address = 10.100.0.1/24
ListenPort = 51820
PrivateKey = $SERVER_PRIVKEY

PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT

# Clients added by setup-wg-fallback.sh
EOF
chmod 600 "$WG_DIR/wg0.conf"

# WireGuard NOT started by default — Tailscale is the primary path
# Start manually with: systemctl start wg-quick@wg0
systemctl enable wg-quick@wg0
log "WireGuard configured (not started — Tailscale is primary)"

# =============================================================================
# Layer 5: Hardening
# =============================================================================
log "Applying OS hardening..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/harden.sh" || warn "Hardening script not found, run harden.sh manually"

# =============================================================================
# Deploy health check
# =============================================================================
log "Deploying health check..."
bash "$SCRIPT_DIR/deploy-healthcheck.sh" --interval 60 || warn "Health check deployment skipped"

# =============================================================================
# Summary
# =============================================================================
TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending auth")

log ""
log "=========================================="
log " Lightsail egress node provisioned"
log ""
log " Public IPv4:     $PUBLIC_IP (verify static IP is attached!)"
log " Tailscale IP:    $TS_IP"
log " Tailscale name:  us-egress-primary"
log ""
log " Primary path:    Tailscale exit node (WireGuard + DERP relay)"
log " Fallback path:   Raw WireGuard on :51820/udp"
log " WG server pub:   $SERVER_PUBKEY"
log ""
log " NEXT STEPS:"
log "  1. Approve exit node in Tailscale admin console"
log "  2. On each device: run setup-tailscale-client.sh"
log "  3. Verify: curl ifconfig.me → should show $PUBLIC_IP"
log "=========================================="
