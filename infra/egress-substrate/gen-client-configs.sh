#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Deterministic Client Config Generator
# Produces identical-behavior configs for all platforms (Mac/Win/iOS/Android)
#
# Usage: ./gen-client-configs.sh <client-name> [--primary-endpoint IP] [--backup-endpoint IP]
#
# Output: ./clients/<client-name>/
#   ├── primary.conf        (WireGuard config → primary node)
#   ├── backup.conf         (WireGuard config → backup node)
#   ├── primary-tcp.conf    (WireGuard-over-TCP for hostile networks)
#   ├── primary.png         (QR code for mobile import)
#   ├── backup.png          (QR code for mobile import)
#   └── README.txt          (device-specific setup notes)
# =============================================================================

CLIENT_NAME="${1:?Usage: $0 <client-name> [--primary-endpoint IP] [--backup-endpoint IP]}"
PRIMARY_ENDPOINT="${3:-}"
BACKUP_ENDPOINT="${5:-}"

WG_DIR="/etc/wireguard"
CLIENT_DIR="$(dirname "$0")/clients/$CLIENT_NAME"
WG_PORT=51820
WSTUNNEL_PORT=443
DNS_SERVERS="1.1.1.1, 1.0.0.1"  # Cloudflare — low latency, no logging

# --- Load server info ---
if [[ -f "$WG_DIR/server_public.key" ]]; then
    SERVER_PUBKEY=$(cat "$WG_DIR/server_public.key")
else
    echo "Error: server public key not found. Run provision.sh first." >&2
    exit 1
fi

if [[ -z "$PRIMARY_ENDPOINT" ]]; then
    PRIMARY_ENDPOINT=$(curl -4 -s ifconfig.me)
fi

# --- Generate client keypair ---
mkdir -p "$CLIENT_DIR"
if [[ ! -f "$CLIENT_DIR/private.key" ]]; then
    wg genkey | tee "$CLIENT_DIR/private.key" | wg pubkey > "$CLIENT_DIR/public.key"
    wg genpsk > "$CLIENT_DIR/preshared.key"
    chmod 600 "$CLIENT_DIR/private.key" "$CLIENT_DIR/preshared.key"
    echo "[+] Generated new client keypair for: $CLIENT_NAME"
else
    echo "[+] Reusing existing client keypair for: $CLIENT_NAME"
fi

CLIENT_PRIVKEY=$(cat "$CLIENT_DIR/private.key")
CLIENT_PUBKEY=$(cat "$CLIENT_DIR/public.key")
CLIENT_PSK=$(cat "$CLIENT_DIR/preshared.key")

# --- Allocate client IP ---
# Simple: hash client name to get a deterministic IP in 10.100.0.0/24
# This ensures the same client name always gets the same IP
CLIENT_HASH=$(echo -n "$CLIENT_NAME" | md5sum | cut -c1-2)
CLIENT_NUM=$(( 16#$CLIENT_HASH % 253 + 2 ))  # 2-254, avoiding .1 (server)
CLIENT_IP="10.100.0.$CLIENT_NUM"
echo "[+] Client IP: $CLIENT_IP (deterministic from name hash)"

# =============================================================================
# Layer 3: Endpoint Consistency — same config shape across all devices
# =============================================================================

# --- Primary config (UDP direct) ---
cat > "$CLIENT_DIR/primary.conf" <<EOF
# Stable Egress Substrate — Primary (UDP)
# Client: $CLIENT_NAME
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/32
DNS = $DNS_SERVERS
# MTU tuned for reliability across mobile/hotel networks
MTU = 1280

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $CLIENT_PSK
Endpoint = ${PRIMARY_ENDPOINT}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
# Persistent keepalive: survive NAT timeouts on mobile/hotel WiFi
PersistentKeepalive = 25
EOF

# --- Backup config (UDP direct to backup node) ---
if [[ -n "$BACKUP_ENDPOINT" ]]; then
cat > "$CLIENT_DIR/backup.conf" <<EOF
# Stable Egress Substrate — Backup (UDP)
# Client: $CLIENT_NAME
# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
# NOTE: Use this only when primary is unreachable

[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = 10.100.1.$CLIENT_NUM/32
DNS = $DNS_SERVERS
MTU = 1280

[Peer]
PublicKey = BACKUP_SERVER_PUBKEY_PLACEHOLDER
PresharedKey = $CLIENT_PSK
Endpoint = ${BACKUP_ENDPOINT}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
echo "[+] Backup config generated (update BACKUP_SERVER_PUBKEY manually after provisioning backup node)"
fi

# --- TCP fallback config (for UDP-hostile networks) ---
cat > "$CLIENT_DIR/primary-tcp.conf" <<EOF
# Stable Egress Substrate — Primary via TCP (hostile network fallback)
# Client: $CLIENT_NAME
#
# USAGE: This config connects WireGuard through a WebSocket tunnel.
# Start wstunnel client first, then activate this WireGuard config.
#
# Step 1: wstunnel client -L udp://127.0.0.1:${WG_PORT}:127.0.0.1:${WG_PORT} wss://${PRIMARY_ENDPOINT}:${WSTUNNEL_PORT}
# Step 2: Import this config into WireGuard client
#
# On Mac/Linux, a helper script is provided. On iOS/Android, use the
# standard WireGuard config and run wstunnel separately on a companion device
# or use a local proxy app.

[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP/32
DNS = $DNS_SERVERS
MTU = 1280

[Peer]
PublicKey = $SERVER_PUBKEY
PresharedKey = $CLIENT_PSK
# Route through local wstunnel endpoint instead of direct
Endpoint = 127.0.0.1:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

# --- QR codes for mobile onboarding ---
if command -v qrencode &>/dev/null; then
    qrencode -t PNG -o "$CLIENT_DIR/primary.png" < "$CLIENT_DIR/primary.conf"
    echo "[+] QR code: $CLIENT_DIR/primary.png"
    if [[ -f "$CLIENT_DIR/backup.conf" ]]; then
        qrencode -t PNG -o "$CLIENT_DIR/backup.png" < "$CLIENT_DIR/backup.conf"
    fi
else
    echo "[!] qrencode not installed — skipping QR generation (apt install qrencode)"
fi

# --- Device setup notes ---
cat > "$CLIENT_DIR/README.txt" <<EOF
Stable Egress Substrate — Client Setup: $CLIENT_NAME
=====================================================

IP Assignment: $CLIENT_IP
Primary Endpoint: ${PRIMARY_ENDPOINT}:${WG_PORT} (UDP)
TCP Fallback: ${PRIMARY_ENDPOINT}:${WSTUNNEL_PORT} (WSS)
Backup Endpoint: ${BACKUP_ENDPOINT:-not configured}

--- Setup by Platform ---

[Mac / Windows]
1. Install WireGuard from https://www.wireguard.com/install/
2. Import primary.conf
3. Activate tunnel
4. If connection fails (UDP blocked): use primary-tcp.conf with wstunnel

[iOS]
1. Install WireGuard from App Store
2. Scan primary.png QR code
3. Enable "On-Demand" → Wi-Fi + Cellular for always-on

[Android]
1. Install WireGuard from Play Store / F-Droid
2. Scan primary.png QR code
3. Enable persistent tunnel in Android settings

--- Failover Procedure ---

If primary is unreachable for >60 seconds:
1. Disconnect primary tunnel
2. Import and activate backup.conf
3. Verify egress IP: curl ifconfig.me

--- UDP Blocked? (Hotel/Airport/Corporate) ---

1. On Mac/Linux:
   wstunnel client -L udp://127.0.0.1:${WG_PORT}:127.0.0.1:${WG_PORT} \\
     wss://${PRIMARY_ENDPOINT}:${WSTUNNEL_PORT}
2. Then activate primary-tcp.conf in WireGuard
3. This wraps WireGuard inside a WebSocket over TLS on port 443
   — appears as normal HTTPS traffic to network filters

--- DNS Policy ---

DNS is set to Cloudflare (1.1.1.1, 1.0.0.1):
- No logging policy
- Low latency
- Avoids DNS leaks through hotel/carrier resolvers
EOF

# --- Register client peer on the server ---
# Append peer to server config if not already present
WG_CONF="$WG_DIR/wg0.conf"
if [[ -f "$WG_CONF" ]]; then
    if ! grep -q "$CLIENT_PUBKEY" "$WG_CONF"; then
        cat >> "$WG_CONF" <<EOF

# Client: $CLIENT_NAME ($CLIENT_IP)
[Peer]
PublicKey = $CLIENT_PUBKEY
PresharedKey = $CLIENT_PSK
AllowedIPs = $CLIENT_IP/32
EOF
        # Hot-reload without dropping existing connections
        wg syncconf wg0 <(wg-quick strip wg0) 2>/dev/null || {
            echo "[!] Could not hot-reload — restarting WireGuard"
            systemctl restart wg-quick@wg0
        }
        echo "[+] Peer registered on server and config reloaded"
    else
        echo "[+] Peer already registered on server"
    fi
fi

echo ""
echo "=========================================="
echo " Client configs: $CLIENT_DIR/"
echo "   primary.conf      — normal use (UDP)"
echo "   primary-tcp.conf  — hostile network (TCP)"
echo "   backup.conf       — failover node"
echo "   primary.png       — mobile QR"
echo "   README.txt        — setup instructions"
echo "=========================================="
