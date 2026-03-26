#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Raw WireGuard Fallback — Client Config Generator
#
# Use this ONLY if Tailscale is unacceptable (e.g., no third-party control plane).
#
# Trade-offs vs Tailscale path:
#   + No third-party coordination server dependency
#   + Simpler trust model (only your VPS)
#   - No DERP relay: fails on UDP-hostile networks (hotels, airports, corporate)
#   - Manual key distribution
#   - Manual failover (no control plane to switch exit nodes)
#   - PersistentKeepalive at 25s for NAT survival (per WireGuard docs)
#
# Run on the SERVER after provision-*.sh has been run.
#
# Usage: ./setup-wg-fallback.sh <client-name>
# =============================================================================

CLIENT_NAME="${1:?Usage: $0 <client-name>}"
WG_DIR="/etc/wireguard"
CLIENT_DIR="$(cd "$(dirname "$0")" && pwd)/clients/$CLIENT_NAME"
WG_PORT=51820
DNS_SERVERS="1.1.1.1, 1.0.0.1"

log() { echo -e "\033[0;32m[+]\033[0m $*"; }

# --- Server info ---
[[ ! -f "$WG_DIR/server_public.key" ]] && { echo "Error: Run provision-*.sh first"; exit 1; }
SERVER_PUBKEY=$(cat "$WG_DIR/server_public.key")
PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me)

# --- Client keypair ---
mkdir -p "$CLIENT_DIR"
if [[ ! -f "$CLIENT_DIR/private.key" ]]; then
    wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
    wg genpsk > "$CLIENT_DIR/preshared.key"
    chmod 600 "$CLIENT_DIR/private.key" "$CLIENT_DIR/preshared.key"
    log "Generated keypair for: $CLIENT_NAME"
fi

CLIENT_PRIVKEY=$(cat "$CLIENT_DIR/private.key")
CLIENT_PUBKEY=$(cat "$CLIENT_DIR/public.key")
CLIENT_PSK=$(cat "$CLIENT_DIR/preshared.key")

# Deterministic IP from name
CLIENT_HASH=$(echo -n "$CLIENT_NAME" | md5sum | cut -c1-2)
CLIENT_NUM=$(( 16#$CLIENT_HASH % 253 + 2 ))
CLIENT_IP="10.100.0.$CLIENT_NUM"
log "Client IP: $CLIENT_IP"

# --- Generate config ---
cat > "$CLIENT_DIR/wg-fallback.conf" <<EOF
# Raw WireGuard fallback config
# Client: $CLIENT_NAME
# Use only when Tailscale is unavailable
# WARNING: No relay fallback — will fail on UDP-hostile networks

[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/32
DNS = $DNS_SERVERS
MTU = 1280

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $CLIENT_PSK
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# --- QR code ---
if command -v qrencode &>/dev/null; then
    qrencode -t PNG -o "$CLIENT_DIR/wg-fallback.png" < "$CLIENT_DIR/wg-fallback.conf"
    log "QR code: $CLIENT_DIR/wg-fallback.png"
fi

# --- Register peer on server ---
WG_CONF="$WG_DIR/wg0.conf"
if [[ -f "$WG_CONF" ]] && ! grep -q "$CLIENT_PUBKEY" "$WG_CONF"; then
    cat >> "$WG_CONF" <<EOF

# Client: $CLIENT_NAME ($CLIENT_IP)
[Peer]
PublicKey = $CLIENT_PUBKEY
PresharedKey = $CLIENT_PSK
AllowedIPs = $CLIENT_IP/32
EOF
    # Hot-reload if WireGuard is running
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || systemctl restart wg-quick@wg0
        log "Peer registered and WireGuard reloaded"
    else
        log "Peer registered (WireGuard not running — start with: systemctl start wg-quick@wg0)"
    fi
fi

log ""
log "Config:  $CLIENT_DIR/wg-fallback.conf"
log "Import into WireGuard app on your device."
log "This is the low-dependency fallback. Tailscale exit node is preferred."
