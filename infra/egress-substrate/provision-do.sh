#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Variant B: DigitalOcean Dual-Node Provisioner
#
# Key difference from Lightsail:
#   - DigitalOcean Reserved IP can be reassigned between Droplets
#   - This enables automated failover: primary dies → Reserved IP moves to backup
#   - Both nodes must be in the SAME region (Reserved IP is region-bound)
#
# Prerequisites (done in DO console or via doctl):
#   1. Create Reserved IP in target US region (e.g. nyc1)
#      doctl compute reserved-ip create --region nyc1
#   2. Create primary Droplet ($4/mo, Ubuntu 22.04, same region)
#   3. Create backup Droplet ($4/mo, Ubuntu 22.04, same region)
#   4. Assign Reserved IP to primary Droplet
#      doctl compute reserved-ip-action assign <reserved-ip> <primary-droplet-id>
#   5. SSH into each node and run this script
#
# Usage:
#   Primary: ./provision-do.sh --role primary --reserved-ip 1.2.3.4 [--authkey tskey-xxx]
#   Backup:  ./provision-do.sh --role backup  --reserved-ip 1.2.3.4 [--authkey tskey-xxx]
# =============================================================================

ROLE=""
RESERVED_IP=""
TS_AUTHKEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)        ROLE="$2"; shift 2 ;;
        --reserved-ip) RESERVED_IP="$2"; shift 2 ;;
        --authkey)     TS_AUTHKEY="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$ROLE" ]] && { echo "Usage: $0 --role primary|backup --reserved-ip IP"; exit 1; }
[[ -z "$RESERVED_IP" ]] && { echo "Error: --reserved-ip required"; exit 1; }
[[ "$ROLE" != "primary" && "$ROLE" != "backup" ]] && { echo "Error: --role must be primary or backup"; exit 1; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && err "Run as root"

DROPLET_IP=$(curl -4 -s --max-time 10 ifconfig.me)
[[ -z "$DROPLET_IP" ]] && err "Cannot detect public IP"

log "Role: $ROLE"
log "Droplet IP: $DROPLET_IP"
log "Reserved IP: $RESERVED_IP"

# =============================================================================
# Layer 1: Tailscale exit node
# =============================================================================
log "Installing Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf

TS_HOSTNAME="us-egress-$ROLE"
if [[ -n "$TS_AUTHKEY" ]]; then
    tailscale up --authkey="$TS_AUTHKEY" --advertise-exit-node --hostname="$TS_HOSTNAME"
    log "Tailscale started as $TS_HOSTNAME"
else
    tailscale up --advertise-exit-node --hostname="$TS_HOSTNAME"
    log "Tailscale started — complete auth via the URL above"
    warn "Then approve as exit node in Tailscale admin console"
fi

# =============================================================================
# Layer 4: Failover — Reserved IP reassignment
# =============================================================================
if [[ "$ROLE" == "backup" ]]; then
    log "Installing doctl for automated failover..."
    # doctl is needed to reassign the Reserved IP
    snap install doctl 2>/dev/null || {
        # Fallback: manual install
        DOCTL_VERSION="1.104.0"
        curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" | tar xz -C /usr/local/bin/
    }

    if command -v doctl &>/dev/null; then
        log "doctl installed — configure with: doctl auth init"
        warn "After configuring doctl, the health check can auto-reassign the Reserved IP"
    else
        warn "doctl installation failed — automated failover not available"
        warn "Manual failover: doctl compute reserved-ip-action assign $RESERVED_IP <this-droplet-id>"
    fi

    # Store failover config
    mkdir -p /etc/egress-substrate
    cat > /etc/egress-substrate/failover.conf <<EOF
ROLE=backup
RESERVED_IP=$RESERVED_IP
PRIMARY_HOSTNAME=us-egress-primary
BACKUP_DROPLET_IP=$DROPLET_IP
EOF
    chmod 600 /etc/egress-substrate/failover.conf
    log "Failover config stored at /etc/egress-substrate/failover.conf"
fi

if [[ "$ROLE" == "primary" ]]; then
    mkdir -p /etc/egress-substrate
    cat > /etc/egress-substrate/failover.conf <<EOF
ROLE=primary
RESERVED_IP=$RESERVED_IP
PRIMARY_DROPLET_IP=$DROPLET_IP
EOF
    chmod 600 /etc/egress-substrate/failover.conf
fi

# =============================================================================
# WireGuard fallback
# =============================================================================
log "Installing WireGuard (fallback)..."
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools qrencode

WG_DIR="/etc/wireguard"
if [[ ! -f "$WG_DIR/server_private.key" ]]; then
    wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
    chmod 600 "$WG_DIR/server_private.key"
fi

SERVER_PRIVKEY=$(cat "$WG_DIR/server_private.key")
SERVER_PUBKEY=$(cat "$WG_DIR/server_public.key")
DEFAULT_IF=$(ip route show default | awk '/default/ {print $5}' | head -1)

if [[ "$ROLE" == "primary" ]]; then
    WG_ADDR="10.100.0.1/24"
else
    WG_ADDR="10.100.1.1/24"
fi

cat > "$WG_DIR/wg0.conf" <<EOF
# Raw WireGuard fallback — $ROLE node
[Interface]
Address = $WG_ADDR
ListenPort = 51820
PrivateKey = $SERVER_PRIVKEY

PostUp = iptables -t nat -A POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostUp = iptables -A FORWARD -i %i -j ACCEPT
PostUp = iptables -A FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $DEFAULT_IF -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT
PostDown = iptables -D FORWARD -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
chmod 600 "$WG_DIR/wg0.conf"
systemctl enable wg-quick@wg0
log "WireGuard configured (not started — Tailscale is primary)"

# =============================================================================
# Hardening + Health check
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$SCRIPT_DIR/harden.sh" || warn "Run harden.sh manually"
bash "$SCRIPT_DIR/deploy-healthcheck.sh" --interval 60 || warn "Deploy health check manually"

# =============================================================================
# Summary
# =============================================================================
TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending")

log ""
log "=========================================="
log " DigitalOcean $ROLE node provisioned"
log ""
log " Droplet IP:    $DROPLET_IP"
log " Reserved IP:   $RESERVED_IP"
log " Tailscale IP:  $TS_IP"
log " Tailscale name: $TS_HOSTNAME"
log " WG server pub: $SERVER_PUBKEY"
log ""
if [[ "$ROLE" == "primary" ]]; then
    log " This is the primary exit node."
    log " Reserved IP should be assigned to this Droplet."
    log " Verify: curl -4 ifconfig.me → should show $RESERVED_IP"
else
    log " This is the backup exit node."
    log " Reserved IP stays on primary until failover."
    log " Configure doctl: doctl auth init"
    log " Test failover: doctl compute reserved-ip-action assign $RESERVED_IP <this-droplet-id>"
fi
log "=========================================="
