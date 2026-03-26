#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Health Check — Updated for Tailscale + WireGuard dual-path architecture
#
# Probes:
#   1. Tailscale status (is exit node active?)
#   2. Egress IP matches expected (static/reserved IP)
#   3. OpenAI API reachable (401 = good, 403 = geo-blocked/flagged)
#   4. State transition logging + optional Telegram alert
#
# On DigitalOcean backup node: can trigger Reserved IP reassignment
#
# Usage: ./deploy-healthcheck.sh [--interval 60] [--telegram-token T --telegram-chat C]
# =============================================================================

INTERVAL=60
TELEGRAM_TOKEN=""
TELEGRAM_CHAT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)        INTERVAL="$2"; shift 2 ;;
        --telegram-token)  TELEGRAM_TOKEN="$2"; shift 2 ;;
        --telegram-chat)   TELEGRAM_CHAT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }

# Store expected egress IP
PUBLIC_IP=$(curl -4 -s --max-time 10 ifconfig.me)
mkdir -p /etc/egress-substrate
echo "$PUBLIC_IP" > /etc/egress-substrate/expected_ip

# Store Telegram config
if [[ -n "$TELEGRAM_TOKEN" && -n "$TELEGRAM_CHAT" ]]; then
    echo "$TELEGRAM_TOKEN" > /etc/egress-substrate/telegram_token
    echo "$TELEGRAM_CHAT" > /etc/egress-substrate/telegram_chat
    chmod 600 /etc/egress-substrate/telegram_token /etc/egress-substrate/telegram_chat
fi

# Install probe script
cat > /usr/local/bin/egress-healthcheck <<'SCRIPT'
#!/usr/bin/env bash
LOG="/var/log/egress-health.log"
STATE_FILE="/tmp/egress-health-state"
CONF_DIR="/etc/egress-substrate"

[[ ! -f "$STATE_FILE" ]] && echo "healthy" > "$STATE_FILE"
PREV=$(cat "$STATE_FILE")
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

FAILURES=()

# Probe 1: Tailscale status
if command -v tailscale &>/dev/null; then
    TS_STATUS=$(tailscale status --json 2>/dev/null)
    if [[ -n "$TS_STATUS" ]]; then
        # Check if this node is offering exit node
        SELF_EXIT=$(echo "$TS_STATUS" | grep -o '"ExitNode":true' || echo "")
        ONLINE=$(echo "$TS_STATUS" | grep -o '"Online":true' | head -1 || echo "")
        [[ -z "$ONLINE" ]] && FAILURES+=("tailscale-offline")
    else
        FAILURES+=("tailscale-unreachable")
    fi
else
    # Tailscale not installed — check WireGuard instead
    wg show wg0 &>/dev/null || FAILURES+=("wg-interface-down")
fi

# Probe 2: Egress IP
EXPECTED_IP=""
[[ -f "$CONF_DIR/expected_ip" ]] && EXPECTED_IP=$(cat "$CONF_DIR/expected_ip")
ACTUAL_IP=$(curl -4 -s --max-time 10 ifconfig.me 2>/dev/null || echo "")
if [[ -n "$EXPECTED_IP" && -n "$ACTUAL_IP" ]]; then
    [[ "$ACTUAL_IP" != "$EXPECTED_IP" ]] && FAILURES+=("egress-ip-mismatch:expected=$EXPECTED_IP,got=$ACTUAL_IP")
elif [[ -z "$ACTUAL_IP" ]]; then
    FAILURES+=("egress-ip-unreachable")
fi

# Probe 3: OpenAI reachability
STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
    "https://api.openai.com/v1/models" \
    -H "Authorization: Bearer sk-probe" 2>/dev/null || echo "000")
case "$STATUS" in
    401|200) ;; # reachable
    403) FAILURES+=("openai-403-blocked") ;;
    *)   FAILURES+=("openai-unreachable:$STATUS") ;;
esac

# Determine state
if [[ ${#FAILURES[@]} -eq 0 ]]; then
    NOW="healthy"
else
    NOW="degraded:${FAILURES[*]}"
fi

# Log transition
if [[ "$NOW" != "$PREV" ]]; then
    echo "$(ts) STATE_CHANGE $PREV -> $NOW" >> "$LOG"

    # Alert
    if [[ "$NOW" != "healthy" ]]; then
        MSG="Egress degraded: ${FAILURES[*]}"
        echo "$(ts) ALERT $MSG" >> "$LOG"
        if [[ -f "$CONF_DIR/telegram_token" && -f "$CONF_DIR/telegram_chat" ]]; then
            T=$(cat "$CONF_DIR/telegram_token")
            C=$(cat "$CONF_DIR/telegram_chat")
            curl -s -X POST "https://api.telegram.org/bot${T}/sendMessage" \
                -d chat_id="$C" -d text="$MSG" &>/dev/null || true
        fi
    else
        echo "$(ts) RECOVERY healthy" >> "$LOG"
    fi

    # DigitalOcean failover: if backup node detects primary is down
    if [[ -f "$CONF_DIR/failover.conf" ]]; then
        source "$CONF_DIR/failover.conf"
        if [[ "$ROLE" == "backup" && "$NOW" == *"openai"* ]]; then
            echo "$(ts) FAILOVER_CANDIDATE backup node detected primary degradation" >> "$LOG"
            # Automated reassignment requires doctl auth to be configured
            # Uncomment after testing:
            # doctl compute reserved-ip-action assign $RESERVED_IP $(curl -s http://169.254.169.254/metadata/v1/id)
        fi
    fi
fi

echo "$NOW" > "$STATE_FILE"
echo "$(ts) PROBE $NOW" >> "$LOG"
SCRIPT

chmod +x /usr/local/bin/egress-healthcheck

# Systemd timer
cat > /etc/systemd/system/egress-healthcheck.service <<EOF
[Unit]
Description=Egress substrate health probe
[Service]
Type=oneshot
ExecStart=/usr/local/bin/egress-healthcheck
EOF

cat > /etc/systemd/system/egress-healthcheck.timer <<EOF
[Unit]
Description=Egress health probe every ${INTERVAL}s
[Timer]
OnBootSec=30
OnUnitActiveSec=${INTERVAL}s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now egress-healthcheck.timer

echo "[+] Health check deployed (interval: ${INTERVAL}s, log: /var/log/egress-health.log)"
echo "[+] Expected egress IP: $PUBLIC_IP"
